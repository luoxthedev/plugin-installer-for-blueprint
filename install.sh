#!/bin/bash
# =============================================================================
#  Blueprint Plugin Reinstaller
#  Reinstalls Blueprint extensions on a Pterodactyl panel that is ALREADY set up.
#  https://github.com/luoxthedev/plugin-installer-for-blueprint
#
#  This script never installs Pterodactyl or Blueprint. Both have to be present.
#
#  Pterodactyl (https://docs.pterodactyl.io/panel/1.0/getting_started):
#    the panel root (normally /var/www/pterodactyl, or /app inside the official
#    and Blueprint Docker images) must already contain artisan,
#    config/pterodactyl.php, composer.json name "pterodactyl/panel",
#    vendor/autoload.php, and a non-empty APP_KEY in .env.
#
#  Blueprint (https://blueprint.zip/guides/admin/install and blueprint.sh):
#    installation is finished only when blueprint.sh, the extension installer,
#    app/BlueprintFramework and a setup marker all exist. Current releases
#    touch db/is_installed. beta-2024-12 records "* blueprint.setupFinished;"
#    in db/database. Node.js must match the check inside that blueprint.sh
#    (22 on current releases, 17 on beta-2024-12).
#    Extensions are reinstalled with `blueprint -install <id>`, which itself
#    rebuilds assets, flushes caches, fixes ownership from .blueprintrc and
#    runs migrations (migrations are skipped when Blueprint sees Docker).
# =============================================================================

set -euo pipefail

VERSION="v1.4.0"

# Overridable in tests. Unset means "use the real machine".
PTERODACTYL_DOCKERENV="${PTERODACTYL_DOCKERENV:-/.dockerenv}"
PTERODACTYL_DOCKER_APP="${PTERODACTYL_DOCKER_APP:-/app}"

# ── Colors & formatting ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

INSTALL_MODE=""
PANEL_DIR=""
COMPOSE_FILE=""
LOCATE_DETAIL=""
MAINTENANCE_ENABLED=0

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ██████╗ ██╗     ██╗   ██╗███████╗██████╗ ██████╗ ██╗███╗   ██╗████████╗"
    echo "  ██╔══██╗██║     ██║   ██║██╔════╝██╔══██╗██╔══██╗██║████╗  ██║╚══██╔══╝"
    echo "  ██████╔╝██║     ██║   ██║█████╗  ██████╔╝██████╔╝██║██╔██╗ ██║   ██║   "
    echo "  ██╔══██╗██║     ██║   ██║██╔══╝  ██╔═══╝ ██╔══██╗██║██║╚██╗██║   ██║   "
    echo "  ██████╔╝███████╗╚██████╔╝███████╗██║     ██║  ██║██║██║ ╚████║   ██║   "
    echo "  ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝   ╚═╝   "
    echo -e "${RESET}"
    echo -e "${DIM}  Blueprint Plugin Reinstaller — Pterodactyl Panel (${VERSION})${RESET}"
    echo -e "${DIM}  ─────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

usage() {
    cat <<EOF
Usage: blueprint-plugin-installer [panel-directory]

Reinstall Blueprint extensions on an existing Pterodactyl panel.
If Pterodactyl or Blueprint is not already installed, the script stops.

  panel-directory    Optional. Defaults to the first real installation found:
                     /var/www/pterodactyl, /var/www/panel, /opt/pterodactyl,
                     /app when running inside the panel container, or a running
                     Blueprint Docker stack at /srv/pterodactyl/docker-compose.yml.
EOF
}

