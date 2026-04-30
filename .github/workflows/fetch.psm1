#Requires -Version 7.4
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function fetch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD')]
        [string]$Method = 'GET',

        [object]$Body = $null,

        [string]$ContentType = 'application/json',

        [string]$CacheDir = (Join-Path $env:TEMP 'RestCache'),

        [switch]$OutFile
    )

    if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) { 
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null 
    }

    # 1. Create a unique hash based on Method, Uri, and Body
    $bodyString = ''
    if ($null -ne $Body) {
        $bodyString = if ($Body -is [string]) {
            $Body 
        }
        else {
            $Body | ConvertTo-Json -Compress 
        }
    }

    $hashInput = "$Method|$Uri|$bodyString"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashInput))).Replace('-', '').Substring(0, 16)

    # 2. Optimized search for the most recent cache file using path pattern
    $cacheFile = Get-ChildItem -Path "$CacheDir/$hash.*" | 
        Sort-Object LastWriteTime -Descending | 
        Select-Object -First 1

    $headers = @{}
    if ($cacheFile) {
        if ($OutFile) {
            return $cacheFile.FullName
        }
        $parts = $cacheFile.Name.Split('.')
        if ($parts.Count -ge 3 -and $parts[1] -ne '') {
            $base64 = $parts[1].Replace('-', '+').Replace('_', '/')
            while ($base64.Length % 4) {
                $base64 += '=' 
            }
            $headers['If-None-Match'] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64))
        }
        $headers['If-Modified-Since'] = $cacheFile.LastWriteTime.ToUniversalTime().ToString('R')
    }

    $requestParams = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { 
        $requestParams['Body'] = $bodyString
        $requestParams['ContentType'] = $ContentType
    }

    $tempFile = "$CacheDir/$hash" 

    try {
        $response = Invoke-WebRequest @requestParams -OutFile $tempFile -PassThru

        # --- Handle 200 OK (New Data) ---
        $isJson = $response.Content -is [string] -and ![string]::IsNullOrWhiteSpace($response.Content) -and $response.Headers['Content-Type'] -like '*json*'
        $extension = if ($isJson) {
            'json' 
        }
        else {
            'data' 
        }

        $etagEncoded = ''
        if ($response.Headers.ETag) {
            $etagBytes = [Text.Encoding]::UTF8.GetBytes($response.Headers.ETag)
            $etagEncoded = [Convert]::ToBase64String($etagBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
        }

        # Cleanup old cache versions
        Get-ChildItem -Path "$CacheDir/$hash.*" -Force | Remove-Item -Force

        $newFileName = "$hash.$etagEncoded.$extension"
        $newFilePath = Join-Path $CacheDir $newFileName

        $file = Rename-Item -LiteralPath $tempFile -NewName $newFilePath -Force -PassThru
        if ($response.Headers['Last-Modified']) {
            $file.LastWriteTime = [DateTime]::Parse($response.Headers['Last-Modified'])
        }

        Write-Verbose "Cache updated: $newFileName"

        if ($OutFile) {
            return $newFilePath 
        }
        if ($isJson) { 
            return $response.Content | ConvertFrom-Json -NoEnumerate 
        }
        return $response.Content
    }
    catch {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        
        $statusCode = [int]($_.Exception.Response?.StatusCode ?? 0 )
        if ($statusCode -eq 304 ) {
            if (-not $cacheFile) {
                throw 'Server returned 304, but local cache was not found.' 
            }

            Write-Verbose "304 Not Modified: Using cached file $($cacheFile.Name)"

            if ($OutFile) {
                return $cacheFile.FullName 
            }

            if ($cacheFile.Extension -eq '.json') {
                return Get-Content -LiteralPath $cacheFile.FullName -Raw | ConvertFrom-Json -NoEnumerate
            }
            return [System.IO.File]::ReadAllBytes($cacheFile.FullName)
        }
        throw $_
    }
}

Export-ModuleMember -Function fetch
