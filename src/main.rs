use askama::Template;
use indexmap::IndexMap;
use lazy_regex::{regex, regex_replace_all};
use serde::Deserialize;
use std::io::{Write, stdout};
use std::process::{self, Command, Output, Stdio};

#[derive(Deserialize, Debug)]
#[serde(untagged)]
enum SettingOptions {
    Range { min: u32, max: u32, unit: String },
    Enum(Vec<EnumOption>),
    None,
}

#[derive(Deserialize, Debug)]
struct EnumOption {
    key: String,
    value: u32,
}

#[derive(Deserialize, Debug)]
struct Setting {
    description: String,
    alias: Option<String>,
    options: SettingOptions,
    ac: u32,
    dc: u32,
}

#[derive(Deserialize, Debug)]
struct Subgroup {
    description: String,
    alias: Option<String>,
    #[serde(rename = "options")]
    _options: Option<serde::de::IgnoredAny>,
    #[serde(flatten)]
    settings: IndexMap<String, Setting>,
}

#[derive(Deserialize, Debug)]
struct PowerPlan {
    description: String,
    alias: Option<String>,
    #[serde(rename = "options")]
    _options: Option<serde::de::IgnoredAny>,
    #[serde(flatten)]
    subgroups: IndexMap<String, Subgroup>,
}

mod filters {
    use crate::SettingOptions;
    #[askama::filter_fn]
    pub fn format_opts(opt: &SettingOptions, _: &dyn askama::Values) -> askama::Result<String> {
        match opt {
            SettingOptions::Enum(list) => Ok(list
                .iter()
                .map(|o| format!("{} - {}", o.key, o.value))
                .collect::<Vec<_>>()
                .join(" / ")),
            SettingOptions::Range { min, max, unit, .. } => {
                Ok(format!("[{}-{}] {}", min, max, unit))
            }
            SettingOptions::None => Ok("".to_string()),
        }
    }
}

#[derive(Template)]
#[template(path = "script.ps1.hbs", ext = "txt", escape = "none")]
struct ScriptTemplate {
    plans: Vec<(String, PowerPlan)>,
    active_plan: Option<String>,
}

fn zero_if_empty(s: &str) -> &str {
    if s.is_empty() { "0" } else { s }
}

fn make_safe_for_yaml_string(data: Vec<u8>) -> String {
    let mut output = String::from_utf8_lossy(&data).into_owned();
    drop(data);
    let bytes = unsafe { output.as_bytes_mut() };
    for b in bytes {
        match b {
            b'\r' => *b = b'\n',
            b'\'' => *b = b'`',
            _ => (),
        }
    }
    output
}

fn get_plan_yaml(guid: &str) -> String {
    let s = make_safe_for_yaml_string(run_powercfg(&["/qh", guid]).stdout);

    let s = regex_replace_all!(
        r"^( *)[^\s]?.*?GUID.*?: (?P<guid>[0-9a-f-]{36})\s+\((?P<desc>.+)\)\n+(?: +[^\s]?.*?GUID.*?: (?P<alias>[A-Z_0-9]+)\n+)?"m,
        &s,
        |_, indent, guid, desc, alias| format!(
            "{indent}{guid}:\n{indent}  description: '{desc}'\n{indent}  alias: {alias}\n{indent}  options:\n"
        )
    );

    let s = regex_replace_all!(
        r"^      [^\s][^:]+: (?P<min>0x[0-9a-f]+)\n+      [^\s][^:]+: (?P<max>0x[0-9a-f]+)\n+      [^\s][^:]+: (?P<step>0x[0-9a-f]+)\n+      [^\s][^:]+: (?P<unit>.+)$"m,
        &s,
        |_, min, max, _, unit| format!(
            "        min: {min}\n        max: {max}\n        unit: '{unit}'"
        )
    );

    let s = regex_replace_all!(
        r"^      [^\s][^:]+: (?P<val>0[0-9]+)\n+      [^\s][^:]+: (?P<key>.+)$"m,
        &s,
        |_, val: &str, key| format!(
            "        - key: '{key}'\n          value: {}",
            zero_if_empty(val.trim_start_matches('0'))
        )
    );

    // Current AC/DC
    regex_replace_all!(
        r"^    [^\s][^:]+: (?P<ac>0x[0-9a-f]+)\n+    [^\s][^:]+: (?P<dc>0x[0-9a-f]+)$"m,
        &s,
        |_, ac, dc| format!("      ac: {ac}\n      dc: {dc}")
    )
    .to_string()
}

fn run_powercfg(args: &[&str]) -> Output {
    Command::new("powercfg")
        .args(args)
        .stderr(Stdio::inherit())
        .output()
        .expect("FAIL run 'powercfg' command")
}

fn main() {
    for arg in std::env::args().skip(1) {
        match arg.as_ref() {
            "/?" | "-h" | "--help" => {
                println!(concat!(
                    env!("CARGO_PKG_NAME"),
                    " v",
                    env!("CARGO_PKG_VERSION"),
                    "\n\nUsage:\n  ",
                    env!("CARGO_PKG_NAME"),
                    " > power_schemes.ps1\n\nOptions:\n  -h, --help, /?    Show this help message\n  -v, --version     Show version information",
                ));
                return;
            }
            "-v" | "--version" => {
                println!(concat!(
                    env!("CARGO_PKG_NAME"),
                    " v",
                    env!("CARGO_PKG_VERSION")
                ));
                return;
            }
            _ => {}
        }
    }

    let pcfg = run_powercfg(&["/list"]);
    if !pcfg.status.success() {
        eprintln!("FAIL 'powercfg /lits' commamnd");
        process::exit(pcfg.status.code().unwrap_or(1));
    }

    let list_output = String::from_utf8_lossy(&pcfg.stdout);
    let mut plans = Vec::new();
    let mut active_plan = None;

    let re_list = regex!(r"\s+(?P<guid>[0-9a-f-]{36})\s+\((?P<name>.+)\)\s*(?P<active>\*)?");

    for cap in re_list.captures_iter(&list_output) {
        let plan_guid = &cap["guid"];
        let plan_name = &cap["name"];
        let is_active = cap.name("active").is_some();

        let raw_yaml = get_plan_yaml(plan_guid);

        //std::fs::write(format!("{plan_name}.yaml"), raw_yaml.clone()).unwrap();

        match serde_yaml::from_str::<IndexMap<String, PowerPlan>>(&raw_yaml) {
            Ok(data) => {
                if let Some((p_guid, p_data)) = data.into_iter().next() {
                    if is_active {
                        active_plan = Some(p_data.alias.clone().unwrap_or_else(|| p_guid.clone()));
                    }
                    plans.push((p_guid, p_data));
                }
            }
            Err(e) => {
                eprintln!("FAIL parse 'powercfg' output for plan '{plan_name}'\n{e}")
            }
        }
    }

    if !plans.is_empty() {
        let template = ScriptTemplate { plans, active_plan }
            .render()
            .expect("FAIL render script template");

        let mut lock = stdout().lock();
        lock.write_all(template.as_bytes()).unwrap();
    }
}
