#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version,
    [string]$Repo,
    [string]$BaseUrl,
    [string]$FallbackBaseUrl,
    [string]$InstallBase,
    [string]$BinDir,
    [string]$Arch,
    [string]$AssetName,
    [switch]$SkipChecksum,
    [switch]$SkipOpenSourceDeps,
    [switch]$ConfigureLLM,
    [switch]$SkipLLMConfig,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-EnvOrDefault {
    param(
        [string]$Name,
        [string]$DefaultValue = ""
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }
    return $value.Trim()
}

function Coalesce-String {
    param([object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    return [string]$Value
}

function Test-Truthy {
    param([string]$Value)
    switch ((Coalesce-String $Value).Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "y" { return $true }
        "on" { return $true }
        default { return $false }
    }
}

function Test-Falsy {
    param([string]$Value)
    switch ((Coalesce-String $Value).Trim().ToLowerInvariant()) {
        "0" { return $true }
        "false" { return $true }
        "no" { return $true }
        "n" { return $true }
        "off" { return $true }
        default { return $false }
    }
}

function Say {
    param([string]$Message = "")
    Write-Host $Message
}

function Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Die {
    param([string]$Message)
    throw $Message
}

function Normalize-Arch {
    param([string]$RawValue)
    switch ((Coalesce-String $RawValue).Trim().ToLowerInvariant()) {
        "amd64" { return "x86_64" }
        "x64" { return "x86_64" }
        "x86_64" { return "x86_64" }
        "arm64" { return "arm64" }
        "aarch64" { return "arm64" }
        default { return (Coalesce-String $RawValue).Trim().ToLowerInvariant() }
    }
}

function Default-AssetName {
    param([string]$NormalizedArch)
    return "archi-windows-$NormalizedArch.zip"
}

function Trim-TrailingSlash {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }
    return $Value.TrimEnd("/")
}

function Get-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }
    return $command.Source
}

function Install-WingetPackage {
    param(
        [string]$PackageId,
        [string]$Label
    )
    $wingetPath = Get-CommandPath "winget"
    if ([string]::IsNullOrWhiteSpace($wingetPath)) {
        return $false
    }
    Warn "Missing $Label. Trying to install it with winget ($PackageId)."
    & $wingetPath install --id $PackageId --exact --source winget --accept-source-agreements --accept-package-agreements
    return ($LASTEXITCODE -eq 0)
}

function Resolve-PythonCommand {
    $candidates = @(
        @{ Command = "python"; Prefix = @() },
        @{ Command = "py"; Prefix = @("-3") },
        @{ Command = "py"; Prefix = @() }
    )
    foreach ($candidate in $candidates) {
        $commandPath = Get-CommandPath $candidate.Command
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            continue
        }
        try {
            & $candidate.Command @($candidate.Prefix + @("-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)")) | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return [pscustomobject]@{
                    Command = $candidate.Command
                    Prefix  = [string[]]$candidate.Prefix
                }
            }
        } catch {
        }
    }
    return $null
}

function Ensure-Python {
    $resolved = Resolve-PythonCommand
    if ($null -ne $resolved) {
        return $resolved
    }
    if (Install-WingetPackage -PackageId "Python.Python.3.11" -Label "Python 3.11") {
        $resolved = Resolve-PythonCommand
        if ($null -ne $resolved) {
            return $resolved
        }
    }
    Die "Python 3.11 or newer is required on Windows. Install it, reopen PowerShell, and re-run the installer."
}

function Invoke-Python {
    param(
        [pscustomobject]$PythonCommand,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    & $PythonCommand.Command @($PythonCommand.Prefix + $Arguments)
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
        Die "Python command failed: $($PythonCommand.Command) $($Arguments -join ' ')"
    }
    return $LASTEXITCODE
}

function Ensure-Pip {
    param([pscustomobject]$PythonCommand)
    Invoke-Python -PythonCommand $PythonCommand -Arguments @("-m", "pip", "--version") -AllowFailure | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return
    }
    Warn "Python is available but pip is missing. Trying python -m ensurepip."
    Invoke-Python -PythonCommand $PythonCommand -Arguments @("-m", "ensurepip", "--upgrade") -AllowFailure | Out-Null
    Invoke-Python -PythonCommand $PythonCommand -Arguments @("-m", "pip", "--version") -AllowFailure | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return
    }
    Die "python -m pip is still unavailable. Install pip for the detected Python runtime and re-run."
}

