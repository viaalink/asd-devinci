# Installs the Viaalink CLI on Windows with the official installer, the same
# way the CLI's own terminal workflow does. REQUESTED_VERSION: latest, a
# release tag or a nightly tag.
#
# The install is the job's own (as install-cli.sh): binaries and data
# directory in this session's state directory under RUNNER_TEMP, never the
# runner's %LOCALAPPDATA%\via, and no change to the user's PATH in the
# registry. The job's PATH and ASD_HOME/VIA_HOME point at it for the rest of
# the job, the caller's later steps included. The CLI's config directory
# (%APPDATA%\via otherwise; XDG_CONFIG_HOME wins on every platform) follows
# XDG_CONFIG_HOME, which every step of the action, this one too (the
# installer runs via --version), sets to <state>\cli\config (action.yml).
$ErrorActionPreference = "Stop"
$env:VERSION = if ($env:REQUESTED_VERSION -eq "latest" -or -not $env:REQUESTED_VERSION) { "" } else { $env:REQUESTED_VERSION }
# A nightly is a prerelease on viaalink/cli-nightly, which the installer does
# not look up; its base-URL mode fetches the archive and SHA256SUMS.txt from
# that release instead. Only the exact tag form is accepted, so the input
# cannot point the base URL at another path (\z: .NET's $ also matches before
# a trailing newline).
if ($env:VERSION -cmatch '^v?[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}T[0-9]{4}\z') {
  if (-not $env:VERSION.StartsWith("v")) { $env:VERSION = "v$env:VERSION" }
  $env:VIA_INSTALL_BASE_URL = "https://github.com/viaalink/cli-nightly/releases/download/$env:VERSION"
} elseif ($env:VERSION -like "*-nightly.*") {
  Write-Output "::error::cli-version is not a valid nightly tag; expected vX.Y.Z-nightly.YYYYMMDDTHHMM"
  exit 1
}
if (-not $env:STATE_DIR) {
  Write-Output "::error::No session state directory: the credentials step did not run."
  exit 1
}
# STATE_DIR comes from Git Bash as RUNNER_TEMP + "/ci-terminal-<name>"
# (D:\a\_temp/ci-terminal-x): one form with backslashes for PATH and the env.
$stateDir = [IO.Path]::GetFullPath($env:STATE_DIR)
$cliHome = [IO.Path]::GetFullPath((Join-Path $stateDir "cli\home"))
$cliBin = Join-Path $cliHome "bin"
$cliConfig = [IO.Path]::GetFullPath((Join-Path $stateDir "cli\config"))
New-Item -ItemType Directory -Path $cliBin -Force | Out-Null
New-Item -ItemType Directory -Path $cliConfig -Force | Out-Null
$env:ASD_HOME = $cliHome
$env:VIA_HOME = $cliHome
$env:INSTALL_DIR = $cliBin
$env:ASD_NO_MODIFY_PATH = "1"
$env:VIA_NO_MODIFY_PATH = "1"
Invoke-RestMethod https://raw.githubusercontent.com/viaalink/cli/main/install.ps1 | Invoke-Expression
if (-not (Test-Path (Join-Path $cliBin "via.exe"))) {
  Write-Output "::error::The installer finished but via.exe is not in $cliBin."
  exit 1
}
$cliBin | Out-File -FilePath $env:GITHUB_PATH -Append
"ASD_HOME=$cliHome" | Out-File -FilePath $env:GITHUB_ENV -Append
"VIA_HOME=$cliHome" | Out-File -FilePath $env:GITHUB_ENV -Append
