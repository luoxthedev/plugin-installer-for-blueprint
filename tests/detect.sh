#!/bin/bash
# Exercises Pterodactyl and Blueprint detection without touching a real panel.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/install.sh"

FAILURES=0

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

assert_rc() {
    local expected="$1"
    shift
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -ne "$expected" ]]; then
        fail "$*: expected exit ${expected}, got ${rc}"
    fi
}

make_panel() {
    local dir="$1"
    mkdir -p "$dir/config" "$dir/vendor"
    printf '%s\n' '<?php' > "$dir/artisan"
    printf '%s\n' '<?php' > "$dir/config/pterodactyl.php"
    printf '%s\n' '<?php' > "$dir/vendor/autoload.php"
    printf '%s\n' '{' '  "name": "pterodactyl/panel",' '  "description": "panel"' '}' > "$dir/composer.json"
    printf '%s\n' 'APP_ENV=production' 'APP_KEY=base64:abc123' > "$dir/.env"
}

make_blueprint() {
    local dir="$1"
    local node_major="${2:-22}"
    printf '%s\n' '#!/bin/bash' "[[ \$nodeMajor -lt ${node_major} ]]" > "$dir/blueprint.sh"
    mkdir -p \
        "$dir/scripts/commands/extensions" \
        "$dir/scripts/libraries" \
        "$dir/app/BlueprintFramework" \
        "$dir/.blueprint/extensions/blueprint/private/db"
    printf '%s\n' '#!/bin/bash' > "$dir/scripts/commands/extensions/install.sh"
    printf '%s\n' '#!/bin/bash' > "$dir/scripts/libraries/misc.sh"
    : > "$dir/.blueprint/extensions/blueprint/private/db/is_installed"
}

