# VoltGlean

VoltGlean exports Windows power plans to an executable `*.bat` script. It allows you to save your performance and power settings for migration to another system or restoration after an OS reinstall.

## Features

- Full Export: Extracts all available power schemes.
- AC/DC Settings: Saves parameters for both plugged-in and battery modes.
- Automation: Generates a ready-to-use batch file using the standard powercfg utility.
- Smart Parsing: Correctly handles GUIDs, aliases, and nested setting subgroups.
- Hidden Settings: Dumps properties that are hidden in the Windows GUI, allowing you to manually edit them in the script before applying.
- Active Plan: Detects the currently active plan and includes a command to reactivate it.

## Installation

### Via Cargo
```bash
cargo install voltglean
```

### Via cargo-binstall
```bash
cargo binstall voltglean
```

### Via WinGet
```powershell
winget install Taraflex.VoltGlean
```

## Usage

Run the program and redirect the output to a file:

```powershell
voltglean > restore_power_plans.bat
```

This will create `restore_power_plans.bat`. Run it as Administrator to apply the saved power settings.

### Options
```text
-h, --help      Show help message
-v, --version   Show version information
```

## How it works

1. The program calls `powercfg /list` to find all power schemes.
2. For each scheme, it performs a deep query via `powercfg /qh` (including hidden settings).
3. The data is parsed into an internal structure.
4. Using the template engine, it generates a script containing `powercfg /setacvalueindex` and `powercfg /setdcvalueindex` commands.
