#!/bin/bash
# =============================================================================
#  Blueprint Plugin Reinstaller
#  Automatically reinstalls all Blueprint (Pterodactyl) plugins on this machine
#  https://github.com/luoxthedev/plugin-installer-for-blueprint
# =============================================================================

set -euo pipefail

# ── Colors & formatting ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

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
    echo -e "${DIM}  Blueprint Plugin Reinstaller — Pterodactyl Panel${RESET}"
    echo -e "${DIM}  ─────────────────────────────────────────────────────────────${RESET}"
    echo ""
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
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── Dependency check & Auto-installer ─────────────────────────────────────────
check_dependencies() {
    step "Checking dependencies..."
    local missing=()
    local apt_packages=()

    # Mapping entre la commande et le paquet apt réel
    for cmd in php composer curl unzip jq; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd is available"
        else
            warn "$cmd is NOT found"
            missing+=("$cmd")
            
            # Ajustement pour composer qui s'installe via le paquet 'composer' sur Debian
            if [[ "$cmd" == "composer" ]]; then
                apt_packages+=("composer")
            elif [[ "$cmd" == "php" ]]; then
                apt_packages+=("php-cli")
            else
                apt_packages+=("$cmd")
            fi
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        warn "Missing required dependencies: ${missing[*]}"
        info "Updating package lists to calculate download size..."
        
        # Update discret pour rafraîchir les tailles de paquets
        apt-get update -qq
        
        # Récupération de la taille requise via apt-get (simulation -s)
        local size_info
        size_info=$(apt-get install -s -y "${apt_packages[@]}" 2>/dev/null | grep -E "Need to get|after this operation" || true)
        
        # Extraction propre de l'espace disque additionnel requis
        local disk_space="unknown size"
        if [[ "$size_info" =~ ([0-9]+[[:space:]]*[kMGT]B)[[:space:]]of[[:space:]]additional ]]; then
            disk_space="${BASH_REMATCH[1]}"
        elif [[ "$size_info" =~ ([0-9,.]+[[:space:]]*[kMGT]b)[[:space:]]d\’espace ]]; then # Fallback selon la locale FR
            disk_space="${BASH_REMATCH[1]}"
        fi

        echo ""
        info "Estimated disk space needed for installation: ${BOLD}$disk_space${RESET}"
        read -rp "  Would you like to automatically install these dependencies now? [y/N] " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            step "Installing missing dependencies..."
            if apt-get install -y "${apt_packages[@]}"; then
                success "All dependencies successfully installed!"
            else
                error "Failed to install dependencies automatically. Please run: apt-get install -y ${apt_packages[*]}"
                exit 1
            fi
        else
            info "Aborted by user. Missing tools prevent script execution."
            exit 0
        fi
    fi
}

# ── Detect Blueprint install directory ────────────────────────────────────────
detect_blueprint_path() {
    step "Detecting Blueprint installation..."

    local candidates=(
        "/var/www/pterodactyl"
        "/var/www/panel"
        "/srv/pterodactyl"
        "/opt/pterodactyl"
    )

    PANEL_DIR=""
    for dir in "${candidates[@]}"; do
        if [[ -f "$dir/config/app.php" ]] && [[ -d "$dir/blueprint" ]]; then
            PANEL_DIR="$dir"
            break
        fi
    done

    if [[ -z "$PANEL_DIR" ]]; then
        warn "Could not auto-detect Pterodactyl + Blueprint directory."
        read -rp "  Enter the panel root path manually: " PANEL_DIR
        if [[ ! -d "$PANEL_DIR" ]]; then
            error "Directory '$PANEL_DIR' does not exist. Aborting."
            exit 1
        fi
    fi

    success "Panel found at: ${BOLD}$PANEL_DIR${RESET}"
    BLUEPRINT_DIR="$PANEL_DIR/blueprint"
    EXTENSIONS_DIR="$BLUEPRINT_DIR/extensions"
}

