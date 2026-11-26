#!/usr/bin/env bash
# bootstrap — provision this machine with the dotfiles in this repo.
#
#   curl -fsSL https://github.com/cforqol/bootstrap/raw/main/setup.sh | bash
#
# Copies hosts/<hostname>/ (or hosts/generic/) into ~/dotfiles/<hostname>/,
# installs dots.sh alongside it, and applies. Files marked filter=git-crypt
# are skipped: public provisioning only.

REPO="${BOOTSTRAP_REPO:-https://github.com/cforqol/bootstrap}"
REF="${BOOTSTRAP_REF:-main}"
TOOL_COMMIT="${BOOTSTRAP_TOOL_COMMIT:-5eb8c51e64f1bc73b3c3031c23229ebb2f7424bc}"
TOOL_RAW="${BOOTSTRAP_TOOL_RAW:-https://raw.githubusercontent.com/cforqol/dots/$TOOL_COMMIT/dots.sh}"

VERSION=1
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/bootstrap"
SRC="$DATA/src"
DOTS_REPO="${DOTS_REPO:-$HOME/dotfiles}"

set -euo pipefail

YES=false
TTY_IN=/dev/null
[[ -t 0 ]] && TTY_IN=/dev/stdin
[[ "$TTY_IN" == /dev/null && -r /dev/tty ]] && TTY_IN=/dev/tty

# --- helpers ---
if [[ -t 2 ]]; then C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
else C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''; fi

log_info() { printf '  %s\n' "$*" >&2; }
log_ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*" >&2; }
log_warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
log_step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*" >&2; }
die()      { printf '\n%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ask() {
    local prompt="$1" default="${2:-n}" a
    [[ "$YES" == true ]] && return 0
    [[ "$TTY_IN" == /dev/null ]] && { [[ "$default" == y ]]; return; }
    printf '  %s [%s] ' "$prompt" "$default" >&2
    read -r a < "$TTY_IN" || a=""
    a="${a:-$default}"
    [[ "$a" =~ ^[Yy] ]]
}

confirm() {
    [[ "$YES" == true ]] && return 0
    [[ "$TTY_IN" == /dev/null ]] && return 0
    local a
    printf '\n  proceed? [Y/n] ' >&2
    read -r a < "$TTY_IN" || a=""
    [[ "${a:-y}" =~ ^[Yy]?$ ]] || die "aborted"
}

host_slug() {
    local h="${HOST_SLUG:-$(hostname -s 2>/dev/null || echo unknown)}"
    h="${h,,}"; printf '%s\n' "${h//[^a-z0-9-]/-}"
}

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
    for t in git curl tar realpath; do have "$t" || miss+=("$t"); done
    if (( ${#miss[@]} )); then
        log_warn "missing: ${miss[*]}"
        ask "install with apt?" y || die "install ${miss[*]} and re-run"
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${miss[@]}"
        for t in "${miss[@]}"; do have "$t" || die "$t still missing"; done
    fi
    log_ok "ok"
}

fetch_repo() {
    log_step "configs"
    rm -rf "${SRC:?}"
    mkdir -p "$SRC"
    curl -fsSL "$REPO/archive/$REF.tar.gz" | tar -xz -C "$SRC" --strip-components=1
    git -C "$SRC" init -q          # so `git check-attr` can read .gitattributes
    log_ok "$SRC @ $REF"
}

prepare_data() {
    log_step "data repo"
    local marker="$DOTS_REPO/.bootstrap"

    if [[ -e "$DOTS_REPO" ]]; then
        [[ -e "$marker" ]] || die \
"$DOTS_REPO already exists and was not created by bootstrap.
     If it is your existing dots repo, you do not need this script.
     Otherwise set DOTS_REPO=/some/other/path, or remove it."
        [[ -z "$(git -C "$DOTS_REPO" remote 2>/dev/null)" ]] || die \
"$DOTS_REPO has a git remote; refusing to overwrite it."
    fi

    mkdir -p "$DOTS_REPO"
    [[ -d "$DOTS_REPO/.git" ]] || git -C "$DOTS_REPO" init --quiet
    : > "$marker"

    local g
    for g in dots.sh .bootstrap; do
        grep -qxF "$g" "$DOTS_REPO/.gitignore" 2>/dev/null \
            || echo "$g" >> "$DOTS_REPO/.gitignore"
    done
    log_ok "$DOTS_REPO"
}

install_dots() {
    log_step "dots"
    curl -fsSL "$TOOL_RAW" -o "$DOTS_REPO/dots.sh"
    chmod +x "$DOTS_REPO/dots.sh"
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$DOTS_REPO/dots.sh" "$HOME/.local/bin/dots"
    have dots || export PATH="$HOME/.local/bin:$PATH"
    have dots || die "dots not on PATH"
    log_ok "dots @ ${TOOL_COMMIT:0:7}"
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

    rm -rf "${DOTS_REPO:?}/$HOST"

    local f rel repo_rel dest n=0 skipped=0
    while IFS= read -r -d '' f; do
        rel="${f#"$src/"}"
        repo_rel="${f#"$SRC/"}"
        if [[ "$(filter_attr "$repo_rel")" == git-crypt ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        dest="$DOTS_REPO/$HOST/$rel"
        mkdir -p "$(dirname "$dest")"
        cp -a "$f" "$dest"
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
            cp -a "$dest" "$dest.bak"; n=$((n + 1))
        fi
    done < <(find "$DOTS_REPO/$HOST/_user" -type f -print0 2>/dev/null)
    while IFS= read -r -d '' f; do
        rel="${f#"$DOTS_REPO/$HOST/_root/"}"
        dest="/$rel"
        if [[ -e "$dest" && ! -L "$dest" ]]; then
            sudo cp -a "$dest" "$dest.bak"; n=$((n + 1))
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
            sudo chmod 600 "$f"
        else
            sudo chmod 644 "$f"
        fi
    done < <(find "$DOTS_REPO/$HOST/_root" -type f -print0)
    log_ok "ok"
}

main() {
    preflight
    fetch_repo
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
