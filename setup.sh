#!/usr/bin/env bash
# bootstrap — provision this machine with the dotfiles in this repo, via dots.
#
#   curl -fsSL https://github.com/cforqol/bootstrap/raw/main/setup.sh | bash
#
# Reads hosts/<hostname>/ if present, else hosts/generic/, copies it into a
# dots working tree at ~/.config/dotfiles/<hostname>/, and applies it.
# Files marked filter=git-crypt are skipped: public provisioning only.

REPO="${BOOTSTRAP_REPO:-https://github.com/cforqol/bootstrap}"
REF="${BOOTSTRAP_REF:-main}"
TOOL_REPO="${BOOTSTRAP_TOOL_REPO:-https://github.com/cforqol/dots}"
TOOL_COMMIT="${BOOTSTRAP_TOOL_COMMIT:-5eb8c51e64f1bc73b3c3031c23229ebb2f7424bc}"

VERSION=1

# Re-exec under bash from a downloaded copy when piped in or under a non-bash shell.
if [ -z "${BOOTSTRAP_REEXEC:-}" ] && { [ -z "${BASH_VERSION:-}" ] || [ ! -t 0 ]; }; then
    command -v curl >/dev/null 2>&1 || { echo "curl required" >&2; exit 1; }
    tmpd="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
    mkdir -p "$tmpd/lib"
    curl -fsSL --proto '=https' --tlsv1.2 "${BOOTSTRAP_URL:-$REPO/raw/$REF/setup.sh}" \
        -o "$tmpd/setup.sh" \
        || { echo "download failed: $REPO/raw/$REF/setup.sh" >&2; exit 1; }
    curl -fsSL --proto '=https' --tlsv1.2 "${BOOTSTRAP_LIB_URL:-$REPO/raw/$REF/lib/common.sh}" \
        -o "$tmpd/lib/common.sh" \
        || { echo "download failed: $REPO/raw/$REF/lib/common.sh" >&2; exit 1; }
    if [ -r /dev/tty ]; then
        BOOTSTRAP_REEXEC=1 BOOTSTRAP_TMPD="$tmpd" exec bash "$tmpd/setup.sh" "$@" </dev/tty
    fi
    BOOTSTRAP_REEXEC=1 BOOTSTRAP_TMPD="$tmpd" exec bash "$tmpd/setup.sh" "$@" </dev/null
fi

set -euo pipefail

DATA="${XDG_DATA_HOME:-$HOME/.local/share}/bootstrap"
SRC="$DATA/src"
TOOL="$DATA/tool"
DOTS_REPO="${DOTS_REPO:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles}"

DRY=false; YES=false
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
TTY_IN=/dev/null
[[ -t 0 ]] && TTY_IN=/dev/stdin
[[ "$TTY_IN" == /dev/null && -r /dev/tty ]] && TTY_IN=/dev/tty

# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

[[ -n "${BOOTSTRAP_TMPD:-}" ]] && trap 'rm -rf "$BOOTSTRAP_TMPD"' EXIT

usage() {
    cat >&2 <<EOF
bootstrap — provision this machine with dotfiles from $REPO

  curl -fsSL $REPO/raw/$REF/setup.sh | bash

  --version   print version
  -h, --help  this
EOF
    exit "${1:-0}"
}

while (( $# )); do
    case "$1" in
        --version|-V) printf 'bootstrap %s\n' "$VERSION"; exit 0 ;;
        -h|--help)    usage 0 ;;
        *)            die "setup.sh takes no arguments (got: $1)" ;;
    esac
done