function Test-PythonCanUseUserSite {
    param([pscustomobject]$PythonCommand)
    Invoke-Python -PythonCommand $PythonCommand -Arguments @(
        "-c",
        "import sys; in_venv = bool(getattr(sys, 'real_prefix', None) or sys.prefix != getattr(sys, 'base_prefix', sys.prefix)); raise SystemExit(0 if not in_venv else 1)"
    ) -AllowFailure | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-NodeAndNpm {
    $nodePath = Get-CommandPath "node"
    $npmPath = Get-CommandPath "npm"
    if (-not [string]::IsNullOrWhiteSpace($nodePath) -and -not [string]::IsNullOrWhiteSpace($npmPath)) {
        return
    }
    if (Install-WingetPackage -PackageId "OpenJS.NodeJS.LTS" -Label "Node.js LTS") {
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        $nodePath = Get-CommandPath "node"
        $npmPath = Get-CommandPath "npm"
        if (-not [string]::IsNullOrWhiteSpace($nodePath) -and -not [string]::IsNullOrWhiteSpace($npmPath)) {
            return
        }
    }
    Die "Node.js and npm are required to install repomix on Windows. Install Node.js LTS, reopen PowerShell, and re-run."
}

function Ensure-Git {
    $gitPath = Get-CommandPath "git"
    if (-not [string]::IsNullOrWhiteSpace($gitPath)) {
        return
    }
    if (Install-WingetPackage -PackageId "Git.Git" -Label "Git") {
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        $gitPath = Get-CommandPath "git"
        if (-not [string]::IsNullOrWhiteSpace($gitPath)) {
            return
        }
    }
    Die "Git is required for the installer fallback path. Install Git, reopen PowerShell, and re-run."
}

function Ensure-PathContains {
    param([string]$PathEntry)
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $currentParts = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $currentParts = $userPath.Split(";") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    if ($currentParts -notcontains $PathEntry) {
        $updated = @($currentParts + $PathEntry) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $updated, "User")
    }
    $runtimeParts = $env:Path.Split(";") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($runtimeParts -notcontains $PathEntry) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function New-TemporaryDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("architec-install-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Get-AuthHeaders {
    $token = Get-EnvOrDefault -Name "GITHUB_TOKEN"
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = Get-EnvOrDefault -Name "GH_TOKEN"
    }
    $headers = @{
        "User-Agent" = "Architec-Windows-Installer"
        "Accept" = "application/vnd.github+json"
    }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers["Authorization"] = "Bearer $token"
        $headers["X-GitHub-Api-Version"] = "2022-11-28"
    }
    return $headers
}

function Invoke-WebRequestCompat {
    param(
        [string]$Uri,
        [string]$OutFile,
        [hashtable]$Headers
    )
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Headers $Headers -UseBasicParsing
        return
    }
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Headers $Headers
}

function Invoke-RestMethodCompat {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -UseBasicParsing
    }
    return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
}

function Resolve-ReleaseMetadata {
    param(
        [string]$TargetRepo,
        [string]$VersionSelector,
        [string]$RequestedAssetName
    )
    $headers = Get-AuthHeaders
    $apiUrl = if ($VersionSelector -eq "latest") {
        "https://api.github.com/repos/$TargetRepo/releases/latest"
    } else {
        "https://api.github.com/repos/$TargetRepo/releases/tags/$VersionSelector"
    }
    try {
        $release = Invoke-RestMethodCompat -Uri $apiUrl -Headers $headers
    } catch {
        Die "Failed to resolve release metadata from $TargetRepo ($VersionSelector). $($_.Exception.Message)"
    }

    $result = [ordered]@{
        TagName            = [string]$release.tag_name
        DownloadUrl        = ""
        ChecksumsUrl       = ""
        HippocampusWheelUrl = ""
        LLMGatewayWheelUrl = ""
        SkillsArchiveUrl   = ""
        InstallScriptPs1Url = ""
    }

    foreach ($asset in @($release.assets)) {
        $name = [string]$asset.name
        $url = [string]$asset.browser_download_url
        switch -Regex ($name) {
            "^$([regex]::Escape($RequestedAssetName))$" { $result.DownloadUrl = $url }
            "^SHA256SUMS\.txt$" { $result.ChecksumsUrl = $url }
            "^hippocampus-.*\.whl$" { $result.HippocampusWheelUrl = $url }
            "^llmgateway-.*\.whl$" { $result.LLMGatewayWheelUrl = $url }
            "^architec-skills\.tar\.gz$" { $result.SkillsArchiveUrl = $url }
            "^install_prod\.ps1$" { $result.InstallScriptPs1Url = $url }
        }
    }

    if ([string]::IsNullOrWhiteSpace($result.TagName) -or [string]::IsNullOrWhiteSpace($result.DownloadUrl)) {
        Die "The release metadata for $TargetRepo did not contain the expected asset $RequestedAssetName."
    }
    return [pscustomobject]$result
}

function Download-FileWithFallback {
    param(
        [string]$Label,
        [string]$OutputPath,
        [string]$PrimaryUrl,
        [string]$FallbackUrl = ""
    )

    foreach ($candidateUrl in @($PrimaryUrl, $FallbackUrl)) {
        if ([string]::IsNullOrWhiteSpace($candidateUrl)) {
            continue
        }
        Say "Downloading $Label from $candidateUrl"
        try {
            Invoke-WebRequestCompat -Uri $candidateUrl -OutFile $OutputPath -Headers (Get-AuthHeaders)
            return
        } catch {
            if ($candidateUrl -eq $FallbackUrl -or [string]::IsNullOrWhiteSpace($FallbackUrl)) {
                Die "Failed to download $Label from $candidateUrl. $($_.Exception.Message)"
            }
            Warn "Primary download failed for $Label. Retrying from fallback source."
        }
    }
    Die "Failed to download $Label."
}