isolate_search() {
    PTERODACTYL_SEARCH_PATHS=()
    DOCKER_COMPOSE_CANDIDATES=()
    PTERODACTYL_DOCKERENV="/does/not/exist"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "node version parser"
assert_eq "$(node_major_from_string "v22.14.0")" "22" "v22"
assert_eq "$(node_major_from_string "v20.11.1")" "20" "v20"
assert_eq "$(node_major_from_string "22.0.0")" "22" "bare 22"
assert_eq "$(node_major_from_string "not-node")" "" "garbage"

echo "rejects a generic Laravel tree"
LARAVEL="$TMP/laravel"
mkdir -p "$LARAVEL/config"
printf '%s\n' '<?php' > "$LARAVEL/artisan"
printf '%s\n' '<?php' > "$LARAVEL/config/app.php"
printf '%s\n' 'APP_KEY=base64:abc' > "$LARAVEL/.env"
assert_rc 1 is_pterodactyl_panel "$LARAVEL"

echo "rejects an unpacked panel with an empty APP_KEY"
UNPACKED="$TMP/unpacked"
make_panel "$UNPACKED"
printf '%s\n' 'APP_KEY=' > "$UNPACKED/.env"
assert_rc 1 is_pterodactyl_panel "$UNPACKED"

echo "rejects a panel whose composer package is not pterodactyl/panel"
OTHER="$TMP/other"
make_panel "$OTHER"
printf '%s\n' '{' '  "name": "laravel/laravel"' '}' > "$OTHER/composer.json"
assert_rc 1 is_pterodactyl_panel "$OTHER"

echo "rejects a panel without vendor/"
NOVENDOR="$TMP/novendor"
make_panel "$NOVENDOR"
rm -rf "$NOVENDOR/vendor"
assert_rc 1 is_pterodactyl_panel "$NOVENDOR"

echo "accepts a finished Pterodactyl panel, including a quoted APP_KEY"
PANEL="$TMP/var/www/pterodactyl"
make_panel "$PANEL"
printf '%s\n' 'APP_KEY="base64:quoted"' > "$PANEL/.env"
assert_rc 0 is_pterodactyl_panel "$PANEL"

echo "Blueprint is installed only when the official marker and CLI are present"
assert_rc 1 is_blueprint_installed "$PANEL"
make_blueprint "$PANEL"
assert_rc 0 is_blueprint_installed "$PANEL"
assert_eq "$(required_node_major "$PANEL")" "22" "current blueprint wants node 22"

echo "beta-2024-12 is installed when setupFinished is recorded, and wants node 17"
LEGACY="$TMP/legacy"
make_panel "$LEGACY"
make_blueprint "$LEGACY" 17
rm -f "$LEGACY/.blueprint/extensions/blueprint/private/db/is_installed"
assert_rc 1 is_blueprint_installed "$LEGACY"
printf '%s\n' '* blueprint.setupFinished;' > "$LEGACY/.blueprint/extensions/blueprint/private/db/database"
assert_rc 0 is_blueprint_installed "$LEGACY"
assert_eq "$(required_node_major "$LEGACY")" "17" "legacy blueprint wants node 17"
# shellcheck disable=SC2016
printf '%s\n' '[[ $nodeMajor -lt 17 ]]' 'node_modules/"*"cross-env"*"' > "$LEGACY/blueprint.sh"
assert_rc 0 blueprint_mentions_node_module "$LEGACY" "cross-env"
assert_rc 1 blueprint_mentions_node_module "$PANEL" "cross-env"

WIPED="$TMP/wiped"
make_panel "$WIPED"
make_blueprint "$WIPED"
rm -rf "$WIPED/app/BlueprintFramework"
assert_rc 1 is_blueprint_installed "$WIPED"
assert_rc 0 blueprint_was_wiped "$WIPED"

echo "extension names come from the panel root only"
printf '%s\n' 'a' > "$PANEL/zeta.blueprint"
printf '%s\n' 'b' > "$PANEL/alpha.blueprint"
mkdir -p "$PANEL/nested"
printf '%s\n' 'c' > "$PANEL/nested/hidden.blueprint"
assert_eq "$(collect_blueprint_names "$PANEL")" $'alpha\nzeta' "sorted names"
assert_rc 0 extension_name_is_safe "alpha"
assert_rc 1 extension_name_is_safe "bad name"
assert_rc 1 extension_name_is_safe "*"

echo "compose file classification"
COMPOSE="$TMP/docker-compose.yml"
printf '%s\n' 'image: ghcr.io/blueprintframework/blueprint:v1.15.2' > "$COMPOSE"
assert_rc 0 compose_targets_blueprint "$COMPOSE"
printf '%s\n' 'image: ghcr.io/pterodactyl/panel:v1.11.11' > "$COMPOSE"
assert_rc 1 compose_targets_blueprint "$COMPOSE"
printf '%s\n' '- /srv/pterodactyl/extensions/:/blueprint_extensions' > "$COMPOSE"
assert_rc 0 compose_targets_blueprint "$COMPOSE"

echo "locate_panel refuses to continue when either install is missing"
isolate_search
PTERODACTYL_SEARCH_PATHS=("$LARAVEL" "$UNPACKED")
assert_rc 3 locate_panel
assert_eq "$INSTALL_MODE" "" "mode stays empty"

isolate_search
PTERODACTYL_SEARCH_PATHS=("$NOVENDOR")
# novendor is not a panel; rebuild a real one without blueprint
ONLY_PTERO="$TMP/only-ptero"
make_panel "$ONLY_PTERO"
PTERODACTYL_SEARCH_PATHS=("$LARAVEL" "$ONLY_PTERO")
assert_rc 2 locate_panel
assert_eq "$LOCATE_DETAIL" "$(realpath "$ONLY_PTERO")" "reports the panel path"

isolate_search
PTERODACTYL_SEARCH_PATHS=("$WIPED")
assert_rc 5 locate_panel

isolate_search
PTERODACTYL_SEARCH_PATHS=("$ONLY_PTERO" "$PANEL")
assert_rc 0 locate_panel
assert_eq "$INSTALL_MODE" "host" "host mode"
assert_eq "$PANEL_DIR" "$(realpath "$PANEL")" "picks the panel that has Blueprint"

isolate_search
assert_rc 4 locate_panel "$LARAVEL"
assert_rc 2 locate_panel "$ONLY_PTERO"
assert_rc 0 locate_panel "$PANEL"
assert_eq "$PANEL_DIR" "$(realpath "$PANEL")" "explicit path"

echo "a missing node module is reported through the caller array"
mkdir -p "$PANEL/node_modules/react"
nested_missing="$(
    check_nested_missing() {
        local missing=()
        PANEL_DIR="$PANEL"
        require_node_module "webpack"
        printf '%s\n' "${missing[*]}"
    }
    check_nested_missing
)"
assert_eq "$(printf '%s\n' "$nested_missing" | tail -n 1)" "webpack" "nested missing module"

echo "missing search paths do not fall back to this machine"
isolate_search
assert_rc 3 locate_panel

if [[ "$FAILURES" -gt 0 ]]; then
    echo "${FAILURES} test(s) failed." >&2
    exit 1
fi

echo "All detection tests passed."