# ── Discover installed plugins ────────────────────────────────────────────────
discover_plugins() {
    step "Scanning for installed Blueprint plugins..."

    if [[ ! -d "$EXTENSIONS_DIR" ]]; then
        error "Extensions directory not found: $EXTENSIONS_DIR"
        error "Make sure Blueprint is properly installed."
        exit 1
    fi

    mapfile -t PLUGIN_DIRS < <(find "$EXTENSIONS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    PLUGINS=()
    for dir in "${PLUGIN_DIRS[@]}"; do
        local name
        name=$(basename "$dir")
        PLUGINS+=("$name")
    done

    local count=${#PLUGINS[@]}

    echo ""
    divider

    if [[ $count -eq 0 ]]; then
        warn "No Blueprint plugins were found in $EXTENSIONS_DIR"
        exit 0
    fi

    echo -e "  ${GREEN}${BOLD}Found $count plugin(s):${RESET}"
    echo ""
    for i in "${!PLUGINS[@]}"; do
        local num=$((i + 1))
        local pname="${PLUGINS[$i]}"
        local conf="$EXTENSIONS_DIR/$pname/conf.yml"
        local version="unknown"

        if [[ -f "$conf" ]]; then
            version=$(grep -i '^version:' "$conf" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1 || echo "unknown")
        fi

        printf "  ${DIM}%2d.${RESET}  ${BOLD}%-28s${RESET} ${DIM}v%s${RESET}\n" "$num" "$pname" "$version"
    done

    divider
    echo ""
}

# ── Ask the user what to install ──────────────────────────────────────────────
ask_user() {
    echo -e "  ${BOLD}What would you like to do?${RESET}"
    echo ""
    echo -e "    ${CYAN}[A]${RESET}  Reinstall ALL plugins (${#PLUGINS[@]} total)"
    echo -e "    ${CYAN}[S]${RESET}  Select specific plugins"
    echo -e "    ${CYAN}[Q]${RESET}  Quit"
    echo ""
    read -rp "  Your choice [A/S/Q]: " CHOICE
    echo ""

    case "${CHOICE^^}" in
        A)
            SELECTED_PLUGINS=("${PLUGINS[@]}")
            info "All ${#SELECTED_PLUGINS[@]} plugins will be reinstalled."
            ;;
        S)
            select_plugins
            ;;
        Q)
            info "Aborted. No changes were made."
            exit 0
            ;;
        *)
            warn "Invalid choice. Please enter A, S, or Q."
            ask_user
            ;;
    esac
}

