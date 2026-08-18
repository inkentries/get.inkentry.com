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
# Options:
#   --dry-run             print what would happen and write nothing
#
#   curl -fsSL https://get.inkentry.com/install.sh | sh -s -- --dry-run
#
# Overrides:
#   INKENTRY_VERSION      install a specific tag (default: latest release)
#   INKENTRY_INSTALL_DIR  install directory (default: /usr/local/bin when
#                         writable, otherwise ~/.local/bin)
#   INKENTRY_DRY_RUN      set to any value for --dry-run, matching migrate.sh
#
# Release assets are named from the git tag, not the bare version: the release
# workflow builds them as inkentry-${{ github.ref_name }}-<target>, so the `v`
# is part of the filename. If that naming ever changes, change it here too.

set -eu

REPO="inkentries/inkentry"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

main() {
  dry_run=${INKENTRY_DRY_RUN:+1}
  dry_run=${dry_run:-0}

  # An unrecognised option is an error, never a silent no-op. A preview flag
  # that is quietly ignored installs when it promised not to, which is worse
  # than not offering one.
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        say "usage: install.sh [--dry-run]"
        say ""
        say "  --dry-run   print what would happen and write nothing"
        say ""
        say "environment: INKENTRY_VERSION, INKENTRY_INSTALL_DIR, INKENTRY_DRY_RUN"
        return 0
        ;;
      *) fail "unknown option: $1 (supported: --dry-run, --help)" ;;
    esac
    shift
  done

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
    # stderr is discarded because a 404 here is the expected state during a
    # release-candidate cycle, handled by the fallback below. Left visible it
    # prints `curl: (56) ... 404` above a successful install, which reads as a
    # failure the user is supposed to act on.
    tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
      sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

    # `/releases/latest` excludes pre-releases and 404s when every release is
    # one, which is the state during a release-candidate cycle. Falling back to
    # the newest release of any kind is what makes an -rc installable; once a
    # stable release exists it wins and this never runs.
    if [ -z "$tag" ]; then
      tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1" |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
      [ -z "$tag" ] || say "no stable release yet — installing the pre-release $tag"
    fi

    [ -n "$tag" ] || fail "could not determine a release from the GitHub API"
  fi
  archive="inkentry-${tag}-${target}.tar.gz"
  url="https://github.com/$REPO/releases/download/$tag/$archive"

  if [ -n "${INKENTRY_INSTALL_DIR:-}" ]; then
    install_dir="$INKENTRY_INSTALL_DIR"
  elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    install_dir="/usr/local/bin"
  else
    install_dir="$HOME/.local/bin"
  fi

  # Everything above this point only reads. Everything below it writes.
  if [ "$dry_run" -eq 1 ]; then
    say "dry run: nothing is downloaded, written or changed."
    say ""
    say "  platform     $os $arch ($target)"
    say "  release      $tag"
    say "  archive      $url"
    say "  install to   $install_dir/inkentry"
    say "               $install_dir/inkentry-server"
    [ -d "$install_dir" ] || say "  create       $install_dir"
    case ":$PATH:" in
      *":$install_dir:"*) ;;
      *) say "  PATH         $install_dir is not on it; a real run says so and changes nothing" ;;
    esac
    say ""
    if curl -fsSI --proto '=https' "$url" >/dev/null 2>&1; then
      say "the release archive is reachable, so a real run would find it."
    else
      say "warning: the release archive is NOT reachable at that URL, so a real run would fail."
    fi
    return 0
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