function Verify-Checksum {
    param(
        [string]$ArchivePath,
        [string]$ChecksumsPath,
        [string]$ExpectedAssetName
    )
    $expectedHash = ""
    foreach ($line in Get-Content -Path $ChecksumsPath -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }
        $parts = $trimmed -split "\s+"
        if ($parts.Length -ge 2 -and $parts[-1] -eq $ExpectedAssetName) {
            $expectedHash = $parts[0].Trim().ToLowerInvariant()
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        Die "Checksum entry not found for $ExpectedAssetName."
    }
    $actualHash = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Die "Checksum mismatch for $ExpectedAssetName. Expected $expectedHash, got $actualHash."
    }
}

function Install-PythonWheelPackage {
    param(
        [pscustomobject]$PythonCommand,
        [string]$Label,
        [string]$WheelUrl,
        [string]$TempDir
    )
    $wheelName = [System.IO.Path]::GetFileName(($WheelUrl -split "\?")[0])
    $wheelPath = Join-Path $TempDir $wheelName
    Download-FileWithFallback -Label "$Label wheel" -OutputPath $wheelPath -PrimaryUrl $WheelUrl

    $pipArgs = @("-m", "pip", "install")
    if (Test-PythonCanUseUserSite -PythonCommand $PythonCommand) {
        $pipArgs += "--user"
    }
    $pipArgs += @("--upgrade", "--force-reinstall", $wheelPath)
    foreach ($extraWheel in Get-ChildItem -Path $TempDir -Filter *.whl -ErrorAction SilentlyContinue) {
        if ($extraWheel.FullName -ne $wheelPath) {
            $pipArgs += $extraWheel.FullName
        }
    }

    Say "Installing or upgrading open-source dependency: $Label"
    Invoke-Python -PythonCommand $PythonCommand -Arguments $pipArgs | Out-Null
}

function Install-PythonGitPackage {
    param(
        [pscustomobject]$PythonCommand,
        [string]$Label,
        [string]$GitUrl,
        [string]$TempDir
    )
    Ensure-Git
    $pipArgs = @("-m", "pip", "install")
    if (Test-PythonCanUseUserSite -PythonCommand $PythonCommand) {
        $pipArgs += "--user"
    }
    $pipArgs += @("--upgrade", "--force-reinstall", "--find-links", $TempDir, $GitUrl)
    Say "Installing or upgrading open-source dependency: $Label"
    Invoke-Python -PythonCommand $PythonCommand -Arguments $pipArgs | Out-Null
}

function Install-OpenSourceDependencies {
    param(
        [pscustomobject]$PythonCommand,
        [string]$TempDir,
        [string]$HippocampusWheelUrl,
        [string]$LLMGatewayWheelUrl,
        [string]$HippocampusGitUrl,
        [string]$LLMGatewayGitUrl
    )
    Say "Architec also uses two open-source Python packages:"
    Say "- hippocampus"
    Say "- llmgateway"
    Say "The installer will prefer bundled release wheels when available, then fall back to git sources."

    if (-not [string]::IsNullOrWhiteSpace($LLMGatewayWheelUrl)) {
        Install-PythonWheelPackage -PythonCommand $PythonCommand -Label "llmgateway" -WheelUrl $LLMGatewayWheelUrl -TempDir $TempDir
    } else {
        Install-PythonGitPackage -PythonCommand $PythonCommand -Label "llmgateway" -GitUrl $LLMGatewayGitUrl -TempDir $TempDir
    }

    if (-not [string]::IsNullOrWhiteSpace($HippocampusWheelUrl)) {
        Install-PythonWheelPackage -PythonCommand $PythonCommand -Label "hippocampus" -WheelUrl $HippocampusWheelUrl -TempDir $TempDir
    } else {
        Install-PythonGitPackage -PythonCommand $PythonCommand -Label "hippocampus" -GitUrl $HippocampusGitUrl -TempDir $TempDir
    }
}

function Install-Repomix {
    param(
        [string]$InstallRoot,
        [string]$ToolsBinDir
    )
    $existing = Get-CommandPath "repomix"
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Say "repomix is already available in PATH"
        return
    }

    Ensure-NodeAndNpm

    $packageDir = Join-Path (Join-Path $InstallRoot "node-tools") "repomix"
    $packageBin = Join-Path $packageDir "node_modules\.bin\repomix.cmd"
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

    Say "Installing repository structure helper: repomix"
    & npm install --prefix $packageDir --no-fund --no-audit repomix
    if ($LASTEXITCODE -ne 0) {
        Die "Failed to install repomix automatically. Install Node.js LTS and re-run."
    }
    if (-not (Test-Path $packageBin)) {
        Die "repomix installation completed but the launcher is missing at $packageBin"
    }
    Copy-Item -Path $packageBin -Destination (Join-Path $ToolsBinDir "repomix.cmd") -Force
}

function Copy-IfMissing {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    if (-not (Test-Path $SourcePath)) {
        Die "Missing bundled config template: $SourcePath"
    }
    if (Test-Path $DestinationPath) {
        return
    }
    $destinationDir = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
}

function Write-TextFileIfMissing {
    param(
        [string]$PathValue,
        [string]$Content
    )
    if (Test-Path $PathValue) {
        return
    }
    $directory = Split-Path -Parent $PathValue
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [System.IO.File]::WriteAllText($PathValue, $Content, [System.Text.Encoding]::UTF8)
}

function Normalize-LoginMethod {
    param([string]$Value)
    switch ((Coalesce-String $Value).Trim().ToLowerInvariant()) {
        "browser" { return "browser" }
        "web" { return "browser" }
        "activation" { return "activation_code" }
        "activation_code" { return "activation_code" }
        "activation-code" { return "activation_code" }
        "code" { return "activation_code" }
        "manual" { return "activation_code" }
        default { return "" }
    }
}

