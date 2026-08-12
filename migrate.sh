#!/bin/sh
#
# spelunk → inkentry migration — https://get.inkentry.com/migrate.sh
#
#   curl -fsSL https://get.inkentry.com/migrate.sh | sh
#
# Installs inkentry, carries every spelunk memory store across, and only then
# retires spelunk. Memory entries are authored and nothing regenerates them, so
# this script is built around one rule: the old store is never modified and
# never deleted. It stays on disk as the recovery path.
#
# Stores are found by scanning the filesystem for `.spelunk/memory.db`, not by
# reading the project registry. The registry records projects that were
# *indexed*, which is not the same set as projects that have *memory* — a
# repository whose memory was only ever added, never indexed, is absent from it.
#
# Overrides:
#   INKENTRY_MIGRATE_DRY_RUN=1     report what would happen, change nothing
#   INKENTRY_MIGRATE_SCAN_ROOT     where to scan (default: $HOME)
#   INKENTRY_MIGRATE_KEEP_SPELUNK=1  migrate, but never remove the old binaries
#   INKENTRY_MIGRATE_SKIP_INSTALL=1  inkentry is already installed; use it as-is
#   INKENTRY_MIGRATE_EXPORT_TOOL   path to an existing spelunk-export binary
#                                  instead of downloading one
#   SPELUNK_VERSION                tag to take spelunk-export from (default: latest)

set -eu

SPELUNK_REPO="spelunk-cloud/spelunk"
INSTALL_URL="https://get.inkentry.com/install.sh"

DRY_RUN=${INKENTRY_MIGRATE_DRY_RUN:-}
SCAN_ROOT=${INKENTRY_MIGRATE_SCAN_ROOT:-$HOME}
KEEP_SPELUNK=${INKENTRY_MIGRATE_KEEP_SPELUNK:-}

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'migrate.sh: %s\n' "$*" >&2; }
fail() {
  printf 'migrate.sh: %s\n' "$*" >&2
  exit 1
}

# Prompts must come from the terminal, not stdin: under `curl | sh` stdin is the
# script itself, so reading it would consume the script and answer nothing.
#
# `[ -r /dev/tty ]` is not a sufficient test — the node exists and reports
# readable in environments with no controlling terminal, and only the open
# fails. So the check is an actual open, with its error suppressed.
# The probe runs in a subshell because POSIX says a redirection error on a
# *special* built-in — which `:` and `exec` both are — exits the shell outright,
# and `2>/dev/null` suppresses only the message, not the exit. dash implements
# that faithfully, so the obvious `{ : < /dev/tty; } 2>/dev/null` kills the whole
# script on Linux the moment there is no terminal. bash does not, which is why
# the naive form survives every test on macOS.
have_tty() {
  if ( exec < /dev/tty ) 2>/dev/null; then
    return 0
  fi
  return 1
}

ask_yes_no() {
  { printf '%s [y/N] ' "$1" > /dev/tty; } 2>/dev/null || return 1
  read -r reply < /dev/tty 2>/dev/null || return 1
  case "$reply" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

detect_target() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Darwin)
      case "$arch" in
        arm64 | aarch64) target="aarch64-apple-darwin" ;;
        *) fail "no prebuilt binary for macOS on $arch (Apple silicon only)" ;;
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64 | amd64) target="x86_64-unknown-linux-gnu" ;;
        arm64 | aarch64) target="aarch64-unknown-linux-gnu" ;;
        *) fail "no prebuilt binary for Linux on $arch" ;;
      esac
      ;;
    *) fail "unsupported platform: $os. On Windows, migrate by hand — see https://inkentry.com/docs/getting-started" ;;
  esac
}