# ── Logging helpers ───────────────────────────────────────────────────────────
info()    { echo -e "  ${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "  ${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "  ${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n  ${BLUE}${BOLD}▶ $*${RESET}"; }
divider() { echo -e "  ${DIM}────────────────────────────────────────────────────${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── Update / Install Global Command ───────────────────────────────────────────
sync_global_command() {
    local target="/usr/local/bin/blueprint-plugin-installer"

    info "Syncing and updating global command 'blueprint-plugin-installer'..."

    if [[ -f "$0" && "$(basename "$0")" == "install.sh" ]]; then
        cp "$(realpath "$0")" "$target"
    else
        curl -fsSL "https://raw.githubusercontent.com/luoxthedev/plugin-installer-for-blueprint/main/install.sh" -o "$target"
    fi

    chmod +x "$target"
}

# ── Pterodactyl / Blueprint detection ─────────────────────────────────────────
# A configured panel, not a generic Laravel app and not an unpacked archive.
is_pterodactyl_panel() {
    local dir="$1"

    [[ -n "$dir" && -d "$dir" ]] || return 1
    [[ -f "$dir/artisan" ]] || return 1
    [[ -f "$dir/config/pterodactyl.php" ]] || return 1
    [[ -f "$dir/vendor/autoload.php" ]] || return 1
    [[ -f "$dir/composer.json" ]] || return 1
    grep -Eq '"name"[[:space:]]*:[[:space:]]*"pterodactyl/panel"' "$dir/composer.json" || return 1
    panel_app_key_is_set "$dir"
}

panel_app_key_is_set() {
    local env_file="$1/.env"
    local line="" value=""

    [[ -f "$env_file" ]] || return 1
    line=$(grep -E '^[[:space:]]*APP_KEY=' "$env_file" | tail -n 1 || true)
    [[ -n "$line" ]] || return 1

    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"

    [[ -n "$value" && "$value" != "null" && "$value" != "base64:" ]]
}

# Current Blueprint touches db/is_installed at the end of blueprint.sh.
# beta-2024-12 and older record "* blueprint.setupFinished;" via dbAdd.
blueprint_setup_finished() {
    local dir="$1"
    local db="$dir/.blueprint/extensions/blueprint/private/db"

    [[ -f "$db/is_installed" ]] && return 0
    [[ -f "$db/database" ]] || return 1
    grep -Fxq '* blueprint.setupFinished;' "$db/database"
}

# The other paths are what `blueprint -install` actually executes.
is_blueprint_installed() {
    local dir="$1"

    [[ -f "$dir/blueprint.sh" ]] || return 1
    [[ -f "$dir/scripts/commands/extensions/install.sh" ]] || return 1
    [[ -f "$dir/scripts/libraries/misc.sh" ]] || return 1
    [[ -d "$dir/app/BlueprintFramework" ]] || return 1
    blueprint_setup_finished "$dir"
}

# Marker left behind, but a panel update wiped the framework files.
blueprint_was_wiped() {
    local dir="$1"

    blueprint_setup_finished "$dir" || return 1
    ! is_blueprint_installed "$dir"
}

node_major_from_string() {
    local version="$1"
    version="${version#v}"
    version="${version%%.*}"
    if [[ "$version" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$version"
    fi
}

# Current releases require Node 22. beta-2024-12 requires Node 17.
# Read the check from the Blueprint that is actually installed.
required_node_major() {
    local dir="$1"
    local line=""

    line="$(grep -E 'nodeMajor -lt [0-9]+' "$dir/blueprint.sh" 2>/dev/null | head -n 1 || true)"
    if [[ "$line" =~ -lt[[:space:]]+([0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf '%s\n' "22"
}

blueprint_mentions_node_module() {
    local dir="$1"
    local module="$2"
    grep -q "node_modules/.*${module}" "$dir/blueprint.sh"
}

host_search_paths() {
    if [[ -n "${PTERODACTYL_SEARCH_PATHS+x}" ]]; then
        if [[ ${#PTERODACTYL_SEARCH_PATHS[@]} -gt 0 ]]; then
            printf '%s\n' "${PTERODACTYL_SEARCH_PATHS[@]}"
        fi
        return 0
    fi

    # Blueprint forces the panel directory to /app when /.dockerenv exists.
    if [[ -f "$PTERODACTYL_DOCKERENV" ]]; then
        printf '%s\n' "$PTERODACTYL_DOCKER_APP"
    fi
    printf '%s\n' \
        /var/www/pterodactyl \
        /var/www/panel \
        /opt/pterodactyl
}

docker_compose_candidates() {
    if [[ -n "${DOCKER_COMPOSE_CANDIDATES+x}" ]]; then
        if [[ ${#DOCKER_COMPOSE_CANDIDATES[@]} -gt 0 ]]; then
            printf '%s\n' "${DOCKER_COMPOSE_CANDIDATES[@]}"
        fi
        return 0
    fi
    printf '%s\n' /srv/pterodactyl/docker-compose.yml
}

compose_targets_blueprint() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -Eq 'blueprintframework/blueprint|/blueprint_extensions' "$file"
}

compose_cmd() {
    local work
    work="$(dirname "$COMPOSE_FILE")"
    docker compose --project-directory "$work" -f "$COMPOSE_FILE" "$@"
}

# 0 = running Blueprint panel, 2 = compose file but container stopped,
# 1 = not a usable Blueprint Docker panel.
probe_running_blueprint_docker() {
    local file="$1"
    local cid=""

    [[ -f "$file" ]] || return 1
    compose_targets_blueprint "$file" || return 1
    command -v docker >/dev/null 2>&1 || return 1

    COMPOSE_FILE="$file"
    cid="$(compose_cmd ps --status running -q panel 2>/dev/null || true)"
    [[ -n "$cid" ]] || return 2

    # stdin is the script. -i keeps it open, -T avoids a TTY.
    if compose_cmd exec -iT panel sh -s <<'EOF'
set -eu
test -f /app/artisan
test -f /app/config/pterodactyl.php
test -f /app/vendor/autoload.php
test -f /app/composer.json
test -f /app/blueprint.sh
test -f /app/scripts/commands/extensions/install.sh
test -f /app/scripts/libraries/misc.sh
test -d /app/app/BlueprintFramework
grep -Eq '"name"[[:space:]]*:[[:space:]]*"pterodactyl/panel"' /app/composer.json
line=$(grep -E '^[[:space:]]*APP_KEY=' /app/.env | tail -n 1)
[ -n "$line" ]
val=${line#*=}
val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '"' | tr -d "'")
[ -n "$val" ]
[ "$val" != "null" ]
[ "$val" != "base64:" ]
if [ -f /app/.blueprint/extensions/blueprint/private/db/is_installed ]; then
    exit 0
fi
grep -Fxq '* blueprint.setupFinished;' /app/.blueprint/extensions/blueprint/private/db/database
EOF
    then
        return 0
    fi
    return 7
}

list_docker_extensions() {
    compose_cmd exec -iT panel sh -s <<'EOF'
for f in /app/*.blueprint; do
    [ -f "$f" ] || continue
    basename "$f" .blueprint
done
EOF
}

# 0 installed, 2 Pterodactyl without Blueprint, 3 nothing,
# 4 path is not Pterodactyl, 5 Blueprint files were wiped,
# 6 Docker stack is not running, 7 container is not an installed panel.
locate_panel() {
    local explicit="${1:-}"
    local dir="" file="" rc=0
    local found_ptero="" damaged="" docker_stopped="" docker_invalid=""

    INSTALL_MODE=""
    PANEL_DIR=""
    COMPOSE_FILE=""
    LOCATE_DETAIL=""

    if [[ -n "$explicit" ]]; then
        if ! is_pterodactyl_panel "$explicit"; then
            LOCATE_DETAIL="$explicit"
            return 4
        fi
        if is_blueprint_installed "$explicit"; then
            INSTALL_MODE="host"
            PANEL_DIR="$(realpath "$explicit")"
            return 0
        fi
        LOCATE_DETAIL="$(realpath "$explicit")"
        if blueprint_was_wiped "$explicit"; then
            return 5
        fi
        return 2
    fi

    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if ! is_pterodactyl_panel "$dir"; then
            continue
        fi
        if is_blueprint_installed "$dir"; then
            INSTALL_MODE="host"
            PANEL_DIR="$(realpath "$dir")"
            COMPOSE_FILE=""
            return 0
        fi
        found_ptero="$dir"
        if blueprint_was_wiped "$dir"; then
            damaged="$dir"
        fi
    done < <(host_search_paths)

    while IFS= read -r file; do
        [[ -n "$file" && -f "$file" ]] || continue
        rc=0
        probe_running_blueprint_docker "$file" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            INSTALL_MODE="docker"
            COMPOSE_FILE="$(realpath "$file")"
            PANEL_DIR="/app"
            return 0
        fi
        if [[ "$rc" -eq 2 && -z "$docker_stopped" ]]; then
            docker_stopped="$file"
        elif [[ "$rc" -eq 7 && -z "$docker_invalid" ]]; then
            docker_invalid="$file"
        fi
    done < <(docker_compose_candidates)

    if [[ -n "$damaged" ]]; then
        LOCATE_DETAIL="$(realpath "$damaged")"
        return 5
    fi
    if [[ -n "$found_ptero" ]]; then
        LOCATE_DETAIL="$(realpath "$found_ptero")"
        return 2
    fi
    if [[ -n "$docker_stopped" ]]; then
        LOCATE_DETAIL="$docker_stopped"
        return 6
    fi
    if [[ -n "$docker_invalid" ]]; then
        LOCATE_DETAIL="$docker_invalid"
        return 7
    fi
    return 3
}

explain_locate_failure() {
    local rc="$1"
    case "$rc" in
        2)
            error "Pterodactyl is installed at ${LOCATE_DETAIL}, but Blueprint is not."
            error "This script does not install Blueprint. Install it with the official guide first:"
            error "https://blueprint.zip/guides/admin/install"
            ;;
        3)
            error "No installed Pterodactyl panel and no installed Blueprint were found."
            error "This script does not install either of them, so there is nothing to reinstall."
            ;;
        4)
            error "'${LOCATE_DETAIL}' is not an installed Pterodactyl panel."
            error "Expected artisan, config/pterodactyl.php, composer.json name pterodactyl/panel,"
            error "vendor/autoload.php and a non-empty APP_KEY. A generic Laravel app is not enough."
            ;;
        5)
            error "Blueprint at ${LOCATE_DETAIL} is incomplete. The installed marker is present"
            error "but blueprint.sh or app/BlueprintFramework is missing (a panel update often does this)."
            error "Restore it with 'blueprint -upgrade', then run this script again."
            error "https://blueprint.zip/guides/admin/updateblueprint"
            ;;
        6)
            error "Blueprint Docker is configured at ${LOCATE_DETAIL}, but the panel container is not running."
            error "Start the stack yourself. This script will not start Pterodactyl or Blueprint."
            ;;
        7)
            error "The panel container from ${LOCATE_DETAIL} is running, but it is not an installed"
            error "Pterodactyl + Blueprint panel. Nothing was changed."
            ;;
        *)
            error "Could not find an installed Pterodactyl panel with Blueprint."
            ;;
    esac
}

require_installed_panel() {
    local explicit="${1:-}"
    local rc=0

    step "Detecting an existing Pterodactyl and Blueprint installation..."
    locate_panel "$explicit" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        explain_locate_failure "$rc"
        exit 1
    fi

    if [[ "$INSTALL_MODE" == "host" ]]; then
        success "Pterodactyl panel: ${BOLD}${PANEL_DIR}${RESET}"
        success "Blueprint is installed in that panel."
        if [[ ! -f "$PANEL_DIR/.blueprintrc" ]]; then
            warn "No .blueprintrc was found. Blueprint will use its default www-data ownership."
        fi
    elif [[ "$INSTALL_MODE" == "docker" ]]; then
        success "Blueprint Docker stack: ${BOLD}${COMPOSE_FILE}${RESET}"
        success "Pterodactyl and Blueprint are installed in the running panel container (/app)."
    else
        error "Unknown installation mode '${INSTALL_MODE}'."
        exit 1
    fi
}

# ── Runtime tools Blueprint itself refuses to run without ────────────────────
require_node_module() {
    local module="$1"
    local -a matches=()
    local glob_state

    # shopt -p returns 1 when the option is off. Ignore that status.
    glob_state="$(shopt -p nullglob || true)"
    shopt -s nullglob
    matches=("$PANEL_DIR"/node_modules/*"$module"*)
    eval "$glob_state"

    if [[ ${#matches[@]} -eq 0 ]]; then
        warn "${module} is missing from ${PANEL_DIR}/node_modules"
        missing+=("$module")
    else
        success "${module} is installed in the panel"
    fi
}

require_host_runtime() {
    local missing=()
    local cmd="" major="" version="" required="22"

    step "Checking Blueprint runtime dependencies..."

    for cmd in unzip zip curl php git grep sed awk tput node yarn; do
        if command -v "$cmd" >/dev/null 2>&1; then
            success "$cmd is available"
        else
            warn "$cmd is NOT installed"
            missing+=("$cmd")
        fi
    done

    required="$(required_node_major "$PANEL_DIR")"
    if command -v node >/dev/null 2>&1; then
        version="$(node -v 2>/dev/null || true)"
        major="$(node_major_from_string "$version")"
        if [[ -z "$major" || "$major" -lt "$required" ]]; then
            warn "node ${version:-unknown} is older than Node.js ${required}, which this Blueprint requires"
            missing+=("node>=${required}")
        else
            success "node ${version} (>= ${required})"
        fi
    fi

    require_node_module "webpack"
    require_node_module "react"
    if blueprint_mentions_node_module "$PANEL_DIR" "cross-env"; then
        require_node_module "cross-env"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing runtime pieces: ${missing[*]}"
        error "Blueprint cannot reinstall extensions without them, and this script does not install them."
        exit 1
    fi
}

require_docker_runtime() {
    step "Checking Docker..."
    if ! command -v docker >/dev/null 2>&1; then
        error "docker is not installed. This script does not install it."
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        error "'docker compose' is not available. Blueprint Docker needs Compose v2."
        exit 1
    fi
    success "docker compose is available"
}

# ── Discover .blueprint files ─────────────────────────────────────────────────
collect_blueprint_names() {
    local dir="$1"
    local file="" name=""
    local names=()
    local glob_state

    [[ -d "$dir" ]] || return 0
    # shopt -p returns 1 when the option is off. Ignore that status.
    glob_state="$(shopt -p nullglob || true)"
    shopt -s nullglob
    for file in "$dir"/*.blueprint; do
        [[ -f "$file" ]] || continue
        name="$(basename "$file" .blueprint)"
        [[ -n "$name" ]] || continue
        names+=("$name")
    done
    eval "$glob_state"

    if [[ ${#names[@]} -gt 0 ]]; then
        printf '%s\n' "${names[@]}" | sort
    fi
}

discover_plugins() {
    local host_extensions="" host_name="" known=""
    local -a host_names=()

    step "Scanning for .blueprint extension files..."
    PLUGINS=()

    if [[ "$INSTALL_MODE" == "host" ]]; then
        mapfile -t PLUGINS < <(collect_blueprint_names "$PANEL_DIR")
    else
        local listed=""
        if ! listed="$(list_docker_extensions)"; then
            error "Could not list .blueprint files inside the panel container."
            exit 1
        fi
        if [[ -n "$listed" ]]; then
            mapfile -t PLUGINS < <(printf '%s\n' "$listed" | sort)
        fi
        host_extensions="$(dirname "$COMPOSE_FILE")/extensions"
        if [[ -d "$host_extensions" ]]; then
            mapfile -t host_names < <(collect_blueprint_names "$host_extensions")
            for host_name in "${host_names[@]}"; do
                known=" ${PLUGINS[*]} "
                if [[ "$known" != *" ${host_name} "* ]]; then
                    warn "${host_name}.blueprint is in ${host_extensions} but not in the container's /app yet."
                    warn "Blueprint Docker syncs that folder itself. This script will not copy it."
                fi
            done
        fi
    fi

    echo ""
    divider

    if [[ ${#PLUGINS[@]} -eq 0 ]]; then
        warn "No '.blueprint' files were found where Blueprint installs them."
        if [[ "$INSTALL_MODE" == "host" ]]; then
            warn "Put identifier.blueprint in ${PANEL_DIR} first."
        else
            warn "Put identifier.blueprint in $(dirname "$COMPOSE_FILE")/extensions and wait until it appears in /app."
        fi
        exit 1
    fi

    echo -e "  ${GREEN}${BOLD}Found ${#PLUGINS[@]} extension file(s):${RESET}"
    echo ""
    local i num
    for i in "${!PLUGINS[@]}"; do
        num=$((i + 1))
        printf "  ${DIM}%2d.${RESET}  ${BOLD}%s.blueprint${RESET}\n" "$num" "${PLUGINS[$i]}"
    done

    divider
    echo ""
}

# ── Ask the user what to install ──────────────────────────────────────────────
ask_user() {
    local choice=""

    while true; do
        echo -e "  ${BOLD}What would you like to do?${RESET}"
        echo ""
        echo -e "    ${CYAN}[A]${RESET}  Reinstall ALL extensions (${#PLUGINS[@]} total)"
        echo -e "    ${CYAN}[S]${RESET}  Select specific extensions"
        echo -e "    ${CYAN}[Q]${RESET}  Quit"
        echo ""

        choice=""
        read -rp "  Your choice [A/S/Q]: " choice </dev/tty
        echo ""

        case "${choice^^}" in
            A)
                SELECTED_PLUGINS=("${PLUGINS[@]}")
                info "All ${#SELECTED_PLUGINS[@]} extensions will be reinstalled."
                return 0
                ;;
            S)
                select_plugins
                return 0
                ;;
            Q)
                info "Aborted. No changes were made."
                exit 0
                ;;
            *)
                warn "Invalid choice. Please enter A, S, or Q."
                echo ""
                ;;
        esac
    done
}

# ── Manual selection ──────────────────────────────────────────────────────────
select_plugins() {
    echo -e "  Enter the ${BOLD}numbers${RESET} of the extensions to reinstall, separated by spaces."
    echo -e "  Example: ${DIM}1 3 5${RESET}"
    echo ""
    local raw_indices=()
    local idx=""
    read -rp "  Extensions: " -a raw_indices </dev/tty
    echo ""

    SELECTED_PLUGINS=()
    for idx in "${raw_indices[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#PLUGINS[@]} )); then
            SELECTED_PLUGINS+=("${PLUGINS[$((idx - 1))]}")
        else
            warn "Skipping invalid index: $idx"
        fi
    done

    if [[ ${#SELECTED_PLUGINS[@]} -eq 0 ]]; then
        warn "No valid extensions selected. Aborting."
        exit 0
    fi

    info "Selected: ${SELECTED_PLUGINS[*]}"
}

extension_name_is_safe() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm_reinstall() {
    local count=${#SELECTED_PLUGINS[@]}
    local plugin=""
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  You are about to REINSTALL ${count} extension(s):${RESET}"
    echo ""
    for plugin in "${SELECTED_PLUGINS[@]}"; do
        echo -e "    ${DIM}•${RESET} ${plugin}.blueprint"
    done
    echo ""
    warn "Blueprint will run 'blueprint -install' once for the whole selection."
    warn "That rebuilds panel assets and does not delete extension database rows."
    echo ""
    local confirm=""
    read -rp "  Confirm reinstall? [y/N] " confirm </dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
    echo ""
}

# ── Commands against the detected panel ──────────────────────────────────────
run_artisan() {
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        compose_cmd exec -T panel php artisan "$@"
    else
        (
            cd "$PANEL_DIR"
            php artisan "$@"
        )
    fi
}

run_blueprint() {
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        compose_cmd exec -T panel blueprint "$@"
    else
        bash "$PANEL_DIR/blueprint.sh" -bash "$@"
    fi
}

panel_in_maintenance() {
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        compose_cmd exec -T panel sh -c 'test -f /app/storage/framework/down'
        return
    fi
    [[ -f "$PANEL_DIR/storage/framework/down" ]]
}

enable_maintenance() {
    if panel_in_maintenance; then
        info "Panel is already in maintenance mode. It will be left that way."
        return 0
    fi
    step "Putting the panel into maintenance mode..."
    run_artisan down
    MAINTENANCE_ENABLED=1
    success "Maintenance mode enabled."
}

disable_maintenance() {
    if [[ "$MAINTENANCE_ENABLED" != 1 ]]; then
        return 0
    fi
    MAINTENANCE_ENABLED=0
    step "Bringing the panel back online..."
    if run_artisan up; then
        success "Panel is online."
    else
        warn "Could not leave maintenance mode. From the panel directory, run: php artisan up"
        return 1
    fi
}

on_exit() {
    local status=$?
    trap - EXIT
    disable_maintenance || true
    exit "$status"
}

# ── Reinstall plugins ─────────────────────────────────────────────────────────
reinstall_plugins() {
    local plugin=""
    local -a safe=()
    local rc=0

    for plugin in "${SELECTED_PLUGINS[@]}"; do
        if extension_name_is_safe "$plugin"; then
            safe+=("$plugin")
        else
            warn "Skipping '${plugin}': Blueprint receives each name as one argument, without spaces."
        fi
    done
    if [[ ${#safe[@]} -eq 0 ]]; then
        error "No safe extension names left to install."
        exit 1
    fi
    SELECTED_PLUGINS=("${safe[@]}")

    step "Reinstalling extensions..."
    info "blueprint -install ${SELECTED_PLUGINS[*]}"
    info "Blueprint rebuilds assets, refreshes its caches, applies .blueprintrc ownership and migrates."
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        info "On Blueprint Docker, Blueprint itself skips database migrations."
    fi
    echo ""

    set +e
    run_blueprint -install "${SELECTED_PLUGINS[@]}"
    rc=$?
    set -e

    echo ""
    divider
    echo ""
    if [[ "$rc" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}Blueprint finished the reinstall.${RESET}"
    else
        echo -e "  ${RED}${BOLD}Blueprint reported a failure (exit ${rc}).${RESET}"
        if [[ "$INSTALL_MODE" == "host" ]]; then
            echo -e "  ${DIM}Details: ${PANEL_DIR}/.blueprint/extensions/blueprint/private/debug/logs.txt${RESET}"
        else
            echo -e "  ${DIM}Details inside the container: /app/.blueprint/extensions/blueprint/private/debug/logs.txt${RESET}"
        fi
    fi
    echo ""
    divider
    return "$rc"
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
    local explicit=""

    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        -V|--version)
            printf '%s\n' "$VERSION"
            exit 0
            ;;
        "")
            explicit=""
            ;;
        *)
            if [[ $# -gt 1 ]]; then
                usage >&2
                exit 1
            fi
            explicit="$1"
            ;;
    esac

    print_banner
    check_root
    sync_global_command
    require_installed_panel "$explicit"

    if [[ "$INSTALL_MODE" == "docker" ]]; then
        require_docker_runtime
    else
        require_host_runtime
    fi

    discover_plugins
    ask_user
    confirm_reinstall

    trap on_exit EXIT
    enable_maintenance
    if reinstall_plugins; then
        disable_maintenance
        trap - EXIT
        echo ""
        echo -e "  ${GREEN}${BOLD}✔  All done. Blueprint reinstalled the selected extensions.${RESET}"
        if [[ "$INSTALL_MODE" == "host" ]]; then
            echo -e "  ${DIM}Logs: ${PANEL_DIR}/storage/logs/ and ${PANEL_DIR}/.blueprint/extensions/blueprint/private/debug/logs.txt${RESET}"
        else
            echo -e "  ${DIM}Container logs: /app/storage/logs/ and /app/.blueprint/extensions/blueprint/private/debug/logs.txt${RESET}"
        fi
        echo ""
    else
        disable_maintenance
        trap - EXIT
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