function Load-ExistingLoginMethod {
    param([string]$PreferencesPath)
    if (-not (Test-Path $PreferencesPath)) {
        return ""
    }
    try {
        $payload = Get-Content -Path $PreferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return (Normalize-LoginMethod -Value ([string]$payload.login_method))
    } catch {
        return ""
    }
}

function Write-AuthPreferences {
    param(
        [string]$PreferencesPath,
        [string]$Method
    )
    $directory = Split-Path -Parent $PreferencesPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $payload = @{ login_method = $Method } | ConvertTo-Json -Depth 2
    [System.IO.File]::WriteAllText($PreferencesPath, ($payload + [Environment]::NewLine), [System.Text.Encoding]::UTF8)
}

function Should-ConfigureLLMNow {
    param(
        [bool]$ForceConfigure,
        [bool]$ForceSkip,
        [string]$GatewayConfigPath,
        [bool]$HasCredentials
    )
    if ($ForceConfigure) {
        return $true
    }
    if ($ForceSkip) {
        return $false
    }
    if (Test-Path $GatewayConfigPath) {
        return $false
    }
    if ($HasCredentials) {
        return $true
    }
    return [Environment]::UserInteractive
}

function Prompt-Value {
    param(
        [string]$PromptText,
        [string]$DefaultValue = ""
    )
    if (-not [Environment]::UserInteractive) {
        return $DefaultValue
    }
    $suffix = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { "" } else { " [$DefaultValue]" }
    $reply = Read-Host "$PromptText$suffix"
    if ([string]::IsNullOrWhiteSpace($reply)) {
        return $DefaultValue
    }
    return $reply.Trim()
}

function Ensure-Skills {
    param(
        [pscustomobject]$PythonCommand,
        [string]$TempDir,
        [string]$SkillsArchiveUrl,
        [string]$SourceRepo,
        [string]$ReleaseTag,
        [string]$CodexSkillsDir,
        [string]$ClaudeSkillsDir
    )
    $extractDir = Join-Path $TempDir "architec-skills"
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    $sourceRoot = $null

    if (-not [string]::IsNullOrWhiteSpace($SkillsArchiveUrl)) {
        $archivePath = Join-Path $TempDir "architec-skills.tar.gz"
        try {
            Download-FileWithFallback -Label "Architec skills archive" -OutputPath $archivePath -PrimaryUrl $SkillsArchiveUrl
            Invoke-Python -PythonCommand $PythonCommand -Arguments @(
                "-c",
                @"
from pathlib import Path
import sys
import tarfile

archive_path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
output_dir.mkdir(parents=True, exist_ok=True)
with tarfile.open(archive_path, "r:gz") as archive:
    archive.extractall(output_dir)
for required in ("codex_skills", "claude_skills"):
    if not (output_dir / required).is_dir():
        raise SystemExit(f"missing bundled skill directory: {required}")
"@,
                $archivePath,
                $extractDir
            ) | Out-Null
            $sourceRoot = $extractDir
        } catch {
            Warn "Failed to extract bundled Architec skills archive. Falling back to GitHub source archive."
        }
    }

    if ($null -eq $sourceRoot) {
        $refs = @()
        if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
            $refs += $ReleaseTag
        }
        $refs += @("master", "main", "source-bootstrap")
        foreach ($ref in $refs) {
            $archiveUrl = if ($ref.StartsWith("v")) {
                "https://github.com/$SourceRepo/archive/refs/tags/$ref.zip"
            } else {
                "https://github.com/$SourceRepo/archive/refs/heads/$ref.zip"
            }
            $archivePath = Join-Path $TempDir "architec-source.zip"
            try {
                Say "Fetching Architec skill bundle from $SourceRepo ($ref)"
                Download-FileWithFallback -Label "Architec source archive" -OutputPath $archivePath -PrimaryUrl $archiveUrl
                $zipExtractDir = Join-Path $extractDir "source"
                if (Test-Path $zipExtractDir) {
                    Remove-Item -Recurse -Force $zipExtractDir
                }
                Expand-Archive -Path $archivePath -DestinationPath $zipExtractDir -Force
                $root = Get-ChildItem -Path $zipExtractDir -Directory | Select-Object -First 1
                if ($null -ne $root -and (Test-Path (Join-Path $root.FullName "codex_skills")) -and (Test-Path (Join-Path $root.FullName "claude_skills"))) {
                    $sourceRoot = $root.FullName
                    break
                }
            } catch {
            }
        }
    }

    if ($null -eq $sourceRoot) {
        Warn "Could not download Architec skills. Codex / Claude skills were not synchronized."
        return
    }

    foreach ($pair in @(
        @{ Source = (Join-Path $sourceRoot "codex_skills"); Target = $CodexSkillsDir; Label = "Codex" },
        @{ Source = (Join-Path $sourceRoot "claude_skills"); Target = $ClaudeSkillsDir; Label = "Claude" }
    )) {
        if (-not (Test-Path $pair.Source)) {
            Warn "$($pair.Label) skill source directory missing: $($pair.Source)"
            continue
        }
        New-Item -ItemType Directory -Path $pair.Target -Force | Out-Null
        foreach ($child in Get-ChildItem -Path $pair.Source -Directory) {
            $destination = Join-Path $pair.Target $child.Name
            if (Test-Path $destination) {
                Remove-Item -Recurse -Force $destination
            }
            Copy-Item -Recurse -Force -Path $child.FullName -Destination $destination
        }
        Say "Synchronized $($pair.Label) skills into $($pair.Target)"
    }
}