fetch_export_tool() {
  if [ -n "${INKENTRY_MIGRATE_EXPORT_TOOL:-}" ]; then
    [ -x "$INKENTRY_MIGRATE_EXPORT_TOOL" ] ||
      fail "INKENTRY_MIGRATE_EXPORT_TOOL is not an executable: $INKENTRY_MIGRATE_EXPORT_TOOL"
    EXPORT_TOOL="$INKENTRY_MIGRATE_EXPORT_TOOL"
    say "using the export tool at $EXPORT_TOOL"
    return
  fi

  if [ -n "${SPELUNK_VERSION:-}" ]; then
    tag="$SPELUNK_VERSION"
  else
    tag=$(curl -fsSL "https://api.github.com/repos/$SPELUNK_REPO/releases/latest" |
      sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$tag" ] || fail "could not determine the latest spelunk release"
  fi

  archive="spelunk-export-${tag}-${target}.tar.gz"
  url="https://github.com/$SPELUNK_REPO/releases/download/$tag/$archive"

  say "downloading the export tool ($tag)"
  curl -fsSL --proto '=https' -o "$tmp/$archive" "$url" ||
    fail "could not download the export tool: $url"
  tar -xzf "$tmp/$archive" -C "$tmp"
  [ -x "$tmp/spelunk-export" ] || fail "archive did not contain spelunk-export"
  EXPORT_TOOL="$tmp/spelunk-export"
}

# Every discovered store is exported unconditionally: the export is read-only and
# its own entry count is the cheapest reliable way to tell an empty store from
# one worth migrating, without depending on sqlite3 being installed.
discover_and_export() {
  say "scanning $SCAN_ROOT for spelunk stores (this can take a minute)"

  find "$SCAN_ROOT" -type d -name .spelunk -prune -print 2>/dev/null > "$tmp/dirs.txt" || true
  total_dirs=$(wc -l < "$tmp/dirs.txt" | tr -d ' ')
  say "found $total_dirs .spelunk directories"

  n=0
  while IFS= read -r d; do
    store="$d/memory.db"
    [ -f "$store" ] || continue
    n=$((n + 1))
    dump="$tmp/dump-$n.jsonl"
    if ! "$EXPORT_TOOL" export --store "$store" --out "$dump" > /dev/null 2>&1; then
      warn "could not export $store — skipping, nothing was changed"
      printf '%s\t%s\t%s\n' "FAILED_EXPORT" "$d" "0" >> "$tmp/plan.tsv"
      continue
    fi
    # `grep -c` exits non-zero on zero matches, so the fallback has to replace
    # the value rather than be appended to it with `|| echo 0`.
    entries=$(grep -c '"type":"memory_entry"' "$dump" 2>/dev/null) || entries=0
    [ "$entries" -gt 0 ] || continue
    printf '%s\t%s\t%s\n' "$dump" "$d" "$entries" >> "$tmp/plan.tsv"
  done < "$tmp/dirs.txt"
}

migrate_one() {
  dump=$1
  spelunk_dir=$2
  expected=$3
  root=$(dirname "$spelunk_dir")

  if [ -n "$DRY_RUN" ]; then
    say "  would migrate $expected entries"
    return 0
  fi

  # `--no-index` is load-bearing, not a speed-up. A plain `init` parses the tree
  # and then keeps embedding in a detached background process, so migrating a
  # run of projects would leave one background indexer per project all competing
  # for the single local server's embedder — which is not scaled for parallel
  # indexing — and each holding its own project's index lock. With `--no-index`
  # nothing is spawned, and this script does the indexing itself, in the
  # foreground, one project at a time: `inkentry index` blocks until it is done.
  if [ ! -d "$root/.inkentry" ]; then
    if ! (cd "$root" && inkentry init --no-index > /dev/null 2>&1); then
      warn "  inkentry init failed in $root (not a git repository?) — skipped"
      return 1
    fi
  fi

  out=$(cd "$root" && inkentry import "$dump" --no-embed 2>&1) || {
    warn "  import failed in $root:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  }

  # Verified against the tool's own report rather than a row count, so the check
  # does not depend on sqlite3 or on the internal schema.
  #
  # Entries already present are counted as accounted for, not as a shortfall.
  # Import is idempotent by design — it skips what the store and the notes ref
  # already hold — so re-running after a partial failure legitimately imports
  # zero, and a check that only read the imported count would call a correct
  # re-run a failure and refuse to retire spelunk forever.
  #
  # `entr.*` deliberately: the report is pluralised, so a single-entry store
  # says "1 memory entry" and a stricter pattern silently reads as zero.
  imported=$(printf '%s\n' "$out" | sed -n 's/^Imported \([0-9]*\) memory entr.*/\1/p' | head -n 1)
  # `w[a-z]*` covers both "was" and "were" without `\|`, which is a GNU
  # extension that BSD sed silently fails to match on macOS.
  already=$(printf '%s\n' "$out" | sed -n 's/^\([0-9]*\) w[a-z]* already in this store.*/\1/p' | head -n 1)
  imported=${imported:-0}
  already=${already:-0}
  accounted=$((imported + already))

  if [ "$accounted" != "$expected" ]; then
    warn "  MISMATCH in $root: exported $expected, accounted for $accounted (imported $imported, already present $already)"
    return 1
  fi

  if [ "$already" -gt 0 ]; then
    say "  migrated — $imported new, $already already present"
  else
    say "  migrated — $imported entries"
  fi
  return 0
}

# Run *before* any migration, not after.
#
# `inkentry init` starts embedding in the background, and loopback discovery
# takes whatever answers on 127.0.0.1:7777. With spelunk-server still holding
# that port, the new index would be embedded by the old product's embedder, so
# the vectors would not match what this build produces at query time. Switching
# first is what makes the embeddings the migration writes trustworthy.
switch_servers() {
  step "Switching servers"

  if [ -n "$DRY_RUN" ]; then
    say "would stop spelunk-server and start inkentry-server before migrating"
    return
  fi

  if command -v spelunk > /dev/null 2>&1; then
    spelunk server stop > /dev/null 2>&1 || true
    say "stopped spelunk-server"
  else
    say "no spelunk binary on PATH — nothing to stop"
  fi

  if inkentry server start > /dev/null 2>&1; then
    say "started inkentry-server"
  else
    say "inkentry-server already running, or could not be started"
  fi

  wait_for_embedder
}

# A freshly started server accepts connections well before its embedding model
# has loaded, and answers embed requests with 503 until it has. Indexing the
# first project immediately after starting it therefore fails on a race, so the
# wait is part of switching servers rather than something each caller retries.
wait_for_embedder() {
  url=$(inkentry server status 2>/dev/null |
    sed -n 's/^[[:space:]]*URL:[[:space:]]*\([^[:space:]]*\).*$/\1/p' | head -n 1)
  if [ -z "$url" ]; then
    warn "could not determine the server URL — continuing without waiting"
    return 0
  fi

  i=0
  while [ "$i" -lt 90 ]; do
    if curl -fsS --max-time 5 "$url/v1/health" 2>/dev/null | grep -q '"state":"ready"'; then
      [ "$i" -eq 0 ] || say "embedder ready"
      return 0
    fi
    [ "$i" -eq 0 ] && say "waiting for the embedding model to load…"
    i=$((i + 1))
    sleep 2
  done

  warn "embedder still not ready after 180s — indexing may fail; check 'inkentry server status'"
  return 0
}

remove_spelunk_binaries() {
  step "Removing spelunk"

  if [ -n "$DRY_RUN" ]; then
    say "would remove the spelunk binaries"
    return
  fi

  removed=
  for bin in spelunk spelunk-server; do
    path=$(command -v "$bin" 2>/dev/null) || continue
    if rm -f "$path" 2>/dev/null; then
      say "removed $path"
      removed=yes
    else
      warn "could not remove $path — remove it yourself"
    fi
  done
  [ -n "$removed" ] || say "nothing to remove — spelunk was not on PATH"

  # Deliberately kept: it is the only thing that can read a legacy store, and
  # it is what any later re-run of this script needs.
  if command -v spelunk-export > /dev/null 2>&1; then
    say "kept $(command -v spelunk-export) — the recovery tool"
  fi
}

main() {
  command -v curl > /dev/null 2>&1 || fail "curl is required"
  command -v tar > /dev/null 2>&1 || fail "tar is required"
  detect_target

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  : > "$tmp/plan.tsv"

  [ -n "$DRY_RUN" ] && say "DRY RUN — nothing will be changed"

  step "Installing inkentry"
  if [ -n "${INKENTRY_MIGRATE_SKIP_INSTALL:-}" ]; then
    command -v inkentry > /dev/null 2>&1 ||
      fail "INKENTRY_MIGRATE_SKIP_INSTALL is set but inkentry is not on PATH"
    say "using the inkentry already installed ($(inkentry --version))"
  elif [ -n "$DRY_RUN" ]; then
    say "would run $INSTALL_URL"
  else
    curl -fsSL --proto '=https' "$INSTALL_URL" | sh || fail "installing inkentry failed"
  fi

  # Checked as a capability rather than a version string: the whole migration
  # runs through `inkentry import`, which does not exist before v1. A 0.9.x
  # binary earlier on PATH than the one just installed would otherwise fail
  # every project one at a time, which reads as the migration being broken
  # rather than as the wrong binary being in front.
  if [ -z "$DRY_RUN" ] && ! inkentry import --help > /dev/null 2>&1; then
    fail "the inkentry on PATH ($(command -v inkentry)) has no 'import' command.
  It reports: $(inkentry --version 2>&1 | head -n 1)
  Migration needs v1 or later. Put the v1 binary earlier on PATH, or remove the
  old one, and run this again."
  fi

  switch_servers

  step "Finding spelunk memory"
  fetch_export_tool
  discover_and_export

  stores=$(grep -cv '^FAILED_EXPORT' "$tmp/plan.tsv" 2>/dev/null) || stores=0
  if [ "$stores" -eq 0 ]; then
    say ""
    say "No spelunk memory found under $SCAN_ROOT — nothing to migrate."
    say "If your projects live elsewhere, re-run with:"
    say "  INKENTRY_MIGRATE_SCAN_ROOT=/path curl -fsSL $0 | sh"
    exit 0
  fi

  say ""
  say "Stores with memory to carry across:"
  while IFS="$(printf '\t')" read -r dump spelunk_dir entries; do
    if [ "$dump" = "FAILED_EXPORT" ]; then
      continue
    fi
    printf '  %6s entries  %s\n' "$entries" "$(dirname "$spelunk_dir")"
  done < "$tmp/plan.tsv"

  step "Migrating"

  interactive=yes
  if [ -n "$DRY_RUN" ] || ! have_tty; then
    interactive=
  fi
  if [ -z "$interactive" ] && [ -z "$DRY_RUN" ]; then
    say "No terminal available for prompts, so every store is migrated without"
    say "asking. Re-indexing is never started this way; the commands are printed"
    say "at the end instead."
    say ""
  fi

  failures=0
  declined=0
  reindex_later=""

  # One project at a time, start to finish: migrate it, then offer its index,
  # then move on. Batching every prompt to the end would ask the user to make
  # decisions about a project whose result scrolled past several screens ago.
  while IFS="$(printf '\t')" read -r dump spelunk_dir entries; do
    if [ "$dump" = "FAILED_EXPORT" ]; then
      failures=$((failures + 1))
      continue
    fi
    root=$(dirname "$spelunk_dir")

    say ""
    say "$root — $entries entries"

    if [ -n "$interactive" ] && ! ask_yes_no "  migrate this project?"; then
      say "  skipped — its .spelunk store is untouched"
      declined=$((declined + 1))
      continue
    fi

    if ! migrate_one "$dump" "$spelunk_dir" "$entries"; then
      failures=$((failures + 1))
      continue
    fi

    # `import --no-embed` deliberately leaves the entries unembedded, so every
    # migrated project needs `memory reindex` — including ones that never had a
    # code index, and including ones where `init` just started one, because that
    # background pass ran before these entries existed. Without it the entries
    # are findable by full text and absent from semantic ranking, which reads as
    # complete results rather than as missing work.
    code_index=yes
    if [ ! -f "$spelunk_dir/index.db" ]; then
      code_index=
    fi

    if [ -n "$DRY_RUN" ]; then
      say "  would offer to re-index (memory always; code index too when it had one)"
      continue
    fi

    if [ -z "$interactive" ]; then
      reindex_later="$reindex_later$root	$code_index
"
      continue
    fi

    if [ -n "$code_index" ]; then
      prompt="  re-index it now? (code + memory embeddings)"
    else
      prompt="  build memory embeddings now? (semantic search over the imported entries)"
    fi

    if ask_yes_no "$prompt"; then
      # Both run in the foreground and in sequence, so only one project is ever
      # indexing against the local server at a time.
      if [ -n "$code_index" ]; then
        (cd "$root" && inkentry index .) || warn "  code indexing failed in $root"
      fi
      (cd "$root" && inkentry memory reindex) || warn "  memory reindex failed in $root"
    else
      if [ -n "$code_index" ]; then
        say "  skipped — run 'inkentry index .' and 'inkentry memory reindex' there"
      else
        say "  skipped — run 'inkentry memory reindex' there when you want it"
      fi
    fi
  done < "$tmp/plan.tsv"

  say ""
  if [ "$failures" -gt 0 ]; then
    say "$failures store(s) did not migrate cleanly."
    say ""
    say "spelunk has been left installed and every original store is untouched,"
    say "so nothing is lost and you can re-run this script after fixing the cause."
    exit 1
  fi

  if [ -n "$DRY_RUN" ]; then
    say "Dry run complete — nothing was changed."
  elif [ "$declined" -gt 0 ]; then
    say "Migrated everything you accepted; $declined project(s) declined."
  else
    say "Every store migrated and verified."
  fi

  # Retiring spelunk while a store is still only in the old format would leave
  # that memory readable by nothing on this machine, so a decline blocks it just
  # as a failure does.
  if [ -n "$KEEP_SPELUNK" ]; then
    step "Removing spelunk"
    say "skipped (INKENTRY_MIGRATE_KEEP_SPELUNK is set)"
  elif [ "$declined" -gt 0 ]; then
    step "Removing spelunk"
    say "skipped — $declined project(s) were not migrated, and removing spelunk"
    say "now would leave their memory readable by nothing on this machine."
  else
    remove_spelunk_binaries
  fi

  if [ -n "$reindex_later" ]; then
    step "Re-indexing"
    say "Imported entries are not in semantic search until they are embedded, and"
    say "code indexes are derived rather than carried across. Run these:"
    printf '%s' "$reindex_later" | while IFS="$(printf '\t')" read -r r code; do
      [ -n "$r" ] || continue
      if [ -n "$code" ]; then
        say "  (cd $r && inkentry index . && inkentry memory reindex)"
      else
        say "  (cd $r && inkentry memory reindex)"
      fi
    done
  fi

  step "Done"
  say "Your old .spelunk directories were not deleted. Once you are satisfied,"
  say "remove them yourself — inkentry never will."
  say "docs: https://inkentry.com/docs/getting-started"
}

# Wrapped in main() so a truncated download can never execute half a script.
main "$@"
