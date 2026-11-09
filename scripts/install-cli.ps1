# Installs the Viaalink CLI on Windows with the official installer, the same
# way the CLI's own terminal workflow does. REQUESTED_VERSION: latest, a
# release tag or a nightly tag.
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
Invoke-RestMethod https://raw.githubusercontent.com/viaalink/cli/main/install.ps1 | Invoke-Expression
"$env:LOCALAPPDATA\via\bin" | Out-File -FilePath $env:GITHUB_PATH -Append