function Show-Usage {
    @"
Usage: install_prod.ps1 [options]

Install the compiled Architec Windows release from GitHub Releases or the site
mirror, install the open-source dependencies hippocampus and llmgateway, write
starter configs, and prepare browser or activation-code authorization.

Common examples:
  powershell -ExecutionPolicy Bypass -File .\install_prod.ps1
  powershell -ExecutionPolicy Bypass -File .\install_prod.ps1 -Version v0.2.4
"@ | Write-Host
}

if ($RemainingArgs -contains "--help" -or $RemainingArgs -contains "-h") {
    Show-Usage
    exit 0
}

$Repo = if ($PSBoundParameters.ContainsKey("Repo")) { $Repo } else { Get-EnvOrDefault -Name "ARCHITEC_RELEASE_REPO" -DefaultValue "bfly123/architec-releases" }
$Version = if ($PSBoundParameters.ContainsKey("Version")) { $Version } else { Get-EnvOrDefault -Name "ARCHITEC_VERSION" -DefaultValue "latest" }
$BaseUrl = Trim-TrailingSlash -Value (if ($PSBoundParameters.ContainsKey("BaseUrl")) { $BaseUrl } else { Get-EnvOrDefault -Name "ARCHITEC_DOWNLOAD_BASE_URL" })
$FallbackBaseUrl = Trim-TrailingSlash -Value (if ($PSBoundParameters.ContainsKey("FallbackBaseUrl")) { $FallbackBaseUrl } else { Get-EnvOrDefault -Name "ARCHITEC_FALLBACK_DOWNLOAD_BASE_URL" })
$InstallBase = if ($PSBoundParameters.ContainsKey("InstallBase")) { $InstallBase } else { Get-EnvOrDefault -Name "ARCHITEC_INSTALL_BASE" -DefaultValue (Join-Path $env:LOCALAPPDATA "Architec") }
$BinDir = if ($PSBoundParameters.ContainsKey("BinDir")) { $BinDir } else { Get-EnvOrDefault -Name "ARCHITEC_BIN_DIR" -DefaultValue (Join-Path $InstallBase "bin") }
$Arch = Normalize-Arch -RawValue (if ($PSBoundParameters.ContainsKey("Arch")) { $Arch } elseif (-not [string]::IsNullOrWhiteSpace((Get-EnvOrDefault -Name "ARCHITEC_TARGET_ARCH"))) { Get-EnvOrDefault -Name "ARCHITEC_TARGET_ARCH" } else { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() })
$AssetName = if ($PSBoundParameters.ContainsKey("AssetName")) { $AssetName } else {
    $fromEnv = Get-EnvOrDefault -Name "ARCHITEC_ASSET_NAME"
    if ([string]::IsNullOrWhiteSpace($fromEnv)) { Default-AssetName -NormalizedArch $Arch } else { $fromEnv }
}
$VerifyChecksums = -not $SkipChecksum.IsPresent -and -not (Test-Falsy (Get-EnvOrDefault -Name "ARCHITEC_VERIFY_CHECKSUMS" -DefaultValue "1"))
$InstallOpenSourceDeps = -not $SkipOpenSourceDeps.IsPresent -and -not (Test-Falsy (Get-EnvOrDefault -Name "ARCHITEC_INSTALL_OPEN_SOURCE_DEPS" -DefaultValue "1"))
$ConfigureLLMBehavior = Get-EnvOrDefault -Name "ARCHITEC_CONFIGURE_LLM" -DefaultValue "auto"
$ForceConfigureLLM = $ConfigureLLM.IsPresent -or (Test-Truthy $ConfigureLLMBehavior)
$ForceSkipLLM = $SkipLLMConfig.IsPresent -or (Test-Falsy $ConfigureLLMBehavior)

$HippocampusGitUrl = Get-EnvOrDefault -Name "ARCHITEC_HIPPOCAMPUS_GIT_URL" -DefaultValue "git+https://github.com/bfly123/hippocampus.git@main"
$LLMGatewayGitUrl = Get-EnvOrDefault -Name "ARCHITEC_LLMGATEWAY_GIT_URL" -DefaultValue "git+https://github.com/bfly123/llmgateway.git@main"
$SourceRepo = Get-EnvOrDefault -Name "ARCHITEC_SOURCE_REPO" -DefaultValue "bfly123/architec"
$SkillsArchiveUrl = Get-EnvOrDefault -Name "ARCHITEC_SKILLS_ARCHIVE_URL"
$HippocampusWheelUrl = Get-EnvOrDefault -Name "ARCHITEC_HIPPOCAMPUS_WHEEL_URL"
$LLMGatewayWheelUrl = Get-EnvOrDefault -Name "ARCHITEC_LLMGATEWAY_WHEEL_URL"
$LoginMethod = Normalize-LoginMethod -Value (Get-EnvOrDefault -Name "ARCHITEC_LOGIN_METHOD")