preflight() {
    log_step "preflight"
    local -a miss=(); local t
    for t in git curl realpath; do have "$t" || miss+=("$t"); done
    if (( ${#miss[@]} )); then
        log_warn "missing: ${miss[*]}"
        ask "install with apt?" y || die "install ${miss[*]} and re-run"
        run sudo apt-get update -qq
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${miss[@]}"
        for t in "${miss[@]}"; do have "$t" || die "$t still missing"; done
    fi
    log_ok "ok"
}

fetch_repo() {
    log_step "bootstrap"
    if [[ -d "$SRC/.git" ]]; then
        [[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]] \
            || die "$SRC has local changes"
        run git -C "$SRC" fetch --quiet --depth 1 origin "$REF"
        run git -C "$SRC" reset --hard --quiet FETCH_HEAD
    else
        run mkdir -p "$DATA"
        run git clone --quiet --depth 1 --branch "$REF" "$REPO" "$SRC"
    fi
    log_ok "$SRC @ $REF"
}

fetch_tool() {
    log_step "dots"
    if [[ -d "$TOOL/.git" ]]; then
        run git -C "$TOOL" fetch --quiet origin
    else
        run mkdir -p "$DATA"
        run git clone --quiet "$TOOL_REPO" "$TOOL"
    fi
    run git -C "$TOOL" checkout --quiet "$TOOL_COMMIT"
    log_ok "tool @ ${TOOL_COMMIT:0:7}"
}

prepare_data() {
    log_step "data repo"
    run mkdir -p "$DOTS_REPO"
    [[ -d "$DOTS_REPO/.git" ]] || run git -C "$DOTS_REPO" init --quiet
    grep -qxF 'dots.sh' "$DOTS_REPO/.gitignore" 2>/dev/null \
        || echo 'dots.sh' >> "$DOTS_REPO/.gitignore"
    log_ok "$DOTS_REPO"
}

install_dots() {
    run cp -f "$TOOL/dots.sh" "$DOTS_REPO/dots.sh"
    chmod +x "$DOTS_REPO/dots.sh"
    run mkdir -p "$HOME/.local/bin"
    run ln -sfn "$DOTS_REPO/dots.sh" "$HOME/.local/bin/dots"
    have dots || export PATH="$HOME/.local/bin:$PATH"
    have dots || die "dots not on PATH"
    log_ok "dots ready"
}

resolve_host() {
    HOST="$(host_slug)"
    [[ -n "$HOST" ]] || die "cannot determine hostname"
    mkdir -p "$HOME/.dots"
    printf '%s\n' "$HOST" > "$HOME/.dots/host"
    log_ok "host $HOST"
}

filter_attr() {   # $1 = path relative to the repo root; prints the filter value
    local _p _a v=""
    { IFS= read -r -d '' _p; IFS= read -r -d '' _a; IFS= read -r -d '' v; } \
        < <(git -C "$SRC" check-attr -z filter -- "$1" 2>/dev/null) || true
    printf '%s' "$v"
}

stage() {
    log_step "stage"
    local src="$SRC/hosts/$HOST"
    [[ -d "$src" ]] || src="$SRC/hosts/generic"
    [[ -d "$src" ]] || die "no host tree: hosts/$HOST or hosts/generic"
    [[ -d "$DOTS_REPO/$HOST" ]] && log_warn "replacing $DOTS_REPO/$HOST"

    run rm -rf "${DOTS_REPO:?}/$HOST"

    local f rel repo_rel dest n=0 skipped=0
    while IFS= read -r -d '' f; do
        rel="${f#"$src/"}"
        repo_rel="${f#"$SRC/"}"
        if [[ "$(filter_attr "$repo_rel")" == git-crypt ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        dest="$DOTS_REPO/$HOST/$rel"
        run mkdir -p "$(dirname "$dest")"
        run cp -a "$f" "$dest"
        n=$((n + 1))
    done < <(find "$src" -type f -print0)

    log_ok "$(basename "$src") -> $HOST ($n copied, $skipped encrypted skipped)"
}

backup_existing() {
    log_step "backup"
    local rel dest n=0
    while IFS= read -r -d '' f; do
        rel="${f#"$DOTS_REPO/$HOST/_user/"}"
        dest="$HOME/$rel"
        if [[ -e "$dest" && ! -L "$dest" ]]; then
            run cp -a "$dest" "$dest.bak"; n=$((n + 1))
        fi
    done < <(find "$DOTS_REPO/$HOST/_user" -type f -print0 2>/dev/null)
    while IFS= read -r -d '' f; do
        rel="${f#"$DOTS_REPO/$HOST/_root/"}"
        dest="/$rel"
        if [[ -e "$dest" && ! -L "$dest" ]]; then
            run sudo cp -a "$dest" "$dest.bak"; n=$((n + 1))
        fi
    done < <(find "$DOTS_REPO/$HOST/_root" -type f -print0 2>/dev/null)
    log_ok "$n files backed up (.bak)"
}

apply_configs() {
    log_step "apply"
    ( cd "$DOTS_REPO" && dots apply-all ) || die "dots apply-all failed"
    log_ok "applied"
}

fix_perms() {
    [[ -d "$DOTS_REPO/$HOST/_root" ]] || return 0
    log_step "permissions"
    local f
    while IFS= read -r -d '' f; do
        if [[ "$f" == */.ssh/* || "$f" == */authorized_keys || "$f" == *.key ]]; then
            run sudo chmod 600 "$f"
        else
            run sudo chmod 644 "$f"
        fi
    done < <(find "$DOTS_REPO/$HOST/_root" -type f -print0)
    log_ok "ok"
}

main() {
    preflight
    fetch_repo
    fetch_tool
    prepare_data
    install_dots
    resolve_host
    stage
    backup_existing
    confirm
    apply_configs
    fix_perms
    log_ok "done — $HOST from $DOTS_REPO"
}

main "$@"
