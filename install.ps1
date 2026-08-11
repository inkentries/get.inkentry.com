# inkentry installer for Windows — https://get.inkentry.com/install.ps1
#
#   iex ((New-Object Net.WebClient).DownloadString('https://get.inkentry.com/install.ps1'))
#
# That invocation is deliberate: GitHub Pages serves .ps1 files as
# application/octet-stream, and `irm | iex` can hand back a byte array instead
# of a string for that content type. DownloadString ignores the content type.
#
# Installs the latest inkentry release to $env:LOCALAPPDATA\Programs\inkentry
# and adds it to the user PATH. Scoop is the other supported route — see
# https://inkentry.com/docs/getting-started
#
# Overrides:
#   $env:INKENTRY_VERSION      install a specific tag (default: latest)
#   $env:INKENTRY_INSTALL_DIR  install directory

$ErrorActionPreference = 'Stop'

$repo = 'inkentries/inkentry'

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
  throw "install.ps1: no prebuilt Windows binary for $arch (x64 only). Build from source: https://github.com/$repo"
}
$target = 'x86_64-pc-windows-msvc'

if ($env:INKENTRY_VERSION) {
  $tag = $env:INKENTRY_VERSION
} else {
  $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
  $tag = $release.tag_name
}
$version = $tag -replace '^v', ''

$archive = "inkentry-$version-$target.zip"
$url = "https://github.com/$repo/releases/download/$tag/$archive"

if ($env:INKENTRY_INSTALL_DIR) {
  $installDir = $env:INKENTRY_INSTALL_DIR
} else {
  $installDir = Join-Path $env:LOCALAPPDATA 'Programs\inkentry'
}
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  Write-Host "downloading inkentry $tag for $target"
  $zipPath = Join-Path $tmp $archive
  Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

  Expand-Archive -Path $zipPath -DestinationPath $tmp -Force

  foreach ($bin in 'inkentry.exe', 'inkentry-server.exe') {
    $src = Join-Path $tmp $bin
    if (-not (Test-Path $src)) { throw "install.ps1: archive did not contain $bin" }
    Copy-Item $src (Join-Path $installDir $bin) -Force
  }
} finally {
  Remove-Item -Recurse -Force $tmp
}

Write-Host "installed inkentry $tag to $installDir"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $installDir) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$installDir", 'User')
  $env:Path = "$env:Path;$installDir"
  Write-Host "added $installDir to your user PATH (new terminals will pick it up)"
}

Write-Host ''
Write-Host "next: run 'inkentry init' inside a repository."
Write-Host 'docs: https://inkentry.com/docs/getting-started'