$UserConfigBase = Get-EnvOrDefault -Name "ARCHITEC_USER_CONFIG_DIR" -DefaultValue (Join-Path $HOME ".architec")
$StateDir = $UserConfigBase
$LLMConfigPath = Get-EnvOrDefault -Name "ARCHITEC_LLM_CONFIG" -DefaultValue (Join-Path $StateDir "config.yaml")
$LLMGatewayConfigPath = Get-EnvOrDefault -Name "LLMGATEWAY_CONFIG" -DefaultValue (Join-Path (Get-EnvOrDefault -Name "LLMGATEWAY_USER_CONFIG_DIR" -DefaultValue (Join-Path $HOME ".llmgateway")) "config.yaml")
$HippocampusConfigPath = Get-EnvOrDefault -Name "HIPPOCAMPUS_LLM_CONFIG" -DefaultValue (Join-Path (Get-EnvOrDefault -Name "HIPPOCAMPUS_USER_CONFIG_DIR" -DefaultValue (Join-Path $HOME ".hippocampus")) "config.yaml")
$AuthPreferencesPath = Join-Path (Join-Path $StateDir "auth") "preferences.json"
$CodexSkillsDir = Get-EnvOrDefault -Name "ARCHITEC_CODEX_SKILLS_DIR" -DefaultValue (Join-Path $HOME ".codex\skills")
$ClaudeSkillsDir = Get-EnvOrDefault -Name "ARCHITEC_CLAUDE_SKILLS_DIR" -DefaultValue (Join-Path $HOME ".claude\skills")

$GatewayProviderType = Get-EnvOrDefault -Name "architec_llm_provider_type" -DefaultValue "openai"
$GatewayApiStyle = Get-EnvOrDefault -Name "architec_llm_api_style" -DefaultValue "openai_chat"
$GatewayBaseUrl = Get-EnvOrDefault -Name "architec_llm_main_url"
$GatewayApiKey = Get-EnvOrDefault -Name "architec_llm_main_api_key"
$GatewayMaxConcurrent = Get-EnvOrDefault -Name "architec_llm_max_concurrent" -DefaultValue "4"
$GatewayRetryMax = Get-EnvOrDefault -Name "gateway_retry_max" -DefaultValue "2"
$GatewayTimeout = Get-EnvOrDefault -Name "gateway_timeout" -DefaultValue "120"
$StrongModel = Get-EnvOrDefault -Name "architec_llm_strong_model" -DefaultValue "gpt-5.4"
$WeakModel = Get-EnvOrDefault -Name "architec_llm_weak_model" -DefaultValue "gpt-5.4-mini"
$StrongReasoning = Get-EnvOrDefault -Name "architec_llm_strong_reasoning_effort" -DefaultValue "high"
$WeakReasoning = Get-EnvOrDefault -Name "architec_llm_weak_reasoning_effort" -DefaultValue "low"

if ([string]::IsNullOrWhiteSpace($Arch) -or [string]::IsNullOrWhiteSpace($AssetName)) {
    Die "Architecture and asset name must be non-empty."
}

Say "Detected target platform: windows-$Arch"
Say "Checking local environment"

$PythonCommand = Ensure-Python
Ensure-Pip -PythonCommand $PythonCommand

$releaseTag = $Version
$downloadUrl = ""
$checksumsUrl = ""

if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
    $downloadUrl = "$BaseUrl/$AssetName"
    $checksumsUrl = "$BaseUrl/SHA256SUMS.txt"
} else {
    $releaseMetadata = Resolve-ReleaseMetadata -TargetRepo $Repo -VersionSelector $Version -RequestedAssetName $AssetName
    $releaseTag = $releaseMetadata.TagName
    $downloadUrl = $releaseMetadata.DownloadUrl
    $checksumsUrl = $releaseMetadata.ChecksumsUrl
    if ([string]::IsNullOrWhiteSpace($HippocampusWheelUrl)) {
        $HippocampusWheelUrl = $releaseMetadata.HippocampusWheelUrl
    }
    if ([string]::IsNullOrWhiteSpace($LLMGatewayWheelUrl)) {
        $LLMGatewayWheelUrl = $releaseMetadata.LLMGatewayWheelUrl
    }
    if ([string]::IsNullOrWhiteSpace($SkillsArchiveUrl)) {
        $SkillsArchiveUrl = $releaseMetadata.SkillsArchiveUrl
    }
}

if (-not [string]::IsNullOrWhiteSpace($BaseUrl) -and (
    [string]::IsNullOrWhiteSpace($HippocampusWheelUrl) -or
    [string]::IsNullOrWhiteSpace($LLMGatewayWheelUrl) -or
    [string]::IsNullOrWhiteSpace($SkillsArchiveUrl)
)) {
    try {
        $releaseMetadata = Resolve-ReleaseMetadata -TargetRepo $Repo -VersionSelector $Version -RequestedAssetName $AssetName
        if ([string]::IsNullOrWhiteSpace($HippocampusWheelUrl)) {
            $HippocampusWheelUrl = $releaseMetadata.HippocampusWheelUrl
        }
        if ([string]::IsNullOrWhiteSpace($LLMGatewayWheelUrl)) {
            $LLMGatewayWheelUrl = $releaseMetadata.LLMGatewayWheelUrl
        }
        if ([string]::IsNullOrWhiteSpace($SkillsArchiveUrl)) {
            $SkillsArchiveUrl = $releaseMetadata.SkillsArchiveUrl
        }
    } catch {
        Warn "Could not resolve dependency wheel or skill bundle URLs from GitHub release metadata. Falling back to git sources for hippocampus/llmgateway and source archive fallback for skills."
    }
}

