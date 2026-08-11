#!/bin/sh
#
# inkentry installer — https://get.inkentry.com/install.sh
#
#   curl -fsSL https://get.inkentry.com/install.sh | sh
#
# Downloads the latest inkentry release for this machine and installs the
# `inkentry` and `inkentry-server` binaries. No telemetry, no account, and the
# script never invokes sudo on its own.
#
# Overrides:
#   INKENTRY_VERSION      install a specific tag (default: latest release)
#   INKENTRY_INSTALL_DIR  install directory (default: /usr/local/bin when
#                         writable, otherwise ~/.local/bin)
#
# Release assets are expected as inkentry-<version>-<target>.tar.gz, matching
# the release workflow. If that naming ever changes, change it here too.

set -eu

REPO="inkentries/inkentry"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

main() {
  os=$(uname -s)
  arch=$(uname -m)

  case "$os" in
    Darwin)
      case "$arch" in
        arm64 | aarch64) target="aarch64-apple-darwin" ;;
        *) fail "no prebuilt binary for macOS on $arch (Apple silicon only). On Intel Macs, build from source: https://github.com/$REPO" ;;
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64 | amd64) target="x86_64-unknown-linux-gnu" ;;
        arm64 | aarch64) target="aarch64-unknown-linux-gnu" ;;
        *) fail "no prebuilt binary for Linux on $arch. Build from source: https://github.com/$REPO" ;;
      esac
      ;;
    *)
      fail "unsupported platform: $os. On Windows, use install.ps1 or Scoop — see https://inkentry.com/docs/getting-started"
      ;;
  esac

  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v tar >/dev/null 2>&1 || fail "tar is required"

  if [ -n "${INKENTRY_VERSION:-}" ]; then
    tag="$INKENTRY_VERSION"
  else
    tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
      sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$tag" ] || fail "could not determine the latest release from the GitHub API"
  fi
  version=${tag#v}

  archive="inkentry-${version}-${target}.tar.gz"
  url="https://github.com/$REPO/releases/download/$tag/$archive"

  if [ -n "${INKENTRY_INSTALL_DIR:-}" ]; then
    install_dir="$INKENTRY_INSTALL_DIR"
  elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    install_dir="/usr/local/bin"
  else
    install_dir="$HOME/.local/bin"
  fi
  mkdir -p "$install_dir"

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  say "downloading inkentry $tag for $target"
  curl -fsSL --proto '=https' -o "$tmp/$archive" "$url" ||
    fail "download failed: $url"

  tar -xzf "$tmp/$archive" -C "$tmp"

  for bin in inkentry inkentry-server; do
    [ -f "$tmp/$bin" ] || fail "archive did not contain $bin"
    install -m 0755 "$tmp/$bin" "$install_dir/$bin"
  done

  say "installed inkentry $tag to $install_dir"

  case ":$PATH:" in
    *":$install_dir:"*) "$install_dir/inkentry" --version ;;
    *)
      say ""
      say "note: $install_dir is not on your PATH. Add it, e.g.:"
      say "  export PATH=\"$install_dir:\$PATH\""
      ;;
  esac

  say ""
  say "next: run 'inkentry init' inside a repository."
  say "docs: https://inkentry.com/docs/getting-started"
}

# Wrapped in main() so a truncated download can never execute half a script.
main "$@"