# ── Manual selection ──────────────────────────────────────────────────────────
select_plugins() {
    echo -e "  Enter the ${BOLD}numbers${RESET} of the plugins to reinstall, separated by spaces."
    echo -e "  Example: ${DIM}1 3 5${RESET}"
    echo ""
    read -rp "  Plugins: " -a RAW_INDICES
    echo ""

    SELECTED_PLUGINS=()
    for idx in "${RAW_INDICES[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#PLUGINS[@]} )); then
            SELECTED_PLUGINS+=("${PLUGINS[$((idx-1))]}")
        else
            warn "Skipping invalid index: $idx"
        fi
    done

    if [[ ${#SELECTED_PLUGINS[@]} -eq 0 ]]; then
        warn "No valid plugins selected. Aborting."
        exit 0
    fi

    info "Selected: ${SELECTED_PLUGINS[*]}"
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm_reinstall() {
    local count=${#SELECTED_PLUGINS[@]}
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  You are about to REINSTALL $count plugin(s):${RESET}"
    echo ""
    for p in "${SELECTED_PLUGINS[@]}"; do
        echo -e "    ${DIM}•${RESET} $p"
    </done>
    echo ""
    warn "This will re-run Blueprint install for each selected plugin."
    warn "Existing plugin data in the database is NOT removed."
    echo ""
    read -rp "  Confirm reinstall? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
    echo ""
}

# ── Find Blueprint CLI ────────────────────────────────────────────────────────
find_blueprint_cli() {
    BLUEPRINT_CLI=""

    local candidates=(
        "$PANEL_DIR/blueprint.sh"
        "$PANEL_DIR/blueprint"
        "/usr/local/bin/blueprint"
    )

    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then
            BLUEPRINT_CLI="$c"
            break
        fi
    done

    if [[ -z "$BLUEPRINT_CLI" ]]; then
        # Fallback: look for it anywhere in panel dir
        BLUEPRINT_CLI=$(find "$PANEL_DIR" -maxdepth 2 -name "blueprint.sh" -o -name "blueprint" \
                        2>/dev/null | head -1 || true)
    fi

    if [[ -z "$BLUEPRINT_CLI" ]]; then
        error "Could not find the Blueprint CLI (blueprint.sh) in $PANEL_DIR"
        error "Please make sure Blueprint is correctly installed."
        exit 1
    fi

    success "Blueprint CLI found: $BLUEPRINT_CLI"
}

# ── Reinstall plugins ─────────────────────────────────────────────────────────
reinstall_plugins() {
    step "Starting reinstallation..."
    echo ""

    local total=${#SELECTED_PLUGINS[@]}
    local success_count=0
    local fail_count=0
    local failed_list=()

    cd "$PANEL_DIR"

    for i in "${!SELECTED_PLUGINS[@]}"; do
        local plugin="${SELECTED_PLUGINS[$i]}"
        local num=$((i + 1))

        echo -e "  ${BOLD}[$num/$total]${RESET} Installing ${CYAN}${plugin}${RESET}..."

        # Blueprint re-install command:
        if bash "$BLUEPRINT_CLI" -install "$plugin" 2>&1 | \
               sed 's/^/          /'; then
            success "[$num/$total] ${plugin} — done"
            (( success_count++ )) || true
        else
            error "[$num/$total] ${plugin} — FAILED"
            (( fail_count++ )) || true
            failed_list+=("$plugin")
        fi

        echo ""
    done

    # ── Summary ───────────────────────────────────────────────────────────────
    divider
    echo ""
    echo -e "  ${BOLD}Reinstallation Summary${RESET}"
    echo ""
    echo -e "    ${GREEN}✔  Success:${RESET}  $success_count / $total"

    if [[ $fail_count -gt 0 ]]; then
        echo -e "    ${RED}✘  Failed:${RESET}   $fail_count / $total"
        echo ""
        echo -e "  ${RED}Failed plugins:${RESET}"
        for p in "${failed_list[@]}"; do
            echo -e "    ${DIM}•${RESET} $p"
        done
    fi

    echo ""
    divider
}

# ── Post-install tasks ────────────────────────────────────────────────────────
post_install() {
    step "Running post-install tasks..."

    cd "$PANEL_DIR"

    info "Clearing Laravel cache..."
    php artisan cache:clear    2>&1 | sed 's/^/          /'
    php artisan config:clear   2>&1 | sed 's/^/          /'
    php artisan view:clear     2>&1 | sed 's/^/          /'
    php artisan route:clear    2>&1 | sed 's/^/          /'
    success "Cache cleared."

    info "Running database migrations..."
    php artisan migrate --force 2>&1 | sed 's/^/          /'
    success "Migrations done."

    info "Setting correct permissions..."
    chown -R www-data:www-data "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || \
    chown -R nginx:nginx      "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || \
    warn "Could not set permissions automatically. Set them manually if needed."
    success "Permissions applied."

    info "Restarting queue workers..."
    php artisan queue:restart 2>&1 | sed 's/^/          /'
    success "Queue restarted."
}

# ── Install self as global command ────────────────────────────────────────────
install_global_command() {
    local target="/usr/local/bin/blueprint-plugin-installer"
    
    if [[ ! -f "$target" ]]; then
        info "Installing global command 'blueprint-plugin-installer'..."
        
        if [[ -f "$0" ]]; then
            cp "$(realpath "$0")" "$target"
        else
            curl -fsSL "https://raw.githubusercontent.com/luoxthedev/plugin-installer-for-blueprint/main/install.sh" -o "$target"
        fi
        
        chmod +x "$target"
        success "You can now run: ${BOLD}blueprint-plugin-installer${RESET} at any time."
    fi
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    install_global_command
    check_dependencies
    detect_blueprint_path
    discover_plugins
    ask_user
    confirm_reinstall
    find_blueprint_cli
    reinstall_plugins
    post_install

    echo ""
    echo -e "  ${GREEN}${BOLD}✔  All done! Your Blueprint plugins have been reinstalled.${RESET}"
    echo -e "  ${DIM}If you encounter issues, check the logs in $PANEL_DIR/storage/logs/${RESET}"
    echo ""
}

main "$@"
