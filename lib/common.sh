#!/usr/bin/env bash
# Shared helpers. Sourced by setup.sh.

if [[ -t 2 ]]; then C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
else C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''; fi

log_info()  { printf '  %s\n' "$*" >&2; }
log_ok()    { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*" >&2; }
log_warn()  { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*" >&2; }
die()       { printf '\n%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

run() {
    if [[ "$DRY" == true ]]; then log_info "would: $*"; return 0; fi
    "$@"
}

# Ask; returns 0 on yes. Non-interactive always no.
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
