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
#   $env:INKENTRY_DRY_RUN      set to any value to preview without writing
#
# To preview, prefer the environment variable, because the piped invocation
# above cannot carry a parameter:
#
#   $env:INKENTRY_DRY_RUN=1; iex ((New-Object Net.WebClient).DownloadString('https://get.inkentry.com/install.ps1'))

[CmdletBinding()]
param(
  # CmdletBinding is what makes an unrecognised argument an error. Without it a
  # script or scriptblock quietly collects unbound arguments into $args, so a
  # mistyped or invented flag vanishes and the install runs anyway. That is how
  # a documented -DryRun that this script did not implement was able to perform
  # a full install, PATH change included.
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ($env:INKENTRY_DRY_RUN) { $DryRun = $true }

$repo = 'inkentries/inkentry'

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
  throw "install.ps1: no prebuilt Windows binary for $arch (x64 only). Build from source: https://github.com/$repo"
}
$target = 'x86_64-pc-windows-msvc'

if ($env:INKENTRY_VERSION) {
  $tag = $env:INKENTRY_VERSION
} else {
  # /releases/latest excludes pre-releases and 404s when every release is one,
  # which is the state during a release-candidate cycle. Falling back to the
  # newest release of any kind is what makes an -rc installable; once a stable
  # release exists it wins and the fallback never runs.
  try {
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
  } catch {
    $release = $null
  }
  if (-not $release) {
    $release = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases?per_page=1")[0]
    if ($release) {
      Write-Host "no stable release yet - installing the pre-release $($release.tag_name)"
    }
  }
  if (-not $release) {
    throw "install.ps1: could not determine a release from the GitHub API"
  }
  $tag = $release.tag_name
}

# Named from the git tag, `v` included — see the note in install.sh.
$archive = "inkentry-$tag-$target.zip"
$url = "https://github.com/$repo/releases/download/$tag/$archive"

if ($env:INKENTRY_INSTALL_DIR) {
  $installDir = $env:INKENTRY_INSTALL_DIR
} else {
  $installDir = Join-Path $env:LOCALAPPDATA 'Programs\inkentry'
}

# Everything above this point only reads. Everything below it writes, so the
# preview returns here. `return` and not `exit`: this script is normally run by
# `iex`, which evaluates it in the caller's own scope, and `exit` there would
# close the user's shell rather than end the preview.
if ($DryRun) {
  # Read defensively: the User target is a Windows registry concept, and this
  # preview must never be the thing that fails. A real run reads it again.
  $currentUserPath = ''
  try { $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User') } catch { }
  $pathAlready = ($currentUserPath -split ';') -contains $installDir

  Write-Host 'dry run: nothing is downloaded, written or changed.'
  Write-Host ''
  Write-Host "  release      $tag"
  Write-Host "  archive      $url"
  Write-Host "  install to   $installDir\inkentry.exe"
  Write-Host "               $installDir\inkentry-server.exe"
  if (-not (Test-Path $installDir)) {
    Write-Host "  create       $installDir"
  }
  if ($pathAlready) {
    Write-Host '  user PATH    already contains that directory, so it would be left alone'
  } else {
    Write-Host "  user PATH    would gain $installDir (a persistent change, under HKCU\Environment)"
  }
  Write-Host ''

  try {
    Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing | Out-Null
    Write-Host 'the release archive is reachable, so a real run would find it.'
  } catch {
    Write-Host "warning: the release archive is NOT reachable at that URL, so a real run would fail: $($_.Exception.Message)"
  }
  return
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
