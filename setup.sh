#!/usr/bin/env bash
# bootstrap — apply personal configs on a Debian/Ubuntu machine.
set -euo pipefail

REPO="${BOOTSTRAP_REPO:-https://github.com/cforqol/bootstrap}"
REF="${BOOTSTRAP_REF:-main}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/bootstrap"
SRC="$DATA/src"
DOTS_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/dots"
DOTS_COMMIT="5eb8c51e64f1bc73b3c3031c23229ebb2f7424bc"

APPS=(); ALL=false; DRY=false; NO_SECRETS=false; YES=false

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

# ---- survive the pipe -------------------------------------------------
if [[ -z "${BASH_VERSION:-}" || ! -t 0 ]]; then
    if [[ -r /dev/tty ]]; then
        have curl || { echo "curl required" >&2; exit 1; }
        tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
        curl -fsSL --proto '=https' --tlsv1.2 \
            "${BOOTSTRAP_URL:-$REPO/raw/$REF/setup.sh}" -o "$tmp"
        exec bash "$tmp" "$@" </dev/tty
    fi
    [[ -n "${BASH_VERSION:-}" ]] || { echo "bash required" >&2; exit 1; }
fi

TTY_IN=/dev/null
[[ -t 0 ]] && TTY_IN=/dev/stdin
[[ "$TTY_IN" == /dev/null && -r /dev/tty ]] && TTY_IN=/dev/tty

# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

usage() {
    cat >&2 <<EOF
bootstrap — apply personal configs

  curl -fsSL $REPO/raw/$REF/setup.sh | bash -s -- vim git

  --all          every app
  --no-secrets   skip encrypted configs
  --repo URL     config repo (default: $REPO)
  --ref REF      git ref (default: $REF)
  -y, --yes      no prompts
  -n, --dry-run  show, change nothing
  -h, --help     this

  apps: $(ls "$SELF_DIR/configs" 2>/dev/null | tr '\n' ' ')
EOF
    exit "${1:-0}"
}

while (( $# )); do
    case "$1" in
        --all)        ALL=true; shift ;;
        --no-secrets) NO_SECRETS=true; shift ;;
        --repo)       REPO="${2:?}"; shift 2 ;;
        --ref)        REF="${2:?}"; shift 2 ;;
        -y|--yes)     YES=true; shift ;;
        -n|--dry-run) DRY=true; shift ;;
        -h|--help)    usage 0 ;;
        -*)           die "unknown flag: $1" ;;
        *)            APPS+=("$1"); shift ;;
    esac
done

# ---- phases -----------------------------------------------------------

