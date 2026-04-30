#Requires -Version 7.4
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Import-Module "${PSScriptRoot}/generate_publish_manifests.psm1"

~ { winget show gh }
return ;

$metadata = Get-CargoMetadata 
$result = New-PackageManifests -Metadata $metadata
Test-PackageManifests -Result $result
