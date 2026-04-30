#Requires -Version 7.4

param(
    [string]$WingetRepo = 'microsoft/winget-pkgs',
    [string]$ScoopRepo = 'ScoopInstaller/Extras'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Import-Module "${PSScriptRoot}/generate_publish_manifests.psm1"

$user = ~ { gh api user --jq .login }

function Submit-ToGitHubRepo {
    param($UpstreamRepo, $BranchName, $CommitTitle, $SourcePath, $DestDir, $PrBody = '')

    Write-Host "--- Submitting to $UpstreamRepo ---" -ForegroundColor Cyan
    ~ { gh repo fork $UpstreamRepo --clone=false }
    $repoName = ($UpstreamRepo -split '/')[-1]

    $repoInfo = ~ { gh api "repos/$UpstreamRepo" } | ConvertFrom-Json
    $defaultBranch = $repoInfo.default_branch
    
    Write-Host "Fetching base information..."
    $upstreamBranchInfo = ~ { gh api "repos/$UpstreamRepo/branches/$defaultBranch" } | ConvertFrom-Json
    $parentSha = $upstreamBranchInfo.commit.sha
    $parentTreeSha = $upstreamBranchInfo.commit.commit.tree.sha

    # Check if branch already exists in fork to allow appending commits
    try {
        $forkBranchInfo = gh api "repos/$user/$repoName/branches/$BranchName" --ignore-stdin | ConvertFrom-Json
        if ($forkBranchInfo.commit.sha) {
            $parentSha = $forkBranchInfo.commit.sha
            $parentTreeSha = $forkBranchInfo.commit.commit.tree.sha
            Write-Host "Branch $BranchName exists in fork. New changes will be appended as a new commit."
        }
    }
    catch {
        Write-Host "Branch $BranchName does not exist in fork. Starting from $defaultBranch."
    }

    $filesToUpload = @()
    $resolvedSource = (Resolve-Path $SourcePath).Path
    $cleanDestDir = $DestDir.Replace('\', '/').TrimEnd('/')

    if (Test-Path $SourcePath -PathType Leaf) {
        $filesToUpload += [PSCustomObject]@{
            FullName = $resolvedSource
            RepoPath = "$cleanDestDir/$((Get-Item $SourcePath).Name)"
        }
    }
    else {
        Get-ChildItem -Path $SourcePath -File -Recurse | ForEach-Object {
            $rel = $_.FullName.Substring($resolvedSource.Length).TrimStart('\', '/')
            $filesToUpload += [PSCustomObject]@{
                FullName = $_.FullName
                RepoPath = "$cleanDestDir/$rel".Replace('\', '/')
            }
        }
    }

    if ($filesToUpload.Count -eq 0) {
        Write-Warning "No files to submit for $UpstreamRepo"
        return
    }

    Write-Host "Creating blobs for $($filesToUpload.Count) files..."
    $treeEntries = @()
    foreach ($file in $filesToUpload) {
        Write-Host "  Uploading $($file.RepoPath)..."
        $content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
        $blobData = @{ content = $content; encoding = 'base64' } | ConvertTo-Json
        $blob = ~ { $blobData | gh api -X POST "repos/$user/$repoName/git/blobs" --input - } | ConvertFrom-Json
        $treeEntries += @{ path = $file.RepoPath; mode = '100644'; type = 'blob'; sha = $blob.sha }
    }

    Write-Host 'Creating tree...'
    $treeData = @{ base_tree = $parentTreeSha; tree = $treeEntries } | ConvertTo-Json -Depth 10
    $newTree = ~ { $treeData | gh api -X POST "repos/$user/$repoName/git/trees" --input - } | ConvertFrom-Json

    Write-Host 'Creating commit...'
    $commitData = @{ message = $CommitTitle; tree = $newTree.sha; parents = @($parentSha) } | ConvertTo-Json
    $newCommit = ~ { $commitData | gh api -X POST "repos/$user/$repoName/git/commits" --input - } | ConvertFrom-Json

    Write-Host "Updating branch $BranchName..."
    $refName = "heads/$BranchName"
    try {
        $refData = @{ ref = "refs/$refName"; sha = $newCommit.sha } | ConvertTo-Json
        ~ { $refData | gh api -X POST "repos/$user/$repoName/git/refs" --input - } | Out-Null
    }
    catch {
        # If it already exists, update it. We don't necessarily need force=true here if we appended,
        # but it's safer to keep it for robustness.
        $refData = @{ sha = $newCommit.sha; force = $true } | ConvertTo-Json
        ~ { $refData | gh api -X PATCH "repos/$user/$repoName/git/refs/$refName" --input - } | Out-Null
    }

    Write-Host "Creating/Updating Pull Request..."
    try {
        ~ { gh pr create --repo $UpstreamRepo --title $CommitTitle --body $PrBody --head "${user}:$BranchName" --base $defaultBranch }
    }
    catch {
        Write-Host "Pull request already exists or could not be created. Since the branch was updated, the existing PR will reflect the latest changes."
    }
}

$metadata = Get-CargoMetadata 
$result = New-PackageManifests -Metadata $metadata
Test-PackageManifests -Result $result

$prBody = "Automated submission from $($metadata.RepoInfo.html_url)"

# --- Submit to WinGet ---
Submit-ToGitHubRepo `
    -UpstreamRepo $WingetRepo `
    -BranchName "winget-$($result.PackageId)-$($result.Version)" `
    -CommitTitle "Add $($result.PackageId) version $($result.Version)" `
    -SourcePath $result.WingetManifestDir `
    -DestDir "manifests/$($result.PackageId.Substring(0, 1).ToLower())/$($result.Publisher)/$($result.PackageName)/$($result.Version)" `
    -PrBody $prBody

# --- Submit to Scoop ---
Submit-ToGitHubRepo `
    -UpstreamRepo $ScoopRepo `
    -BranchName "scoop-$($result.PackageName)-$($result.Version)" `
    -CommitTitle "$((Get-Item $result.ScoopManifestPath).BaseName): Add version $($result.Version)" `
    -SourcePath $result.ScoopManifestPath `
    -DestDir 'bucket' `
    -PrBody $prBody