preflight() {
    log_step "preflight"
    local -a miss=()
    local t
    for t in git curl; do have "$t" || miss+=("$t"); done
    if (( ${#miss[@]} )); then
        log_warn "missing: ${miss[*]}"
        ask "install with apt?" y || die "install ${miss[*]} and re-run"
        run sudo apt-get update -qq
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${miss[@]}"
        for t in "${miss[@]}"; do have "$t" || die "$t still missing"; done
    fi
    have realpath || log_warn "realpath missing (coreutils); dots may fail"
    log_ok "prerequisites present"
}

fetch() {
    log_step "fetch"
    if [[ -d "$SRC/.git" ]]; then
        [[ -z "$(git -C "$SRC" status --porcelain)" ]] || die "$SRC has local changes"
        run git -C "$SRC" fetch --quiet origin
        run git -C "$SRC" checkout --quiet "$REF"
    else
        run mkdir -p "$DATA"
        run git clone --quiet --depth 1 --branch "$REF" "$REPO" "$SRC"
    fi
    [[ "$DRY" == true ]] && { log_info "would use $SRC"; return 0; }
    log_ok "$SRC @ $REF"
}

fetch_dots() {
    log_step "dots"
    if [[ ! -d "$DOTS_SRC/.git" ]]; then
        run git clone --quiet https://github.com/cforqol/dots "$DOTS_SRC"
    fi
    run git -C "$DOTS_SRC" fetch --quiet origin
    run git -C "$DOTS_SRC" checkout --quiet "$DOTS_COMMIT"
    [[ "$DRY" == true ]] && return 0
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$DOTS_SRC/dots.sh" "$HOME/.local/bin/dots"
    have dots || export PATH="$HOME/.local/bin:$PATH"
    have dots || die "dots not on PATH"
    log_ok "dots ready"
}

select_apps() {
    log_step "apps"
    local d n
    if [[ "$ALL" == true ]]; then
        for d in "$SRC"/configs/*/; do [[ -d "$d" ]] && APPS+=("$(basename "$d")"); done
    elif (( ${#APPS[@]} == 0 )); then
        local -a avail=()
        for d in "$SRC"/configs/*/; do [[ -d "$d" ]] && avail+=("$(basename "$d")"); done
        (( ${#avail[@]} )) || die "no apps in $SRC/configs"
        if [[ "$TTY_IN" == /dev/null ]]; then
            die "no apps given; use --all or name them"
        fi
        printf '\n  available:\n' >&2
        printf '    %s\n' "${avail[@]}" >&2
        printf '\n  apply which (space separated): ' >&2
        read -r line < "$TTY_IN" || die "no input"
        # shellcheck disable=SC2206
        APPS=($line)
    fi
    (( ${#APPS[@]} )) || die "nothing selected"
    local a
    for a in "${APPS[@]}"; do
        [[ -d "$SRC/configs/$a" ]] || die "unknown app: $a"
    done
    log_ok "${APPS[*]}"
}

app_is_encrypted() {
    local f
    while IFS= read -r -d '' f; do
        head -c 10 "$f" 2>/dev/null | grep -qa GITCRYPT && return 0
    done < <(find "$SRC/configs/$1" -type f -print0 2>/dev/null)
    return 1
}

prune() {
    local -a keep=(); local a
    for a in "${APPS[@]}"; do [[ "$a" == "$1" ]] || keep+=("$a"); done
    APPS=("${keep[@]}")
}

crypto() {
    log_step "secrets"
    local -a enc=(); local a

    for a in "${APPS[@]}"; do app_is_encrypted "$a" && enc+=("$a"); done
    if (( ${#enc[@]} == 0 )); then log_ok "no encrypted configs"; return 0; fi

    if [[ "$NO_SECRETS" == true ]]; then
        for a in "${enc[@]}"; do prune "$a"; done
        log_warn "--no-secrets: skipped ${enc[*]}"
        return 0
    fi

    if ! have git-crypt; then
        log_warn "encrypted configs: ${enc[*]}"
        if ask "install git-crypt?" y; then
            run sudo apt-get update -qq
            run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git-crypt
            have git-crypt || die "git-crypt still missing"
        else
            for a in "${enc[@]}"; do prune "$a"; done
            log_warn "skipped ${enc[*]}"
            return 0
        fi
    fi

    if git -C "$SRC" grep -q '^\*GITCRYPT\*' -- . 2>/dev/null; then
        log_info "repo is locked"
        printf '  key path (blank to skip): ' >&2
        local kp; read -r kp < "$TTY_IN" || kp=""
        if [[ -n "$kp" ]]; then run dots unlock "$kp"
        else log_warn "locked; encrypted apps will stay ciphertext"; fi
    fi
}

init_dots() {
    log_step "init"
    local host; host="$(host_slug)"
    if [[ -d "$SRC/$host/_user" ]]; then log_ok "$host already initialized"; return 0; fi
    ( cd "$SRC" && run bash "$DOTS_SRC/dots.sh" init ) || die "dots init failed"
    log_ok "initialized $host"
}

collect_targets() {
    TARGETS=(); TARGET_SRC=()
    local a scope root rel f target
    for a in "${APPS[@]}"; do
        for scope in _user _root; do
            [[ -d "$SRC/configs/$a/$scope" ]] || continue
            [[ "$scope" == _user ]] && root="$HOME" || root="/"
            while IFS= read -r -d '' f; do
                rel="${f#"$SRC/configs/$a/$scope/"}"
                TARGETS+=("$root/$rel")
                TARGET_SRC+=("$a")
            done < <(find "$SRC/configs/$a/$scope" -type f -print0)
        done
    done
    # duplicate detection
    local -A seen=()
    local i
    for i in "${!TARGETS[@]}"; do
        if [[ -n "${seen[${TARGETS[$i]}]:-}" ]]; then
            die "conflict: ${TARGET_SRC[$i]} and ${seen[${TARGETS[$i]}]} both provide ${TARGETS[$i]}"
        fi
        seen["${TARGETS[$i]}"]="${TARGET_SRC[$i]}"
    done
}

link_all() {
    log_step "link"
    local host; host="$(host_slug)"
    local i tgt rel f
    for i in "${!TARGETS[@]}"; do
        tgt="${TARGETS[$i]}"
        f="$(find "$SRC/configs/${TARGET_SRC[$i]}" -type f -print0 | tr '\0' '\n' | grep -F "/${tgt#"$HOME"/}" | head -1)"
        [[ -n "$f" ]] || f="$tgt"
        if [[ "$tgt" == /etc/* || "$tgt" == /usr/* ]]; then
            run sudo mkdir -p "$(dirname "$tgt")"
            run sudo ln -sfn "$f" "$tgt"
        else
            run mkdir -p "$(dirname "$tgt")"
            run ln -sfn "$f" "$tgt"
        fi
    done
    log_ok "${#TARGETS[@]} links"
}

apply() {
    log_step "apply"
    [[ "$DRY" == true ]] && { log_info "would run dots apply"; return 0; }
    ( cd "$SRC" && dots apply ) || die "dots apply failed"
    log_ok "applied"
}

main() {
    preflight
    fetch
    select_apps
    printf '\n  repo   %s\n  ref    %s\n  apps   %s\n  secrets %s\n' \
        "$REPO" "$REF" "${APPS[*]}" "$([[ "$NO_SECRETS" == true ]] && echo off || echo on)" >&2
    confirm
    fetch_dots
    crypto
    (( ${#APPS[@]} )) || { log_warn "nothing left to apply"; exit 0; }
    init_dots
    collect_targets
    link_all
    apply
    log_ok "done"
}

main
