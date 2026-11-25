#!/usr/bin/env bash
# bootstrap — apply personal configs on a Debian/Ubuntu machine.

REPO="${BOOTSTRAP_REPO:-https://github.com/cforqol/bootstrap}"
REF="${BOOTSTRAP_REF:-main}"

# Re-exec under bash from a downloaded copy when piped in (curl | bash) or
# started under a non-bash shell. Deliberately above set -euo pipefail and
# above every bashism, so it also works when this file is fed to sh.
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
DOTS_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/dots"
DOTS_COMMIT="5eb8c51e64f1bc73b3c3031c23229ebb2f7424bc"

APPS=(); ALL=false; DRY=false; NO_SECRETS=false; YES=false
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"

TTY_IN=/dev/null
[[ -t 0 ]] && TTY_IN=/dev/stdin
[[ "$TTY_IN" == /dev/null && -r /dev/tty ]] && TTY_IN=/dev/tty

# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

# Clean up the downloaded copy on exit.
[[ -n "${BOOTSTRAP_TMPD:-}" ]] && trap 'rm -rf "$BOOTSTRAP_TMPD"' EXIT

usage() {
    cat >&2 <<EOF
bootstrap — apply personal configs via dots

  curl -fsSL $REPO/raw/$REF/setup.sh | bash -s -- vim git

  --all          every app
  --no-secrets   skip encrypted configs
  --repo URL     config repo (default: $REPO)
  --ref REF      git ref (default: $REF)
  -y, --yes      no prompts
  -n, --dry-run  show, change nothing
  -h, --help     this
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

fetch() {
    log_step "fetch"
    if [[ -d "$SRC/.git" ]]; then
        [[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]] \
            || die "$SRC has local changes"
        run git -C "$SRC" fetch --quiet --depth 1 origin "$REF"
        run git -C "$SRC" reset --hard --quiet FETCH_HEAD
    else
        run mkdir -p "$DATA"
        run git clone --quiet --depth 1 --branch "$REF" "$REPO" "$SRC"
    fi
    log_ok "$SRC @ $REF ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '?'))"
}

fetch_dots() {
    log_step "dots"
    [[ -d "$DOTS_SRC/.git" ]] || run git clone --quiet https://github.com/cforqol/dots "$DOTS_SRC"
    run git -C "$DOTS_SRC" fetch --quiet origin
    run git -C "$DOTS_SRC" checkout --quiet "$DOTS_COMMIT"
    [[ "$DRY" == true ]] && { log_info "would install dots"; return 0; }
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$DOTS_SRC/dots.sh" "$HOME/.local/bin/dots"
    have dots || export PATH="$HOME/.local/bin:$PATH"
    have dots || die "dots not on PATH"
    log_ok "dots ready"
}

select_apps() {
    log_step "apps"
    local d a
    if [[ "$ALL" == true ]]; then
        for d in "$SRC"/configs/*/; do
            [[ -d "$d" ]] || continue
            APPS+=("$(basename "$d")")
        done
    elif (( ${#APPS[@]} == 0 )); then
        local -a avail=()
        for d in "$SRC"/configs/*/; do
            [[ -d "$d" ]] || continue
            avail+=("$(basename "$d")")
        done
        (( ${#avail[@]} )) || die "no apps in $SRC/configs"
        [[ "$TTY_IN" == /dev/null ]] && die "no apps given; use --all"
        printf '\n  available: %s\n\n  apply which: ' "${avail[*]}" >&2
        local line; read -r line < "$TTY_IN" || die "no input"
        # shellcheck disable=SC2206
        APPS=($line)
    fi
    (( ${#APPS[@]} )) || die "nothing selected"
    for a in "${APPS[@]}"; do [[ -d "$SRC/configs/$a" ]] || die "unknown app: $a"; done
    log_ok "${APPS[*]}"
}

app_is_encrypted() {
    local f rel out
    while IFS= read -r -d '' f; do
        head -c 10 "$f" 2>/dev/null | grep -qa GITCRYPT && return 0
    done < <(find "$SRC/configs/$1" -type f -print0 2>/dev/null)
    while IFS= read -r -d '' f; do
        rel="${f#"$SRC"/}"
        out="$(git -C "$SRC" check-attr filter -- "$rel" 2>/dev/null || true)"
        [[ "$out" == *": git-crypt" ]] && return 0
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
    (( ${#enc[@]} )) || { log_ok "no encrypted configs"; return 0; }

    if [[ "$NO_SECRETS" == true ]]; then
        for a in "${enc[@]}"; do prune "$a"; done
        log_warn "--no-secrets: skipped ${enc[*]}"; return 0
    fi

    if ! have git-crypt; then
        log_warn "encrypted: ${enc[*]}"
        if ask "install git-crypt?" y; then
            run sudo apt-get update -qq
            run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git-crypt
            have git-crypt || die "git-crypt still missing"
        else
            for a in "${enc[@]}"; do prune "$a"; done
            log_warn "skipped ${enc[*]}"; return 0
        fi
    fi

    if git -C "$SRC" grep -q '^\*GITCRYPT\*' -- . 2>/dev/null; then
        local kp
        printf '  key path (blank to skip): ' >&2
        read -r kp < "$TTY_IN" || kp=""
        [[ -n "$kp" ]] && run dots unlock "$kp" || log_warn "repo still locked"
    fi
}

init_dots() {
    log_step "init"
    local host; host="$(host_slug)"
    [[ -d "$SRC/$host/_user" ]] && { log_ok "$host already initialized"; return 0; }
    ( cd "$SRC" && run bash "$DOTS_SRC/dots.sh" init ) || die "dots init failed"
    log_ok "initialized $host"
}

# builds SRC_FILES / TARGETS / TARGET_APP, relative-links into the host tree
plan_links() {
    local host; host="$(host_slug)"
    local a scope rel f tgt link
    SRC_FILES=(); TARGETS=(); TARGET_APP=(); LINKS=()

    for a in "${APPS[@]}"; do
        for scope in _user _root; do
            [[ -d "$SRC/configs/$a/$scope" ]] || continue
            while IFS= read -r -d '' f; do
                rel="${f#"$SRC/configs/$a/$scope/"}"
                tgt="$SRC/$host/$scope/$rel"
                SRC_FILES+=("$f"); TARGETS+=("$tgt"); TARGET_APP+=("$a")
                LINKS+=("$(realpath --relative-to="$(dirname "$tgt")" "$f")")
            done < <(find "$SRC/configs/$a/$scope" -type f -print0)
        done
    done

    local -A seen=(); local i
    for i in "${!TARGETS[@]}"; do
        if [[ -n "${seen[${TARGETS[$i]}]:-}" ]]; then
            die "conflict: ${TARGET_APP[$i]} and ${seen[${TARGETS[$i]}]} both provide ${TARGETS[$i]#"$SRC/$host/"}"
        fi
        seen["${TARGETS[$i]}"]="${TARGET_APP[$i]}"
    done
}

write_links() {
    log_step "link"
    local i
    for i in "${!TARGETS[@]}"; do
        run mkdir -p "$(dirname "${TARGETS[$i]}")"
        run ln -sfn "${LINKS[$i]}" "${TARGETS[$i]}"
    done
    log_ok "${#TARGETS[@]} links"
}

apply() {
    log_step "apply"
    if [[ "$DRY" == true ]]; then
        log_info "would run: dots apply"
        return 0
    fi
    ( cd "$SRC" && dots apply ) || die "dots apply failed"

    local has_root=0 i
    for i in "${!TARGETS[@]}"; do [[ "${TARGETS[$i]}" == *"/_root/"* ]] && has_root=1; done
    if (( has_root )); then
        log_warn "system files go to / — backing up originals to *.bak"
        for i in "${!TARGETS[@]}"; do
            [[ "${TARGETS[$i]}" == *"/_root/"* ]] || continue
            local real="/${TARGETS[$i]#*"/_root/"}"
            [[ -e "$real" && ! -L "$real" ]] && run sudo cp -a "$real" "$real.bak"
        done
        ( cd "$SRC" && sudo dots apply-all ) || die "dots apply-all failed"
    fi
    log_ok "applied"
}

main() {
    preflight
    fetch
    select_apps
    printf '\n  repo %s\n  apps %s\n' "$REPO" "${APPS[*]}" >&2
    confirm
    fetch_dots
    crypto
    (( ${#APPS[@]} )) || { log_warn "nothing left"; exit 0; }
    init_dots
    plan_links
    write_links
    apply
    log_ok "done"
}

main