if ($InstallOpenSourceDeps) {
    $openSourceTempDir = New-TemporaryDirectory
    try {
        Install-OpenSourceDependencies -PythonCommand $PythonCommand -TempDir $openSourceTempDir -HippocampusWheelUrl $HippocampusWheelUrl -LLMGatewayWheelUrl $LLMGatewayWheelUrl -HippocampusGitUrl $HippocampusGitUrl -LLMGatewayGitUrl $LLMGatewayGitUrl
    } finally {
        if (Test-Path $openSourceTempDir) {
            Remove-Item -Recurse -Force $openSourceTempDir
        }
    }
} else {
    Say "Skipping hippocampus and llmgateway installation"
}

$tempDir = New-TemporaryDirectory
try {
    New-Item -ItemType Directory -Path $InstallBase -Force | Out-Null
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

    Install-Repomix -InstallRoot $InstallBase -ToolsBinDir $BinDir

    $archivePath = Join-Path $tempDir $AssetName
    $checksumsPath = Join-Path $tempDir "SHA256SUMS.txt"
    Download-FileWithFallback -Label $AssetName -OutputPath $archivePath -PrimaryUrl $downloadUrl -FallbackUrl (if ($FallbackBaseUrl) { "$FallbackBaseUrl/$AssetName" } else { "" })

    if ($VerifyChecksums) {
        if ([string]::IsNullOrWhiteSpace($checksumsUrl)) {
            Die "SHA256SUMS.txt was not resolved for the selected release."
        }
        Download-FileWithFallback -Label "SHA256SUMS.txt" -OutputPath $checksumsPath -PrimaryUrl $checksumsUrl -FallbackUrl (if ($FallbackBaseUrl) { "$FallbackBaseUrl/SHA256SUMS.txt" } else { "" })
        Verify-Checksum -ArchivePath $archivePath -ChecksumsPath $checksumsPath -ExpectedAssetName $AssetName
        Say "Checksum verification passed"
    } else {
        Say "Checksum verification skipped"
    }

    Expand-Archive -Path $archivePath -DestinationPath $tempDir -Force
    $packageDir = Join-Path $tempDir "archi-windows-$Arch"
    if (-not (Test-Path $packageDir)) {
        Die "Extracted package not found: $packageDir"
    }

    $targetDir = Join-Path $InstallBase "windows-$Arch"
    if (Test-Path $targetDir) {
        Remove-Item -Recurse -Force $targetDir
    }
    Move-Item -Path $packageDir -Destination $targetDir

    $binaryPath = Join-Path $targetDir "archi.exe"
    if (-not (Test-Path $binaryPath)) {
        Die "Installed binary is missing: $binaryPath"
    }
    Copy-Item -Path $binaryPath -Destination (Join-Path $BinDir "archi.exe") -Force
    Ensure-PathContains -PathEntry $BinDir

    Copy-IfMissing -SourcePath (Join-Path $targetDir "config\rubric.json") -DestinationPath (Join-Path $StateDir "rubric.json")
    Copy-IfMissing -SourcePath (Join-Path $targetDir "config\scoring-policy.json") -DestinationPath (Join-Path $StateDir "scoring-policy.json")

    Write-TextFileIfMissing -PathValue $LLMConfigPath -Content @"
version: 1
tasks:
  architect_history:
    tier: strong
  architect_feature:
    tier: strong
  architect_component_scoring:
    tier: weak
  architect_component_qa:
    tier: strong
  architect_folder_naming:
    tier: weak
  architect_topology_review:
    tier: weak
  architect_full_report_md:
    tier: strong
  architect_orchestrator:
    tier: strong
  architec_summary:
    tier: strong
"@

    Write-TextFileIfMissing -PathValue $HippocampusConfigPath -Content @"
version: 1
tasks:
  phase_1:
    tier: weak
  phase_2a:
    tier: strong
  phase_2b:
    tier: weak
  phase_3a:
    tier: weak
  phase_3b:
    tier: strong
  architect:
    tier: strong
"@

    $hasCredentials = (-not [string]::IsNullOrWhiteSpace($GatewayBaseUrl)) -and (-not [string]::IsNullOrWhiteSpace($GatewayApiKey))
    $shouldConfigureLLM = Should-ConfigureLLMNow -ForceConfigure $ForceConfigureLLM -ForceSkip $ForceSkipLLM -GatewayConfigPath $LLMGatewayConfigPath -HasCredentials $hasCredentials

    if ($shouldConfigureLLM -and -not (Test-Path $LLMGatewayConfigPath)) {
        Say ""
        Say "LLMGateway setup"
        Say "Most users only need to fill the base URL and API key now."
        Say "provider_type=$GatewayProviderType, api_style=$GatewayApiStyle"
        $GatewayBaseUrl = Prompt-Value -PromptText "LLMGateway base URL" -DefaultValue $GatewayBaseUrl
        $GatewayApiKey = Prompt-Value -PromptText "LLMGateway API key (leave blank to fill later)" -DefaultValue $GatewayApiKey
        $GatewayMaxConcurrent = Prompt-Value -PromptText "LLMGateway max concurrent" -DefaultValue $GatewayMaxConcurrent
        $GatewayRetryMax = Prompt-Value -PromptText "LLMGateway retry max" -DefaultValue $GatewayRetryMax
        $GatewayTimeout = Prompt-Value -PromptText "LLMGateway timeout" -DefaultValue $GatewayTimeout
        $StrongModel = Prompt-Value -PromptText "LLMGateway strong model" -DefaultValue $StrongModel
        $WeakModel = Prompt-Value -PromptText "LLMGateway weak model" -DefaultValue $WeakModel
        $StrongReasoning = Prompt-Value -PromptText "LLMGateway strong reasoning effort" -DefaultValue $StrongReasoning
        $WeakReasoning = Prompt-Value -PromptText "LLMGateway weak reasoning effort" -DefaultValue $WeakReasoning
    }

    if (-not (Test-Path $LLMGatewayConfigPath)) {
        Write-TextFileIfMissing -PathValue $LLMGatewayConfigPath -Content @"
# llmgateway config for Architec
# Common case: keep provider_type and api_style as-is, then only fill provider.base_url
# and provider.api_key. The settings block already contains the recommended defaults.
version: 1

provider:
  provider_type: "$GatewayProviderType"
  api_style: "$GatewayApiStyle"
  base_url: "$GatewayBaseUrl"
  api_key: "$GatewayApiKey"
  headers: {}
  model_map: {}

settings:
  strong_model: "$StrongModel"
  weak_model: "$WeakModel"
  strong_reasoning_effort: "$StrongReasoning"
  weak_reasoning_effort: "$WeakReasoning"
  max_concurrent: $GatewayMaxConcurrent
  retry_max: $GatewayRetryMax
  timeout: $GatewayTimeout
"@
        if ([string]::IsNullOrWhiteSpace($GatewayBaseUrl) -or [string]::IsNullOrWhiteSpace($GatewayApiKey)) {
            Warn "Created a starter llmgateway config template at $LLMGatewayConfigPath. Fill provider.base_url and provider.api_key before running hippo or archi."
        } else {
            Say "Saved llmgateway config to $LLMGatewayConfigPath"
        }
    } else {
        Say "Keeping existing llmgateway config at $LLMGatewayConfigPath"
    }

    if ([string]::IsNullOrWhiteSpace($LoginMethod)) {
        $LoginMethod = Load-ExistingLoginMethod -PreferencesPath $AuthPreferencesPath
    }
    if ([string]::IsNullOrWhiteSpace($LoginMethod)) {
        if ([Environment]::UserInteractive) {
            Say ""
            Say "Choose the default activation method for archi login"
            Say "  1. Browser authorization"
            Say "  2. Activation code"
            $reply = Read-Host "Selection [1]"
            if ((Coalesce-String $reply).Trim() -eq "2") {
                $LoginMethod = "activation_code"
            } else {
                $LoginMethod = "browser"
            }
        } else {
            $LoginMethod = "browser"
        }
    }
    Write-AuthPreferences -PreferencesPath $AuthPreferencesPath -Method $LoginMethod
    Say "Default activation method: $LoginMethod"

    Ensure-Skills -PythonCommand $PythonCommand -TempDir $tempDir -SkillsArchiveUrl $SkillsArchiveUrl -SourceRepo $SourceRepo -ReleaseTag $releaseTag -CodexSkillsDir $CodexSkillsDir -ClaudeSkillsDir $ClaudeSkillsDir

    Say ""
    Say "Installed Architec $releaseTag to $targetDir"
    Say "Installed launcher $(Join-Path $BinDir 'archi.exe')"
    Say "Binary: $binaryPath"
    if ($InstallOpenSourceDeps) {
        Say "Ensured open-source Python dependencies from release wheels or git: hippocampus, llmgateway"
    }
    Say "Repository structure helper: $(Join-Path $BinDir 'repomix.cmd')"
    Say "Architec task config: $LLMConfigPath"
    Say "Hippocampus task config: $HippocampusConfigPath"
    Say "LLMGateway config: $LLMGatewayConfigPath"
    Say "Login preference: $LoginMethod"
    Say "Codex skills: $CodexSkillsDir"
    Say "Claude skills: $ClaudeSkillsDir"
    if (-not [string]::IsNullOrWhiteSpace($GatewayBaseUrl) -and -not [string]::IsNullOrWhiteSpace($GatewayApiKey)) {
        if ($LoginMethod -eq "activation_code") {
            Say "Next step: run archi login, note the machine code, then generate an activation code at https://www.architec.top/account"
        } else {
            Say "Next step: archi login"
        }
    } else {
        if ($LoginMethod -eq "activation_code") {
            Say "Next step: fill provider.base_url and provider.api_key in $LLMGatewayConfigPath, then run archi login and use the machine code at https://www.architec.top/account"
        } else {
            Say "Next step: fill provider.base_url and provider.api_key in $LLMGatewayConfigPath, then run archi login"
        }
    }
    Say "Open a new PowerShell window if the updated PATH is not visible in the current session."
} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Recurse -Force $tempDir
    }
}
