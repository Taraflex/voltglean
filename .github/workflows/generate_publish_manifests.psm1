#Requires -Version 7.4
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

Import-Module "${PSScriptRoot}/fetch.psm1"

class ProcessException: System.Exception {
    [int] $code = 0
    ProcessException([PSCustomObject]$info) : base ("$info") {
        $this.code = $info.code
    }
}

function ~ {
    param (
        [string]$DefaultErrorMessage = '',
        [Parameter(Position = 0, Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )
    $out = $null
    try {
        & @ScriptBlock 2>&1 | Tee-Object -Variable out
    }
    finally {
        if (0 -ne $LASTEXITCODE) {
            $message = (($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
            throw [ProcessException]::new([PSCustomObject]@{
                    code    = $LASTEXITCODE
                    _       = $ScriptBlock.ToString()
                    message = $message ? $message : $DefaultErrorMessage
                })
        }
    }
}

function IsGuiExe {
    param([string]$Path)

    # Читаем файл как поток байтов
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = New-Object System.IO.BinaryReader($stream)

    try {
        # 1. Переходим к смещению 0x3C, где хранится адрес PE-заголовка
        $stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
        $peHeaderOffset = $reader.ReadUInt32()

        # 2. Переходим к полю Subsystem (Начало PE + 0x5C)
        $subsystemOffset = $peHeaderOffset + 0x5C
        $stream.Seek($subsystemOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $subsystem = $reader.ReadUInt16()

        # 3. Интерпретируем значение
        switch ($subsystem) {
            2 {
                return $true # GUI 
            }
            3 {
                return $false # Console 
            }
            default {
                return $false 
            }
        }
    }
    finally {
        $reader.Close()
        $stream.Close()
    }
}

function ConvertTo-NoCase {
    param([Parameter(Mandatory, ValueFromPipeline)][string]$InputString)
    return ($InputString -replace '[_\s\.\/\\-]+', ' ').Trim()
}


$script:TextInfo = [System.Globalization.CultureInfo]::new('en-US', $false).TextInfo
function ConvertTo-TitleCase {
    param([Parameter(Mandatory, ValueFromPipeline)][string]$InputString)
    return $script:TextInfo.ToTitleCase((ConvertTo-NoCase $InputString))
}

function ConvertTo-UpperCamelCase {
    param([Parameter(Mandatory, ValueFromPipeline)][string]$InputString)
    return ((ConvertTo-TitleCase $InputString) -replace '\s+', '')
}

function ConvertTo-DashCase {
    param([Parameter(Mandatory, ValueFromPipeline)][string]$InputString)
    $withSpaces = ([Regex]::Replace($InputString, '(\p{Ll})(\p{Lu})', '$1 $2') -replace '[\s\.\/\\-]+|_$|^_', ' ').ToLower().Trim()
    return ($withSpaces -replace '[_\s]{2,}|\s+', '-') # не трогаем одиночные _
}

function Get-RepoFileUrl {
    param($RepoInfo, $FilePath)
    $baseUrl = $RepoInfo.html_url -replace 'https://github.com/', 'https://raw.githubusercontent.com/'
    return "${baseUrl}/$($RepoInfo.default_branch)/$FilePath"
}

function Get-CargoMetadata {
    param([string]$Path = './Cargo.toml')
    Write-Host '--- Fetch/Parse Cargo.toml ---' -ForegroundColor Cyan
   
    if ([System.Uri]::IsWellFormedUriString($Path, [System.UriKind]::Absolute)) {
        $Path = fetch -Uri $asset.browser_download_url -OutFile 
    }  
    
    $cargoPkg = (yq -o=json -p=toml '.package' $Path | ConvertFrom-Json -AsHashtable)
    $bins = @(yq -o=json -p=toml '.bin' $Path | ConvertFrom-Json | ForEach-Object { $_.name })
    if ($bins.Count -le 0) {
        $bins = @($cargoPkg.name)
    }
    $apiRepo = $cargoPkg.repository -replace '(\.git)?/?$', '' -replace 'https://github.com/', 'https://api.github.com/repos/' 

    return [PSCustomObject]@{
        Package  = $cargoPkg
        Bins     = $bins
        RepoInfo = fetch -Uri $apiRepo
    }
}

$MANIFEST_VERSION = '1.10.0'
function Save-WingetManifest {
    param($Data, $Path)
    $yaml = $Data | ConvertTo-Json -Depth 5 | yq -P -o=yaml 'del(.. | select(. == null)) | sort_keys(..)'
    $header = "# yaml-language-server: `$schema=https://aka.ms/winget-manifest.$($Data.ManifestType).$MANIFEST_VERSION.schema.json"
    Set-Content -LiteralPath $Path -Value ($header, $yaml) -Encoding UTF8
}

function New-PackageManifests {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Metadata,
        [string]$OutputDir = './publish_manifests'
    )

    $cargoPkg = $Metadata.Package
    $repoInfo = $Metadata.RepoInfo
    $apiRepo = $repoInfo.url
    
    Write-Host '--- Requesting license and release info ---' -ForegroundColor Cyan
    $repoLicense = fetch -Uri "${apiRepo}/license"
    $latestRelease = fetch -Uri "${apiRepo}/releases/latest" 
    if (-not $latestRelease) {
        throw 'The latest release on Github has not been found!' 
    }

    $pkgVer = $latestRelease.tag_name -replace '^v', ''
    $Publisher = (ConvertTo-UpperCamelCase $repoInfo.owner.login)
    $PackageName = (ConvertTo-UpperCamelCase $cargoPkg.name)
    $PackageId = $Publisher + '.' + $PackageName

    $Installers = @()
    $TestBins = New-Object System.Collections.Generic.HashSet[string]
    $ArchMap = @(
        @{ WinGet = 'x64'; Pattern = '*x86_64*' },
        @{ WinGet = 'x86'; Pattern = '*i686*' },
        @{ WinGet = 'arm64'; Pattern = '*aarch64*' }
    )

    foreach ($map in $ArchMap) {
        $asset = $latestRelease.assets | Where-Object { $_.name -like '*win*.zip' -and $_.name -like $map.Pattern }
        if ($null -eq $asset) {
            continue 
        }

        Write-Host "Processing $($map.WinGet): $($asset.name)..." -ForegroundColor Yellow
        $tempZip = fetch -Uri $asset.browser_download_url -OutFile 
        $hash = (Get-FileHash -LiteralPath $tempZip -Algorithm SHA256).Hash

        $tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [guid]::NewGuid().ToString())
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempDir -Force

        $bins = @(Get-ChildItem -LiteralPath $tempDir -Filter '*.exe' -Recurse -File | Where-Object {
                $Metadata.Bins.Contains($_.BaseName)
            } | ForEach-Object {
                if ((IsGuiExe -Path $_.FullName)) {
                    @{
                        RelativeFilePath = $_.FullName.Replace($tempDir, '').TrimStart('\')
                        Shortcuts        = @(@{ ShortcutName = ConvertTo-TitleCase $_.BaseName })
                    }
                }
                else {
                    $PortableCommandAlias = ConvertTo-DashCase $_.BaseName 
                    $TestBins.Add($PortableCommandAlias) > $null
                    @{
                        RelativeFilePath     = $_.FullName.Replace($tempDir, '').TrimStart('\')
                        PortableCommandAlias = $PortableCommandAlias 
                    }
                }
            })

        if ($bins.Count -gt 0) {
            $Installers += @{
                Architecture         = $map.WinGet
                InstallerType        = 'zip'
                NestedInstallerType  = 'portable'
                InstallerUrl         = $asset.browser_download_url
                InstallerSha256      = $hash
                NestedInstallerFiles = $bins
            }
        }

        Remove-Item $tempDir -Recurse -ErrorAction SilentlyContinue
    }

    $wingetManifestDir = "$OutputDir/winget/$pkgVer"
    New-Item -ItemType Directory -Path $wingetManifestDir -Force > $null
    
    Save-WingetManifest -Path "$wingetManifestDir/$PackageId.yaml" -Data @{
        PackageIdentifier = $PackageId
        PackageVersion    = $pkgVer
        DefaultLocale     = 'en-US'
        ManifestType      = 'version'
        ManifestVersion   = $MANIFEST_VERSION
    }

    Save-WingetManifest -Path "$wingetManifestDir/$PackageId.installer.yaml" -Data @{
        PackageIdentifier = $PackageId
        PackageVersion    = $pkgVer
        Installers        = $Installers
        ManifestType      = 'installer'
        ManifestVersion   = $MANIFEST_VERSION
    }

    $docs = @()
    if ($cargoPkg['documentation'] -and $cargoPkg.documentation -ne "$($repoInfo.html_url)/wiki") {
        $docs += @{ DocumentLabel = 'Documentation'; DocumentUrl = $cargoPkg.documentation }
    }
    if ($repoInfo.has_wiki) {
        $docs += @{ DocumentLabel = 'Wiki'; DocumentUrl = "$($repoInfo.html_url)/wiki" }
    }
    if ($docs.Count -le 0) {
        $docs += @{ DocumentLabel = 'Documentation'; DocumentUrl = $repoInfo.html_url }
    }
    Save-WingetManifest -Path "$wingetManifestDir/$PackageId.locale.en-US.yaml" -Data @{
        PackageIdentifier   = $PackageId
        PackageVersion      = $pkgVer
        PackageLocale       = 'en-US'
        Publisher           = $Publisher
        Author              = $repoInfo.owner.login
        PackageName         = $PackageName
        License             = $cargoPkg['license']
        ShortDescription    = $cargoPkg['description']
        PackageUrl          = $repoInfo.html_url
        PublisherUrl        = $repoInfo.owner.html_url
        PublisherSupportUrl = "$($repoInfo.html_url)/issues"
        ManifestType        = 'defaultLocale'
        ManifestVersion     = $MANIFEST_VERSION
        Documentations      = $docs
        LicenseUrl          = $repoLicense.html_url
        Tags                = $cargoPkg['keywords']
        ReleaseNotes        = $latestRelease.body
        ReleaseNotesUrl     = $latestRelease.html_url
    }

    $ScoopArch = @{}
    foreach ($inst in $Installers) {
        $sArch = switch ($inst.Architecture) {
            'x64' {
                '64bit' 
            } 
            'x86' {
                '32bit' 
            } 
            'arm64' {
                'arm64' 
            } 
        }
        $ScoopArch[$sArch] = @{
            url       = $inst.InstallerUrl
            hash      = $inst.InstallerSha256 
            bin       = @($inst.NestedInstallerFiles | Where-Object { $_['PortableCommandAlias'] } | ForEach-Object { , @($_.RelativeFilePath, $_.PortableCommandAlias) })
            shortcuts = @($inst.NestedInstallerFiles | Where-Object { $_['Shortcuts'] } | ForEach-Object { , @($_.RelativeFilePath, $_.Shortcuts[0].ShortcutName) })
        } 
    }
    $ScoopManifest = @{
        version      = $pkgVer
        description  = $cargoPkg['description']
        homepage     = $repoInfo.html_url
        license      = $cargoPkg['license']
        architecture = $ScoopArch
        checkver     = @{ github = $repoInfo.html_url }
        autoupdate   = @{
            architecture = @{
                '64bit' = @{ 
                    url = $ScoopArch['64bit']?.url -replace "/$($latestRelease.tag_name)/", '/v$version/'
                }
                '32bit' = @{ 
                    url = $ScoopArch['32bit']?.url -replace "/$($latestRelease.tag_name)/", '/v$version/'
                }
                'arm64' = @{ 
                    url = $ScoopArch['arm64']?.url -replace "/$($latestRelease.tag_name)/", '/v$version/'
                }
            }
            hash         = @{
                url = '$url.sha256'
            }
        }
    }

    $scoopManifestDir = "$OutputDir/scoop/$pkgVer"
    New-Item -ItemType Directory -Path $scoopManifestDir -Force > $null
    $scoopManifestPath = "$scoopManifestDir/$($cargoPkg.name).json"

    $Json = $ScoopManifest | ConvertTo-Json -Depth 5
    $Json = $Json -replace ',\s*"[^"]+":\s*null', '' -replace '"[^"]+":\s*null,?', '' # drop nulls
    $Json = $Json -replace ',\s*"[^"]+":\s*""', '' -replace '"[^"]+":\s*"",?', '' # drop empty strings
    $Json = $Json -replace ',\s*"[^"]+":\s*\[\s*\]', '' -replace '"[^"]+":\s*\[\s*\],?', '' # drop empty arrays
    $Json = $Json -replace ',\s*"[^"]+":\s*\{\s*\}', '' -replace '"[^"]+":\s*\{\s*\},?', '' # drop empty objects
    $Json | Set-Content -LiteralPath $scoopManifestPath -Encoding UTF8

    return [PSCustomObject]@{
        PackageId         = $PackageId
        Version           = $pkgVer
        Publisher         = $Publisher
        PackageName       = $PackageName #$cargoPkg.name
        TestBins          = $TestBins 
        WingetManifestDir = (Resolve-Path -LiteralPath $wingetManifestDir).Path
        ScoopManifestPath = (Resolve-Path -LiteralPath $scoopManifestPath).Path # scoop respect only windows paths for local install
    }
}

function CallAliasHelp {
    param(
        [Parameter(Mandatory = $true)]
        $TestBins
    )
    $TestBins | ForEach-Object {
        try {
            ~ { & $_ --help } *> $null
        }
        catch {
            ~ { & $_ /? } *> $null
        }
    }
}

function Test-PackageManifests {
    param($Result)
    Write-Host '--- Validating and Testing Manifests ---' -ForegroundColor Cyan
    ~ { winget validate --disable-interactivity $Result.WingetManifestDir }
    $schema = fetch -Uri 'https://raw.githubusercontent.com/ScoopInstaller/Scoop/master/schema.json' -OutFile
    ~ { jsonschema validate $schema $Result.ScoopManifestPath }
    ~ { winget install --uninstall-previous --no-upgrade --accept-source-agreements --disable-interactivity --silent --accept-package-agreements --force --ignore-local-archive-malware-scan --manifest $Result.WingetManifestDir }
    CallAliasHelp $Result.TestBins
    ~ { winget uninstall --disable-interactivity --manifest $Result.WingetManifestDir }
    
    scoop uninstall $Result.PackageName *> $null
    ~ { scoop install --no-update-scoop $Result.ScoopManifestPath }
    ~ { scoop info $Result.PackageName }
    CallAliasHelp $Result.TestBins 
    ~ { scoop uninstall $Result.PackageName }
}

Export-ModuleMember -Function Get-CargoMetadata, New-PackageManifests, Test-PackageManifests, ConvertTo-UpperCamelCase, ConvertTo-TitleCase, '~'
