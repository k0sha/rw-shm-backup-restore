#!/bin/bash

set -e

VERSION="3.3.0"
INSTALL_DIR="/opt/rw-backup-restore"
BACKUP_DIR="$INSTALL_DIR/backup"
CONFIG_FILE="$INSTALL_DIR/config.env"
SCRIPT_NAME="backup-restore.sh"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
RETAIN_BACKUPS_DAYS=7
S3_RETAIN_DAYS=30
SYMLINK_PATH="/usr/local/bin/rw-backup"
REMNALABS_ROOT_DIR=""
SCRIPT_REPO_URL="https://raw.githubusercontent.com/k0sha/rw-shm-backup-restore/main/backup-restore.sh"
SCRIPT_RUN_PATH="$(realpath "$0")"
GD_CLIENT_ID=""
GD_CLIENT_SECRET=""
GD_REFRESH_TOKEN=""
GD_FOLDER_ID=""
S3_ENDPOINT=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_BUCKET=""
S3_REGION=""
S3_PREFIX=""
UPLOAD_METHOD="telegram"
DB_CONNECTION_TYPE="docker"
DB_HOST=""
DB_PORT="5432"
DB_NAME="postgres"
DB_PASSWORD=""
DB_SSL_MODE="prefer"
DB_POSTGRES_VERSION="17"
CRON_TIMES=""
TG_MESSAGE_THREAD_ID=""
TG_PROXY=""
UPDATE_AVAILABLE=false
AUTO_UPDATE="false"
BACKUP_EXCLUDE_PATTERNS="*.log *.tmp .git"
LANG_CODE=""
TRANSLATIONS_DIR="$INSTALL_DIR/translations"

REMNAWAVE_ENABLED="false"
SHM_ENABLED="false"
SHM_ROOT_DIR=""


if [[ -t 0 ]]; then
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    GRAY=$'\e[37m'
    LIGHT_GRAY=$'\e[90m'
    CYAN=$'\e[36m'
    RESET=$'\e[0m'
    BOLD=$'\e[1m'
else
    RED=""
    GREEN=""
    YELLOW=""
    GRAY=""
    LIGHT_GRAY=""
    CYAN=""
    RESET=""
    BOLD=""
fi

declare -A L

t() {
    local key="$1"
    if [[ -n "${L[$key]+x}" ]]; then
        echo "${L[$key]}"
    else
        echo "$key"
    fi
}

download_translations() {
    local base_url="${SCRIPT_REPO_URL%/*}"
    mkdir -p "$TRANSLATIONS_DIR"
    for lang_file in ru.sh en.sh; do
        if ! curl -fsSL "$base_url/translations/$lang_file" -o "$TRANSLATIONS_DIR/$lang_file" 2>/dev/null; then
            echo -e "${RED}[ERROR]${RESET} Failed to download $lang_file"
        fi
    done
}

load_language() {
    local lang="${1:-ru}"
    local lang_file="$TRANSLATIONS_DIR/${lang}.sh"
    if [[ -f "$lang_file" ]]; then
        source "$lang_file"
    elif [[ -f "$TRANSLATIONS_DIR/ru.sh" ]]; then
        source "$TRANSLATIONS_DIR/ru.sh"
    fi
}

select_language_interactive() {
    echo ""
    echo "Select language / Выберите язык:"
    echo " 1. Русский"
    echo " 2. English"
    echo ""
    local lang_choice
    read -rp " [?]: " lang_choice
    case "$lang_choice" in
        2) LANG_CODE="en" ;;
        *) LANG_CODE="ru" ;;
    esac
    load_language "$LANG_CODE"
}

print_message() {
    local type="$1"
    local message="$2"
    local color_code="$RESET"

    case "$type" in
        "INFO") color_code="$GRAY" ;;
        "SUCCESS") color_code="$GREEN" ;;
        "WARN") color_code="$YELLOW" ;;
        "ERROR") color_code="$RED" ;;
        "ACTION") color_code="$CYAN" ;;
        "LINK") color_code="$CYAN" ;;
        *) type="INFO" ;;
    esac

    echo -e "${color_code}[$type]${RESET} $message"
}

setup_symlink() {
    echo ""
    if [[ "$EUID" -ne 0 ]]; then
        print_message "WARN" "$(t symlink_root) ${BOLD}${SYMLINK_PATH}${RESET}. $(t symlink_skip)"
        return 1
    fi

    if [[ -L "$SYMLINK_PATH" && "$(readlink -f "$SYMLINK_PATH")" == "$SCRIPT_PATH" ]]; then
        print_message "SUCCESS" "$(t symlink_ok) ${BOLD}${SCRIPT_PATH}${RESET}."
        return 0
    fi

    print_message "INFO" "$(t symlink_creating) ${BOLD}${SYMLINK_PATH}${RESET}..."
    rm -f "$SYMLINK_PATH"
    if [[ -d "$(dirname "$SYMLINK_PATH")" ]]; then
        if ln -s "$SCRIPT_PATH" "$SYMLINK_PATH"; then
            print_message "SUCCESS" "$(t symlink_created)"
        else
            print_message "ERROR" "$(t symlink_fail) ${BOLD}${SYMLINK_PATH}${RESET}. $(t check_permissions)"
            return 1
        fi
    else
        print_message "ERROR" "$(t symlink_dir_missing)"
        return 1
    fi
    echo ""
    return 0
}

compare_versions() {
    local v1="$1"
    local v2="$2"

    local v1_num="${v1//[^0-9.]/}"
    local v2_num="${v2//[^0-9.]/}"

    local v1_sfx="${v1//$v1_num/}"
    local v2_sfx="${v2//$v2_num/}"

    if [[ "$v1_num" == "$v2_num" ]]; then
        if [[ -z "$v1_sfx" && -n "$v2_sfx" ]]; then
            return 0
        elif [[ -n "$v1_sfx" && -z "$v2_sfx" ]]; then
            return 1
        elif [[ "$v1_sfx" < "$v2_sfx" ]]; then
            return 0
        else
            return 1
        fi
    else
        if printf '%s\n' "$v1_num" "$v2_num" | sort -V | head -n1 | grep -qx "$v1_num"; then
            return 0
        else
            return 1
        fi
    fi
}

create_shm_backup() {
    local SHM_DUMP_FILE="shm_dump_${TIMESTAMP}.sql.gz"
    local SHM_DIR_ARCHIVE="shm_dir_${TIMESTAMP}.tar.gz"

    print_message "INFO" "$(t shm_creating)..."

    local shm_mysql_container
    shm_mysql_container=$(docker ps --format '{{.Names}}' | grep -iE 'shm.*(db|mysql|mariadb)|(db|mysql|mariadb).*shm' | head -n 1)

    if [[ -z "$shm_mysql_container" ]]; then
        print_message "ERROR" "$(t shm_db_not_found)"
        return 1
    fi

    print_message "INFO" "$(t shm_dumping)..."
    if ! docker exec "$shm_mysql_container" mysqldump --all-databases -u root 2>/dev/null | gzip -9 > "$BACKUP_DIR/$SHM_DUMP_FILE"; then
        print_message "ERROR" "$(t shm_dump_err)"
        return 1
    fi
    print_message "SUCCESS" "$(t shm_dump_ok)"

    if [[ -d "$SHM_ROOT_DIR" ]]; then
        print_message "INFO" "$(t shm_archiving) ${BOLD}${SHM_ROOT_DIR}${RESET}..."
        local exclude_args=""
        for pattern in $BACKUP_EXCLUDE_PATTERNS; do
            exclude_args+="--exclude=$pattern "
        done

        if eval "tar -czf '$BACKUP_DIR/$SHM_DIR_ARCHIVE' $exclude_args -C '$(dirname "$SHM_ROOT_DIR")' '$(basename "$SHM_ROOT_DIR")'"; then
            print_message "SUCCESS" "$(t shm_arch_ok)"
        else
            print_message "ERROR" "$(t shm_arch_err)"
            return 1
        fi
    else
        print_message "ERROR" "$(t bk_dir_missing) ${BOLD}${SHM_ROOT_DIR}${RESET}"
        return 1
    fi

    BACKUP_ITEMS+=("$SHM_DUMP_FILE" "$SHM_DIR_ARCHIVE")
    print_message "SUCCESS" "$(t shm_done)"
    echo ""
    return 0
}

check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        print_message "ERROR" "$(t docker_missing)"
        read -rp " ${GREEN}[?]${RESET} $(t docker_install_q) (${GREEN}y${RESET}/${RED}n${RESET}): " install_choice
        
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            print_message "INFO" "$(t docker_installing)"
            if curl -fsSL https://get.docker.com | sh > /dev/null 2>&1; then
                print_message "SUCCESS" "$(t docker_installed)"
            else
                print_message "ERROR" "$(t docker_install_fail)"
                return 1
            fi
        else
            print_message "INFO" "$(t docker_cancelled)"
            return 1
        fi
    fi
    return 0
}


save_config() {
    print_message "INFO" "$(t saving_config) ${BOLD}${CONFIG_FILE}${RESET}..."
    cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
DB_USER="$DB_USER"
UPLOAD_METHOD="$UPLOAD_METHOD"
GD_CLIENT_ID="$GD_CLIENT_ID"
GD_CLIENT_SECRET="$GD_CLIENT_SECRET"
GD_REFRESH_TOKEN="$GD_REFRESH_TOKEN"
GD_FOLDER_ID="$GD_FOLDER_ID"
S3_ENDPOINT="$S3_ENDPOINT"
S3_ACCESS_KEY="$S3_ACCESS_KEY"
S3_SECRET_KEY="$S3_SECRET_KEY"
S3_BUCKET="$S3_BUCKET"
S3_REGION="$S3_REGION"
S3_PREFIX="$S3_PREFIX"
S3_RETAIN_DAYS="$S3_RETAIN_DAYS"
RETAIN_BACKUPS_DAYS="$RETAIN_BACKUPS_DAYS"
CRON_TIMES="$CRON_TIMES"
REMNALABS_ROOT_DIR="$REMNALABS_ROOT_DIR"
TG_MESSAGE_THREAD_ID="$TG_MESSAGE_THREAD_ID"
TG_PROXY="$TG_PROXY"
REMNAWAVE_ENABLED="$REMNAWAVE_ENABLED"
SHM_ENABLED="$SHM_ENABLED"
SHM_ROOT_DIR="$SHM_ROOT_DIR"
DB_CONNECTION_TYPE="$DB_CONNECTION_TYPE"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_NAME="$DB_NAME"
DB_PASSWORD="$DB_PASSWORD"
DB_SSL_MODE="$DB_SSL_MODE"
DB_POSTGRES_VERSION="$DB_POSTGRES_VERSION"
LANG_CODE="$LANG_CODE"
AUTO_UPDATE="$AUTO_UPDATE"
EOF
    chmod 600 "$CONFIG_FILE" || { print_message "ERROR" "$(t chmod_error) ${BOLD}${CONFIG_FILE}${RESET}. $(t check_permissions)"; exit 1; }
    print_message "SUCCESS" "$(t config_saved)"
}

load_or_create_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_message "INFO" "$(t cfg_loading)"
        source "$CONFIG_FILE"
        echo ""

        UPLOAD_METHOD=${UPLOAD_METHOD:-telegram}
        DB_USER=${DB_USER:-postgres}
        CRON_TIMES=${CRON_TIMES:-}
        REMNALABS_ROOT_DIR=${REMNALABS_ROOT_DIR:-}
        TG_MESSAGE_THREAD_ID=${TG_MESSAGE_THREAD_ID:-}
        TG_PROXY=${TG_PROXY:-}
        REMNAWAVE_ENABLED=${REMNAWAVE_ENABLED:-false}
        SHM_ENABLED=${SHM_ENABLED:-false}
        SHM_ROOT_DIR=${SHM_ROOT_DIR:-}
        DB_CONNECTION_TYPE=${DB_CONNECTION_TYPE:-docker}
        DB_HOST=${DB_HOST:-}
        DB_PORT=${DB_PORT:-5432}
        DB_NAME=${DB_NAME:-postgres}
        DB_PASSWORD=${DB_PASSWORD:-}
        DB_SSL_MODE=${DB_SSL_MODE:-prefer}
        DB_POSTGRES_VERSION=${DB_POSTGRES_VERSION:-17}
        S3_ENDPOINT=${S3_ENDPOINT:-}
        S3_ACCESS_KEY=${S3_ACCESS_KEY:-}
        S3_SECRET_KEY=${S3_SECRET_KEY:-}
        S3_BUCKET=${S3_BUCKET:-}
        S3_REGION=${S3_REGION:-}
        S3_PREFIX=${S3_PREFIX:-}
        S3_RETAIN_DAYS=${S3_RETAIN_DAYS:-30}
        RETAIN_BACKUPS_DAYS=${RETAIN_BACKUPS_DAYS:-7}
        LANG_CODE=${LANG_CODE:-}
        AUTO_UPDATE=${AUTO_UPDATE:-false}
        
        if [[ -z "$LANG_CODE" || ! -f "$TRANSLATIONS_DIR/$LANG_CODE.sh" ]]; then
            download_translations
            select_language_interactive
            save_config
        else
            load_language "$LANG_CODE"
        fi
        
        local config_updated=false

        if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
            print_message "WARN" "$(t cfg_tg_not_configured)"
        fi

        if [[ "$REMNAWAVE_ENABLED" == "true" && -z "$DB_USER" ]]; then
            print_message "INFO" "$(t cfg_enter_db_user)"
            read -rp "    $(t input_prompt)" input_db_user
            DB_USER=${input_db_user:-postgres}
            config_updated=true
            echo ""
        fi
        
        if [[ "$REMNAWAVE_ENABLED" == "true" && -z "$REMNALABS_ROOT_DIR" ]]; then
            print_message "ACTION" "$(t cfg_where_panel)"
            echo " 1. /opt/remnawave"
            echo " 2. /root/remnawave"
            echo " 3. /opt/stacks/remnawave"
            echo " 4. $(t custom_path)"
            echo ""

            local remnawave_path_choice
            while true; do
                read -rp " ${GREEN}[?]${RESET} $(t select_variant)" remnawave_path_choice
                case "$remnawave_path_choice" in
                1) REMNALABS_ROOT_DIR="/opt/remnawave"; break ;;
                2) REMNALABS_ROOT_DIR="/root/remnawave"; break ;;
                3) REMNALABS_ROOT_DIR="/opt/stacks/remnawave"; break ;;
                4) 
                    echo ""
                    print_message "INFO" "$(t cfg_enter_panel_path)"
                    read -rp " $(t path_prompt)" custom_remnawave_path
    
                    if [[ -z "$custom_remnawave_path" ]]; then
                        print_message "ERROR" "$(t cfg_path_empty)"
                        echo ""
                        read -rp "$(t press_enter)"
                        continue
                    fi
    
                    if [[ ! "$custom_remnawave_path" = /* ]]; then
                        print_message "ERROR" "$(t cfg_path_abs)"
                        echo ""
                        read -rp "$(t press_enter)"
                        continue
                    fi
    
                    custom_remnawave_path="${custom_remnawave_path%/}"
    
                    if [[ ! -d "$custom_remnawave_path" ]]; then
                        print_message "WARN" "$(t cfg_dir_missing) ${BOLD}${custom_remnawave_path}${RESET}"
                        read -rp "$(echo -e "${GREEN}[?]${RESET} $(t cfg_continue_path) ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" confirm_custom_path
                        if [[ "$confirm_custom_path" != "y" ]]; then
                            echo ""
                            read -rp "$(t press_enter)"
                            continue
                        fi
                    fi
    
                    REMNALABS_ROOT_DIR="$custom_remnawave_path"
                    print_message "SUCCESS" "$(t cfg_custom_set) ${BOLD}${REMNALABS_ROOT_DIR}${RESET}"
                    break 
                    ;;
                *) print_message "ERROR" "$(t invalid_input)" ;;
                esac
            done
            config_updated=true
            echo ""
        fi

        if [[ "$SHM_ENABLED" == "true" && -z "$SHM_ROOT_DIR" ]]; then
            print_message "ACTION" "$(t cfg_where_shm)"
            echo " 1. /opt/shm"
            echo " 2. /root/shm"
            echo " 3. /opt/stacks/shm"
            echo " 4. $(t custom_path)"
            echo ""

            local shm_path_choice
            while true; do
                read -rp " ${GREEN}[?]${RESET} $(t select_variant)" shm_path_choice
                case "$shm_path_choice" in
                1) SHM_ROOT_DIR="/opt/shm"; break ;;
                2) SHM_ROOT_DIR="/root/shm"; break ;;
                3) SHM_ROOT_DIR="/opt/stacks/shm"; break ;;
                4)
                    echo ""
                    print_message "INFO" "$(t cfg_enter_shm_path)"
                    read -rp " $(t path_prompt)" custom_shm_path

                    if [[ -z "$custom_shm_path" ]]; then
                        print_message "ERROR" "$(t cfg_path_empty)"
                        echo ""
                        read -rp "$(t press_enter)"
                        continue
                    fi

                    if [[ ! "$custom_shm_path" = /* ]]; then
                        print_message "ERROR" "$(t cfg_path_abs)"
                        echo ""
                        read -rp "$(t press_enter)"
                        continue
                    fi

                    SHM_ROOT_DIR="${custom_shm_path%/}"
                    print_message "SUCCESS" "$(t cfg_custom_set) ${BOLD}${SHM_ROOT_DIR}${RESET}"
                    break
                    ;;
                *) print_message "ERROR" "$(t invalid_input)" ;;
                esac
            done
            config_updated=true
            echo ""
        fi

        if [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            if [[ -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ]]; then
                print_message "WARN" "$(t cfg_gd_incomplete)"
                print_message "WARN" "$(t cfg_gd_switch_tg)"
                UPLOAD_METHOD="telegram"
                config_updated=true
            fi
        fi

        if [[ "$UPLOAD_METHOD" == "s3" ]]; then
            if [[ -z "$S3_BUCKET" || -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
                print_message "WARN" "$(t cfg_s3_incomplete)"
                print_message "WARN" "$(t cfg_s3_switch_tg)"
                UPLOAD_METHOD="telegram"
                config_updated=true
            fi
        fi

        if [[ "$UPLOAD_METHOD" == "google_drive" && ( -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ) ]]; then
            print_message "WARN" "$(t cfg_gd_missing)"
            print_message "ACTION" "$(t cfg_gd_enter)"
            echo ""
            echo "$(t cfg_gd_no_tokens)"
            local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
            print_message "LINK" "$(t cfg_gd_guide) ${CYAN}${guide_url}${RESET}"
            echo ""
            [[ -z "$GD_CLIENT_ID" ]] && read -rp "    $(t cfg_enter_gd_id)" GD_CLIENT_ID
            [[ -z "$GD_CLIENT_SECRET" ]] && read -rp "    $(t cfg_enter_gd_secret)" GD_CLIENT_SECRET
            clear
            
            if [[ -z "$GD_REFRESH_TOKEN" ]]; then
                print_message "WARN" "$(t cfg_gd_auth_needed)"
                print_message "INFO" "$(t cfg_gd_open_url)"
                echo ""
                local auth_url="https://accounts.google.com/o/oauth2/auth?client_id=${GD_CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=https://www.googleapis.com/auth/drive&response_type=code&access_type=offline"
                print_message "INFO" "${CYAN}${auth_url}${RESET}"
                echo ""
                read -rp "    $(t cfg_gd_enter_code)" AUTH_CODE
                
                print_message "INFO" "$(t cfg_gd_getting)"
                local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
                    -d client_id="$GD_CLIENT_ID" \
                    -d client_secret="$GD_CLIENT_SECRET" \
                    -d code="$AUTH_CODE" \
                    -d redirect_uri="urn:ietf:wg:oauth:2.0:oob" \
                    -d grant_type="authorization_code")
                
                GD_REFRESH_TOKEN=$(echo "$token_response" | jq -r .refresh_token 2>/dev/null)
                
                if [[ -z "$GD_REFRESH_TOKEN" || "$GD_REFRESH_TOKEN" == "null" ]]; then
                    print_message "ERROR" "$(t cfg_gd_fail)"
                    print_message "WARN" "$(t cfg_gd_incomplete2)"
                    UPLOAD_METHOD="telegram"
                    config_updated=true
                fi
            fi
            echo ""
            echo "    $(t cfg_gd_folder1)"
            echo "    $(t cfg_gd_folder2)"
            echo "    $(t cfg_gd_folder3)"
            echo "      https://drive.google.com/drive/folders/1a2B3cD4eFmNOPqRstuVwxYz"
            echo "    $(t cfg_gd_folder4)"
            echo "    $(t cfg_gd_folder5)"
            echo ""
            read -rp "    $(t cfg_enter_gd_folder)" GD_FOLDER_ID
            config_updated=true
        fi

        if $config_updated; then
            save_config
        else
            print_message "SUCCESS" "$(t cfg_loaded) ${BOLD}${CONFIG_FILE}${RESET}."
        fi

    else
        if [[ "$SCRIPT_RUN_PATH" != "$SCRIPT_PATH" ]]; then
            print_message "INFO" "Configuration not found. Script launched from temporary location."
            print_message "INFO" "Moving script to main install directory: ${BOLD}${SCRIPT_PATH}${RESET}..."
            mkdir -p "$INSTALL_DIR" || { print_message "ERROR" "$(t cfg_install_fail) ${BOLD}${INSTALL_DIR}${RESET}."; exit 1; }
            mkdir -p "$BACKUP_DIR" || { print_message "ERROR" "$(t cfg_backup_fail) ${BOLD}${BACKUP_DIR}${RESET}."; exit 1; }

            if mv "$SCRIPT_RUN_PATH" "$SCRIPT_PATH"; then
                chmod +x "$SCRIPT_PATH"
                clear
                print_message "SUCCESS" "Script successfully moved to ${BOLD}${SCRIPT_PATH}${RESET}."
                print_message "ACTION" "Restarting script from new location to complete setup."
                exec "$SCRIPT_PATH" "$@"
                exit 0
            else
                print_message "ERROR" "$(t cfg_move_fail) ${BOLD}${SCRIPT_PATH}${RESET}."
                exit 1
            fi
        else
            print_message "INFO" "Configuration not found, creating new..."
            echo ""

            download_translations
            select_language_interactive
            echo ""

            while true; do
                local _setup_remnawave _setup_shm

                print_message "ACTION" "$(t cfg_enable_remnawave)"
                echo " 1. $(t yes_option)"
                echo " 2. $(t no_option)"
                echo ""
                read -rp " ${GREEN}[?]${RESET} $(t your_choice)" _setup_remnawave
                echo ""

                if [[ "$_setup_remnawave" == "1" ]]; then
                    REMNAWAVE_ENABLED="true"

                    print_message "INFO" "$(t cfg_enter_db_user_default)"
                    read -rp "    $(t input_prompt)" input_db_user
                    DB_USER=${input_db_user:-postgres}
                    echo ""

                    print_message "ACTION" "$(t cfg_where_panel)"
                    echo " 1. /opt/remnawave"
                    echo " 2. /root/remnawave"
                    echo " 3. /opt/stacks/remnawave"
                    echo " 4. $(t custom_path)"
                    echo ""

                    local remnawave_path_choice
                    while true; do
                        read -rp " ${GREEN}[?]${RESET} $(t select_variant)" remnawave_path_choice
                        case "$remnawave_path_choice" in
                        1) REMNALABS_ROOT_DIR="/opt/remnawave"; break ;;
                        2) REMNALABS_ROOT_DIR="/root/remnawave"; break ;;
                        3) REMNALABS_ROOT_DIR="/opt/stacks/remnawave"; break ;;
                        4)
                            echo ""
                            print_message "INFO" "$(t cfg_enter_panel_path)"
                            read -rp " $(t path_prompt)" custom_remnawave_path
                            if [[ -n "$custom_remnawave_path" ]]; then
                                REMNALABS_ROOT_DIR="${custom_remnawave_path%/}"
                                break
                            fi
                            ;;
                        *) print_message "ERROR" "$(t invalid_input)" ;;
                        esac
                    done
                    echo ""
                else
                    REMNAWAVE_ENABLED="false"
                fi

                print_message "ACTION" "$(t cfg_enable_shm)"
                echo " 1. $(t yes_option)"
                echo " 2. $(t no_option)"
                echo ""
                read -rp " ${GREEN}[?]${RESET} $(t your_choice)" _setup_shm
                echo ""

                if [[ "$_setup_shm" == "1" ]]; then
                    SHM_ENABLED="true"
                    print_message "INFO" "$(t cfg_shm_backup_info)"
                    echo ""

                    print_message "ACTION" "$(t cfg_where_shm)"
                    echo " 1. /opt/shm"
                    echo " 2. /root/shm"
                    echo " 3. /opt/stacks/shm"
                    echo " 4. $(t custom_path)"
                    echo ""

                    local shm_path_choice
                    while true; do
                        read -rp " ${GREEN}[?]${RESET} $(t select_variant)" shm_path_choice
                        case "$shm_path_choice" in
                        1) SHM_ROOT_DIR="/opt/shm"; break ;;
                        2) SHM_ROOT_DIR="/root/shm"; break ;;
                        3) SHM_ROOT_DIR="/opt/stacks/shm"; break ;;
                        4)
                            echo ""
                            print_message "INFO" "$(t cfg_enter_shm_path)"
                            read -rp " $(t path_prompt)" custom_shm_path
                            if [[ -n "$custom_shm_path" ]]; then
                                SHM_ROOT_DIR="${custom_shm_path%/}"
                                break
                            fi
                            ;;
                        *) print_message "ERROR" "$(t invalid_input)" ;;
                        esac
                    done
                    echo ""
                else
                    SHM_ENABLED="false"
                fi

                if [[ "$REMNAWAVE_ENABLED" != "true" && "$SHM_ENABLED" != "true" ]]; then
                    print_message "WARN" "$(t cfg_nothing_selected)"
                    echo ""
                    echo " 1. $(t cfg_restart_setup)"
                    echo " 0. $(t exit)"
                    echo ""
                    read -rp " ${GREEN}[?]${RESET} $(t your_choice)" _nothing_choice
                    if [[ "$_nothing_choice" == "0" ]]; then
                        exit 0
                    fi
                    continue
                fi

                break
            done

            print_message "INFO" "$(t cfg_tg_setup)"
            print_message "INFO" "$(t cfg_create_bot)"
            print_message "INFO" "$(t cfg_tg_skip_hint)"
            print_message "WARN" "$(t cfg_tg_skip_warn)"
            read -rp "    $(t cfg_enter_token)" BOT_TOKEN
            echo ""
            print_message "INFO" "$(t cfg_chatid_desc)"
            echo -e "       $(t cfg_chatid_help)"
            read -rp "    $(t cfg_enter_chatid)" CHAT_ID
            echo ""
            print_message "INFO" "$(t cfg_thread_info)"
            echo -e "       $(t cfg_thread_empty)"
            read -rp "    $(t cfg_enter_thread)" TG_MESSAGE_THREAD_ID
            echo ""

            mkdir -p "$INSTALL_DIR"
            mkdir -p "$BACKUP_DIR"
            save_config
            print_message "SUCCESS" "$(t cfg_new_saved) ${BOLD}${CONFIG_FILE}${RESET}"
        fi
    fi

    echo ""
}

escape_markdown_v2() {
    local text="$1"
    echo "$text" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/_/\\_/g' \
        -e 's/\[/\\[/g' \
        -e 's/\]/\\]/g' \
        -e 's/(/\\(/g' \
        -e 's/)/\\)/g' \
        -e 's/~/\~/g' \
        -e 's/`/\\`/g' \
        -e 's/>/\\>/g' \
        -e 's/#/\\#/g' \
        -e 's/+/\\+/g' \
        -e 's/-/\\-/g' \
        -e 's/=/\\=/g' \
        -e 's/|/\\|/g' \
        -e 's/{/\\{/g' \
        -e 's/}/\\}/g' \
        -e 's/\./\\./g' \
        -e 's/!/\!/g'
}

get_remnawave_version() {
    local version_output
    version_output=$(docker exec remnawave sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json 2>/dev/null)
    if [[ -z "$version_output" ]]; then
        echo "$(t ver_undefined)"
    else
        echo "$version_output"
    fi
}

get_postgres_image() {
    echo "postgres:${DB_POSTGRES_VERSION}-alpine"
}

LAST_DB_ERROR=""

create_panel_db_dump() {
    local dump_file="$1"
    local pg_image=$(get_postgres_image)
    LAST_DB_ERROR=""
    
    case "$DB_CONNECTION_TYPE" in
        docker)
            if ! docker inspect remnawave-db > /dev/null 2>&1 || ! docker container inspect -f '{{.State.Running}}' remnawave-db 2>/dev/null | grep -q "true"; then
                LAST_DB_ERROR="$(t db_container_missing)"
                print_message "ERROR" "$LAST_DB_ERROR"
                return 1
            fi
            
            local docker_error_log=$(mktemp)
            if ! docker exec "remnawave-db" pg_dumpall -c -U "$DB_USER" 2>"$docker_error_log" | gzip -9 > "$dump_file"; then
                LAST_DB_ERROR=$(cat "$docker_error_log" 2>/dev/null | head -5 | tr '\n' ' ')
                rm -f "$docker_error_log"
                return 1
            fi
            rm -f "$docker_error_log"
            ;;
        external)
            if [[ -z "$DB_HOST" ]]; then
                LAST_DB_ERROR="$(t db_host_missing)"
                print_message "ERROR" "$LAST_DB_ERROR"
                return 1
            fi
            
            print_message "INFO" "$(t db_connecting) ${BOLD}${DB_HOST}:${DB_PORT}/${DB_NAME}${RESET}"
            
            local pg_dump_error_log=$(mktemp)
            
            docker run --rm --network host \
                -e PGPASSWORD="$DB_PASSWORD" \
                -e PGSSLMODE="$DB_SSL_MODE" \
                "$pg_image" \
                pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
                --clean --if-exists 2>"$pg_dump_error_log" | gzip -9 > "$dump_file"
            
            local pg_dump_exit_code=${PIPESTATUS[0]}
            
            if [[ $pg_dump_exit_code -ne 0 ]]; then
                print_message "ERROR" "$(t db_dump_err)"
                if [[ -s "$pg_dump_error_log" ]]; then
                    LAST_DB_ERROR=$(cat "$pg_dump_error_log" | head -5 | tr '\n' ' ')
                    print_message "ERROR" "$(t db_err_details)"
                    cat "$pg_dump_error_log"
                fi
                rm -f "$pg_dump_error_log"
                return 1
            fi
            rm -f "$pg_dump_error_log"
            
            local dump_size=$(stat -c%s "$dump_file" 2>/dev/null || stat -f%z "$dump_file" 2>/dev/null || echo "0")
            if [[ "$dump_size" -lt 100 ]]; then
                LAST_DB_ERROR="$(printf "$(t db_dump_small)" "$dump_size")"
                print_message "ERROR" "$LAST_DB_ERROR"
                return 1
            fi
            ;;
        *)
            LAST_DB_ERROR="$(t db_unknown_type) ${DB_CONNECTION_TYPE}"
            print_message "ERROR" "$LAST_DB_ERROR"
            return 1
            ;;
    esac
    
    return 0
}

restore_panel_db_dump() {
    local sql_file="$1"
    local restore_db_name="$2"
    local restore_log="$3"
    local pg_image=$(get_postgres_image)
    
    case "$DB_CONNECTION_TYPE" in
        docker)
            if ! docker exec -i remnawave-db psql -q -U "$DB_USER" -d "$restore_db_name" > /dev/null 2> "$restore_log" < "$sql_file"; then
                return 1
            fi
            ;;
        external)
            print_message "INFO" "$(t db_restoring_ext) ${BOLD}${DB_HOST}:${DB_PORT}/${DB_NAME}${RESET}"
            
            if ! docker run --rm -i --network host \
                -e PGPASSWORD="$DB_PASSWORD" \
                -e PGSSLMODE="$DB_SSL_MODE" \
                "$pg_image" \
                psql -q -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$restore_db_name" \
                2> "$restore_log" < "$sql_file"; then
                return 1
            fi
            ;;
        *)
            print_message "ERROR" "$(t db_unknown_type) ${BOLD}${DB_CONNECTION_TYPE}${RESET}"
            return 1
            ;;
    esac
    
    return 0
}

send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-MarkdownV2}"

    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        return 1
    fi

    local url="https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
    local send_text="$message"

    if [[ "$parse_mode" == "MarkdownV2" ]]; then
        send_text=$(escape_markdown_v2 "$message")
    fi

    local data_params=(
        -d chat_id="$CHAT_ID"
        -d text="$send_text"
    )

    if [[ -n "$parse_mode" && "$parse_mode" != "None" ]]; then
        data_params+=(-d parse_mode="$parse_mode")
    fi

    [[ -n "$TG_MESSAGE_THREAD_ID" ]] && data_params+=(-d message_thread_id="$TG_MESSAGE_THREAD_ID")

    local response
    response=$(curl -s -X POST ${TG_PROXY:+--proxy "$TG_PROXY"} "$url" "${data_params[@]}" -w "\n%{http_code}")
    local body=$(echo "$response" | head -n -1)
    local http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -eq 200 ]]; then
        return 0
    else
        response=$(curl -s -X POST ${TG_PROXY:+--proxy "$TG_PROXY"} "$url" -d chat_id="$CHAT_ID" -d text="$message" -w "\n%{http_code}")
        http_code=$(echo "$response" | tail -n1)
        if [[ "$http_code" -eq 200 ]]; then
            return 0
        fi
        echo -e "${RED}❌ $(t tg_send_err) ${BOLD}$http_code${RESET}"
        echo -e "$(t tg_response) ${body}"
        return 1
    fi
}

send_telegram_document() {
    local file_path="$1"
    local caption="$2"
    local parse_mode="MarkdownV2"
    local escaped_caption
    escaped_caption=$(escape_markdown_v2 "$caption")

    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        return 1
    fi

    local form_params=(
        -F chat_id="$CHAT_ID"
        -F document=@"$file_path"
        -F parse_mode="$parse_mode"
        -F caption="$escaped_caption"
    )

    if [[ -n "$TG_MESSAGE_THREAD_ID" ]]; then
        form_params+=(-F message_thread_id="$TG_MESSAGE_THREAD_ID")
    fi

    local api_response
    api_response=$(curl -s -X POST ${TG_PROXY:+--proxy "$TG_PROXY"} "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        "${form_params[@]}" \
        -w "%{http_code}" -o /dev/null 2>&1)

    local curl_status=$?

    if [ $curl_status -ne 0 ]; then
        echo -e "${RED}❌ $(t tg_curl_err) ${BOLD}$curl_status${RESET}. $(t tg_check_net)${RESET}"
        return 1
    fi

    local http_code="${api_response: -3}"

    if [[ "$http_code" == "200" ]]; then
        return 0
    else
        echo -e "${RED}❌ $(t tg_api_err) ${BOLD}$http_code${RESET}. $(t tg_resp_label) ${BOLD}$api_response${RESET}. $(t tg_maybe_big)${RESET}"
        return 1
    fi
}

get_google_access_token() {
    if [[ -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ]]; then
        print_message "ERROR" "$(t gd_not_set)"
        return 1
    fi

    local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
        -d client_id="$GD_CLIENT_ID" \
        -d client_secret="$GD_CLIENT_SECRET" \
        -d refresh_token="$GD_REFRESH_TOKEN" \
        -d grant_type="refresh_token")
    
    local access_token=$(echo "$token_response" | jq -r .access_token 2>/dev/null)
    local expires_in=$(echo "$token_response" | jq -r .expires_in 2>/dev/null)

    if [[ -z "$access_token" || "$access_token" == "null" ]]; then
        local error_msg=$(echo "$token_response" | jq -r .error_description 2>/dev/null)
        print_message "ERROR" "$(t gd_token_err) ${error_msg:-Unknown error}."
        return 1
    fi
    echo "$access_token"
    return 0
}

send_google_drive_document() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    local access_token=$(get_google_access_token)

    if [[ -z "$access_token" ]]; then
        print_message "ERROR" "$(t gd_upload_err)"
        return 1
    fi

    local mime_type="application/gzip"
    local upload_url="https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"

    local metadata_file=$(mktemp)
    
    local metadata="{\"name\": \"$file_name\", \"mimeType\": \"$mime_type\""
    if [[ -n "$GD_FOLDER_ID" ]]; then
        metadata="${metadata}, \"parents\": [\"$GD_FOLDER_ID\"]"
    fi
    metadata="${metadata}}"
    
    echo "$metadata" > "$metadata_file"

    local response=$(curl -s -X POST "$upload_url" \
        -H "Authorization: Bearer $access_token" \
        -F "metadata=@$metadata_file;type=application/json" \
        -F "file=@$file_path;type=$mime_type")

    rm -f "$metadata_file"

    local file_id=$(echo "$response" | jq -r .id 2>/dev/null)
    local error_message=$(echo "$response" | jq -r .error.message 2>/dev/null)
    local error_code=$(echo "$response" | jq -r .error.code 2>/dev/null)

    if [[ -n "$file_id" && "$file_id" != "null" ]]; then
        return 0
    else
        print_message "ERROR" "$(t gd_upload_err) Code: ${error_code:-Unknown}. ${error_message:-Unknown error}."
        return 1
    fi
}

install_aws_cli() {
    if command -v aws &> /dev/null; then
        return 0
    fi
    print_message "INFO" "$(t s3_installing_cli)"
    if [[ $EUID -ne 0 ]]; then
        print_message "ERROR" "$(t s3_cli_root)"
        return 1
    fi

    local installed=false

    if command -v apt-get &> /dev/null; then
        apt-get update -qq > /dev/null 2>&1
        if apt-get install -y awscli > /dev/null 2>&1; then
            installed=true
        fi
    elif command -v yum &> /dev/null; then
        if yum install -y awscli > /dev/null 2>&1; then
            installed=true
        fi
    elif command -v dnf &> /dev/null; then
        if dnf install -y awscli > /dev/null 2>&1; then
            installed=true
        fi
    fi

    if ! $installed && ! command -v aws &> /dev/null; then
        print_message "INFO" "$(t s3_cli_fallback)"
        local tmp_dir=$(mktemp -d)
        if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp_dir/awscliv2.zip" 2>/dev/null; then
            if command -v unzip &> /dev/null || apt-get install -y unzip > /dev/null 2>&1 || yum install -y unzip > /dev/null 2>&1; then
                unzip -q "$tmp_dir/awscliv2.zip" -d "$tmp_dir" > /dev/null 2>&1
                if "$tmp_dir/aws/install" > /dev/null 2>&1; then
                    installed=true
                fi
            fi
        fi
        rm -rf "$tmp_dir"
    fi

    if command -v aws &> /dev/null; then
        print_message "SUCCESS" "$(t s3_cli_installed)"
        return 0
    else
        print_message "ERROR" "$(t s3_cli_fail)"
        return 1
    fi
}

send_s3_document() {
    local file_path="$1"
    local file_name=$(basename "$file_path")

    if ! command -v aws &> /dev/null; then
        print_message "ERROR" "$(t s3_aws_not_found)"
        return 1
    fi

    local s3_endpoint_arg=""
    if [[ -n "$S3_ENDPOINT" ]]; then
        s3_endpoint_arg="--endpoint-url $S3_ENDPOINT"
    fi

    local s3_key="${S3_PREFIX:+${S3_PREFIX}/}${file_name}"

    if ! AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
         AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
         AWS_DEFAULT_REGION="$S3_REGION" \
         aws s3 cp "$file_path" "s3://${S3_BUCKET}/${s3_key}" \
         $s3_endpoint_arg --quiet 2>&1; then
        print_message "ERROR" "$(t s3_upload_err)"
        return 1
    fi

    print_message "SUCCESS" "$(t s3_upload_ok)"
    return 0
}

cleanup_s3_old_backups() {
    if [[ -z "$S3_BUCKET" || -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
        return 0
    fi

    local s3_endpoint_arg=""
    if [[ -n "$S3_ENDPOINT" ]]; then
        s3_endpoint_arg="--endpoint-url $S3_ENDPOINT"
    fi

    local s3_prefix_arg="${S3_PREFIX:+${S3_PREFIX}/}"
    local cutoff_date=$(date -d "-${S3_RETAIN_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-${S3_RETAIN_DAYS}d +%Y-%m-%d 2>/dev/null)

    if [[ -z "$cutoff_date" ]]; then
        return 0
    fi

    local file_list
    file_list=$(AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
                AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
                AWS_DEFAULT_REGION="$S3_REGION" \
                aws s3 ls "s3://${S3_BUCKET}/${s3_prefix_arg}" \
                $s3_endpoint_arg 2>/dev/null | grep -E "remnawave_backup_.*\.tar\.gz|shm_backup_.*\.tar\.gz")

    if [[ -z "$file_list" ]]; then
        return 0
    fi

    local deleted_count=0
    while IFS= read -r line; do
        local file_date=$(echo "$line" | awk '{print $1}')
        local file_name=$(echo "$line" | awk '{print $NF}')
        if [[ "$file_date" < "$cutoff_date" ]]; then
            if AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
               AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
               AWS_DEFAULT_REGION="$S3_REGION" \
               aws s3 rm "s3://${S3_BUCKET}/${s3_prefix_arg}${file_name}" \
               $s3_endpoint_arg --quiet 2>/dev/null; then
                ((deleted_count++))
            fi
        fi
    done <<< "$file_list"

    if [[ $deleted_count -gt 0 ]]; then
        print_message "INFO" "$(printf "$(t s3_cleaned)" "$deleted_count")"
    fi
}

send_backup_file() {
    local final_file="$1"
    local backup_info="$2"
    local db_mode_info="$3"

    local DATE
    DATE=$(date +'%Y-%m-%d %H:%M:%S')
    local backup_size
    backup_size=$(du -h "$final_file" | awk '{print $1}')

    print_message "INFO" "$(t bk_sending) (${UPLOAD_METHOD})..."

    local caption_text="💾 #backup_success"$'\n'"➖➖➖➖➖➖➖➖➖"$'\n'"✅ *$(t tg_bk_success)*${backup_info}${db_mode_info}"$'\n'"📁 *$(t tg_db_dir)*"$'\n'"📏 *$(t tg_size)* ${backup_size}"$'\n'"📅 *$(t tg_date)* ${DATE}"

    if [[ -f "$final_file" ]]; then
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            local file_size_bytes
            file_size_bytes=$(stat -c%s "$final_file" 2>/dev/null || stat -f%z "$final_file" 2>/dev/null || echo "0")
            local max_tg_size=$((50 * 1024 * 1024))
            if [[ "$file_size_bytes" -gt "$max_tg_size" ]]; then
                print_message "ERROR" "$(printf "$(t bk_tg_big)" "$backup_size")"
                print_message "INFO" "$(t bk_saved_local) ${BOLD}${final_file}${RESET}"
                send_telegram_message "⚠️ $(printf "$(t bk_tg_big_notify)" "$backup_size")" "None" 2>/dev/null
            elif send_telegram_document "$final_file" "$caption_text"; then
                print_message "SUCCESS" "$(t bk_tg_ok)"
            else
                echo -e "${RED}❌ $(t bk_tg_err)${RESET}"
            fi
        elif [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            if send_google_drive_document "$final_file"; then
                print_message "SUCCESS" "$(t bk_gd_ok)"
                local tg_success_message="💾 #backup_success"$'\n'"➖➖➖➖➖➖➖➖➖"$'\n'"✅ *$(t tg_bk_gd)*${backup_info}${db_mode_info}"$'\n'"📁 *$(t tg_db_dir)*"$'\n'"📏 *$(t tg_size)* ${backup_size}"$'\n'"📅 *$(t tg_date)* ${DATE}"
                if send_telegram_message "$tg_success_message"; then
                    print_message "SUCCESS" "$(t bk_gd_notify_ok)"
                else
                    print_message "ERROR" "$(t bk_gd_notify_fail)"
                fi
            else
                echo -e "${RED}❌ $(t bk_gd_err)${RESET}"
                send_telegram_message "❌ $(t bk_gd_err_tg)" "None"
            fi
        elif [[ "$UPLOAD_METHOD" == "s3" ]]; then
            if send_s3_document "$final_file"; then
                print_message "SUCCESS" "$(t bk_s3_ok)"
                local tg_success_message="💾 #backup_success"$'\n'"➖➖➖➖➖➖➖➖➖"$'\n'"✅ *$(t tg_bk_s3)*${backup_info}${db_mode_info}"$'\n'"📁 *$(t tg_db_dir)*"$'\n'"📏 *$(t tg_size)* ${backup_size}"$'\n'"📅 *$(t tg_date)* ${DATE}"
                if send_telegram_message "$tg_success_message"; then
                    print_message "SUCCESS" "$(t bk_s3_notify_ok)"
                else
                    print_message "ERROR" "$(t bk_s3_notify_fail)"
                fi
            else
                echo -e "${RED}❌ $(t bk_s3_err)${RESET}"
                send_telegram_message "❌ $(t bk_s3_err_tg)" "None"
            fi
        else
            print_message "WARN" "$(t bk_unknown_method) ${BOLD}${UPLOAD_METHOD}${RESET}. $(t bk_not_sent)"
            send_telegram_message "❌ $(t bk_unknown_method) ${BOLD}${UPLOAD_METHOD}${RESET}" "None"
        fi
    else
        echo -e "${RED}❌ $(t bk_file_missing) ${BOLD}${final_file}${RESET}. $(t bk_impossible)${RESET}"
        local error_msg="❌ $(t bk_file_missing) ${BOLD}$(basename "$final_file")${RESET}"
        if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
            send_telegram_message "$error_msg" "None"
        elif [[ "$UPLOAD_METHOD" == "google_drive" ]]; then
            print_message "ERROR" "$(t bk_gd_impossible)"
        elif [[ "$UPLOAD_METHOD" == "s3" ]]; then
            print_message "ERROR" "$(t bk_s3_impossible)"
        fi
        exit 1
    fi
}

create_backup() {
    print_message "INFO" "$(t bk_starting)"
    echo ""
    
    if [[ "$REMNAWAVE_ENABLED" == "true" ]]; then
        if [[ "$DB_CONNECTION_TYPE" == "external" ]]; then
            print_message "INFO" "$(t bk_mode_ext) (${DB_HOST}:${DB_PORT}/${DB_NAME})"
        else
            print_message "INFO" "$(t bk_mode_docker)"
        fi
        echo ""
    fi
    
    REMNAWAVE_VERSION=$(get_remnawave_version)
    TIMESTAMP=$(date +%Y-%m-%d"_"%H_%M_%S)
    BACKUP_FILE_DB="dump_${TIMESTAMP}.sql.gz"
    BACKUP_FILE_FINAL="remnawave_backup_${TIMESTAMP}.tar.gz"
    
    mkdir -p "$BACKUP_DIR" || { 
        echo -e "${RED}❌ $(t bk_mkdir_err) ${BOLD}$BACKUP_DIR${RESET}.${RESET}"
        send_telegram_message "❌ $(t bk_mkdir_err) ${BOLD}$BACKUP_DIR${RESET}." "None"
        exit 1
    }
    
    BACKUP_ITEMS=()

    local _do_rw="false"
    local _do_shm="false"

    if [[ "$REMNAWAVE_ENABLED" == "true" && "$SHM_ENABLED" == "true" ]]; then
        echo ""
        print_message "ACTION" "$(t bk_select_source)"
        echo " 1. $(t src_remnawave)"
        echo " 2. $(t src_shm)"
        echo " 3. $(t bk_source_both)"
        echo ""
        local _src_choice
        while true; do
            read -rp " ${GREEN}[?]${RESET} $(t your_choice)" _src_choice
            case "$_src_choice" in
                1) _do_rw="true"; break ;;
                2) _do_shm="true"; break ;;
                3) _do_rw="true"; _do_shm="true"; break ;;
                *) print_message "ERROR" "$(t invalid_input)" ;;
            esac
        done
        echo ""
    elif [[ "$REMNAWAVE_ENABLED" == "true" ]]; then
        _do_rw="true"
    elif [[ "$SHM_ENABLED" == "true" ]]; then
        _do_shm="true"
    fi

    if [[ "$REMNAWAVE_ENABLED" == "true" && "$_do_rw" != "true" ]]; then
        print_message "INFO" "$(t bk_skip_panel)"
    fi

    if [[ "$_do_rw" == "true" ]]; then
        print_message "INFO" "$(t bk_creating_dump)"
        if ! create_panel_db_dump "$BACKUP_DIR/$BACKUP_FILE_DB"; then
            local STATUS=$?
            echo -e "${RED}❌ $(t bk_dump_err) ${BOLD}$STATUS${RESET}. $(t bk_check_db)${RESET}"
            local error_msg="❌ $(t bk_dump_err) ${STATUS}"
            if [[ -n "$LAST_DB_ERROR" ]]; then
                error_msg+="${LAST_DB_ERROR}"
            fi
            if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
                send_telegram_message "$error_msg" "None"
            fi
            exit $STATUS
        fi
        
        print_message "SUCCESS" "$(t bk_dump_ok)"
        echo ""
        
        print_message "INFO" "$(t bk_archiving)"
        REMNAWAVE_DIR_ARCHIVE="remnawave_dir_${TIMESTAMP}.tar.gz"
        
        if [ -d "$REMNALABS_ROOT_DIR" ]; then
            print_message "INFO" "$(t bk_arch_dir) ${BOLD}${REMNALABS_ROOT_DIR}${RESET}..."
            
            local exclude_args=""
            for pattern in $BACKUP_EXCLUDE_PATTERNS; do
                exclude_args+="--exclude=$pattern "
            done
            
            if eval "tar -czf '$BACKUP_DIR/$REMNAWAVE_DIR_ARCHIVE' $exclude_args -C '$(dirname "$REMNALABS_ROOT_DIR")' '$(basename "$REMNALABS_ROOT_DIR")'"; then
                print_message "SUCCESS" "$(t bk_arch_ok)"
                BACKUP_ITEMS=("$BACKUP_FILE_DB" "$REMNAWAVE_DIR_ARCHIVE")
            else
                STATUS=$?
                echo -e "${RED}❌ $(t bk_arch_err) ${BOLD}$STATUS${RESET}.${RESET}"
                local error_msg="❌ $(t bk_arch_err) ${BOLD}${STATUS}${RESET}"
                if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
                    send_telegram_message "$error_msg" "None"
                fi
                exit $STATUS
            fi
        else
            print_message "ERROR" "$(t bk_dir_missing) ${BOLD}${REMNALABS_ROOT_DIR}${RESET}"
            exit 1
        fi
    fi
    
    echo ""

    # ── Remnawave pass ──────────────────────────────────────────────────────────
    if [[ "$_do_rw" == "true" ]]; then
        if [[ ${#BACKUP_ITEMS[@]} -eq 0 ]]; then
            print_message "ERROR" "$(t bk_no_data)"
            exit 1
        fi

        local DUMP_TYPE
        if [[ "$DB_CONNECTION_TYPE" == "docker" ]]; then
            DUMP_TYPE="dumpall"
        else
            DUMP_TYPE="dump"
        fi

        cat > "$BACKUP_DIR/rw_meta.info" <<METAEOF
DUMP_TYPE="$DUMP_TYPE"
DB_CONNECTION_TYPE="$DB_CONNECTION_TYPE"
DB_NAME="$DB_NAME"
BACKUP_VERSION="$VERSION"
PANEL_VERSION="$REMNAWAVE_VERSION"
TIMESTAMP="$TIMESTAMP"
SOURCE="remnawave"
METAEOF
        BACKUP_ITEMS+=("rw_meta.info")

        if ! tar -czf "$BACKUP_DIR/$BACKUP_FILE_FINAL" -C "$BACKUP_DIR" "${BACKUP_ITEMS[@]}"; then
            local _rw_tar_status=$?
            echo -e "${RED}❌ $(t bk_final_err) ${BOLD}${_rw_tar_status}${RESET}.${RESET}"
            if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
                send_telegram_message "❌ $(t bk_final_err) ${BOLD}${_rw_tar_status}${RESET}" "None"
            fi
            exit $_rw_tar_status
        fi

        print_message "SUCCESS" "$(t bk_final_ok) ${BOLD}${BACKUP_DIR}/${BACKUP_FILE_FINAL}${RESET}"
        echo ""

        print_message "INFO" "$(t bk_cleaning)"
        for item in "${BACKUP_ITEMS[@]}"; do
            rm -f "$BACKUP_DIR/$item"
        done
        print_message "SUCCESS" "$(t bk_cleaned)"
        echo ""

        local _rw_backup_info=$'\n'"🌊 *Remnawave:* ${REMNAWAVE_VERSION}"
        if [[ "$DB_CONNECTION_TYPE" == "external" ]]; then
            _rw_backup_info+=$'\n'"🔗 *$(t tg_db_ext)* (${DB_HOST})"
        else
            _rw_backup_info+=$'\n'"🐳 *$(t tg_db_docker)*"
        fi

        send_backup_file "$BACKUP_DIR/$BACKUP_FILE_FINAL" "$_rw_backup_info" ""

        echo ""
        print_message "INFO" "$(printf "$(t bk_retention)" "$RETAIN_BACKUPS_DAYS")"
        find "$BACKUP_DIR" -maxdepth 1 -name "remnawave_backup_*.tar.gz" -mtime +$RETAIN_BACKUPS_DAYS -delete
        print_message "SUCCESS" "$(t bk_retention_ok)"
        echo ""
    fi

    # ── SHM pass ────────────────────────────────────────────────────────────────
    if [[ "$_do_shm" == "true" ]]; then
        BACKUP_ITEMS=()
        local SHM_BACKUP_FILE_FINAL="shm_backup_${TIMESTAMP}.tar.gz"

        if ! create_shm_backup; then
            print_message "ERROR" "$(t shm_backup_failed)"
            if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
                send_telegram_message "❌ $(t shm_backup_failed)" "None"
            fi
            exit 1
        fi

        if [[ ${#BACKUP_ITEMS[@]} -eq 0 ]]; then
            print_message "ERROR" "$(t bk_no_data)"
            exit 1
        fi

        cat > "$BACKUP_DIR/shm_meta.info" <<METAEOF
BACKUP_VERSION="$VERSION"
TIMESTAMP="$TIMESTAMP"
SOURCE="shm"
METAEOF
        BACKUP_ITEMS+=("shm_meta.info")

        if ! tar -czf "$BACKUP_DIR/$SHM_BACKUP_FILE_FINAL" -C "$BACKUP_DIR" "${BACKUP_ITEMS[@]}"; then
            local _shm_tar_status=$?
            echo -e "${RED}❌ $(t bk_final_err) ${BOLD}${_shm_tar_status}${RESET}.${RESET}"
            if [[ "$UPLOAD_METHOD" == "telegram" ]]; then
                send_telegram_message "❌ $(t bk_final_err) ${BOLD}${_shm_tar_status}${RESET}" "None"
            fi
            exit $_shm_tar_status
        fi

        print_message "SUCCESS" "$(t bk_final_ok) ${BOLD}${BACKUP_DIR}/${SHM_BACKUP_FILE_FINAL}${RESET}"
        echo ""

        print_message "INFO" "$(t bk_cleaning)"
        for item in "${BACKUP_ITEMS[@]}"; do
            rm -f "$BACKUP_DIR/$item"
        done
        print_message "SUCCESS" "$(t bk_cleaned)"
        echo ""

        local _shm_backup_info=$'\n'"🖥️ *SHM*"

        send_backup_file "$BACKUP_DIR/$SHM_BACKUP_FILE_FINAL" "$_shm_backup_info" ""

        echo ""
        print_message "INFO" "$(printf "$(t bk_retention)" "$RETAIN_BACKUPS_DAYS")"
        find "$BACKUP_DIR" -maxdepth 1 -name "shm_backup_*.tar.gz" -mtime +$RETAIN_BACKUPS_DAYS -delete
        print_message "SUCCESS" "$(t bk_retention_ok)"
        echo ""
    fi

    if [[ "$UPLOAD_METHOD" == "s3" ]]; then
        print_message "INFO" "$(printf "$(t bk_s3_retention)" "$S3_RETAIN_DAYS")"
        cleanup_s3_old_backups
        print_message "SUCCESS" "$(t bk_s3_retention_ok)"
    fi
    
    echo ""
    
    {
        check_update_status >/dev/null 2>&1
        
        if [[ "$UPDATE_AVAILABLE" == true ]]; then
            local CURRENT_VERSION="$VERSION"
            local REMOTE_VERSION_LATEST
            REMOTE_VERSION_LATEST=$(curl -fsSL "$SCRIPT_REPO_URL" 2>/dev/null | grep -m 1 "^VERSION=" | cut -d'"' -f2)
            
            if [[ -n "$REMOTE_VERSION_LATEST" ]]; then
                if [[ "$AUTO_UPDATE" == "true" ]]; then
                    local TEMP_SCRIPT_PATH="${INSTALL_DIR}/backup-restore.sh.tmp"
                    if curl -fsSL "$SCRIPT_REPO_URL" -o "$TEMP_SCRIPT_PATH" 2>/dev/null; then
                        if [[ -s "$TEMP_SCRIPT_PATH" ]] && head -n 1 "$TEMP_SCRIPT_PATH" | grep -q -e '^#!.*bash'; then
                            find "$(dirname "$SCRIPT_PATH")" -maxdepth 1 -name "${SCRIPT_NAME}.bak.*" -type f -delete
                            cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak.$(date +%s)" 2>/dev/null
                            mv "$TEMP_SCRIPT_PATH" "$SCRIPT_PATH" 2>/dev/null
                            chmod +x "$SCRIPT_PATH" 2>/dev/null
                            
                            local base_url="${SCRIPT_REPO_URL%/*}"
                            mkdir -p "$TRANSLATIONS_DIR"
                            for lang_file in ru.sh en.sh; do
                                curl -fsSL "$base_url/translations/$lang_file" -o "$TRANSLATIONS_DIR/$lang_file" 2>/dev/null
                            done
                            
                            local auto_update_msg="✅ *$(t tg_auto_updated)* ${CURRENT_VERSION} *$(t tg_auto_updated_to)* ${REMOTE_VERSION_LATEST}"
                            local release_url="https://github.com/k0sha/rw-shm-backup-restore/releases/tag/${REMOTE_VERSION_LATEST}"
                            local keyboard="{\"inline_keyboard\":[[{\"text\":\"$(t tg_auto_update_changelog)\",\"url\":\"${release_url}\"}]]}"

                            curl -s -X POST ${TG_PROXY:+--proxy "$TG_PROXY"} "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                                -d "chat_id=${CHAT_ID}" \
                                -d "text=${auto_update_msg}" \
                                -d "parse_mode=Markdown" \
                                -d "reply_markup=${keyboard}" \
                                ${TG_MESSAGE_THREAD_ID:+-d "message_thread_id=${TG_MESSAGE_THREAD_ID}"} \
                                >/dev/null 2>&1
                        else
                            rm -f "$TEMP_SCRIPT_PATH"
                        fi
                    fi
                else
                    local update_msg="⚠️ *$(t tg_update_avail)*"$'\n'"🔄 *$(t tg_cur_ver)* ${CURRENT_VERSION}"$'\n'"🆕 *$(t tg_new_ver)* ${REMOTE_VERSION_LATEST}"$'\n\n'"📥 $(t tg_update_menu)"
                    send_telegram_message "$update_msg" >/dev/null 2>&1
                fi
            fi
        fi
    } &
}

setup_auto_send() {
    echo ""
    if [[ $EUID -ne 0 ]]; then
        print_message "WARN" "$(t cron_root)"
        read -rp "$(t press_enter)"
        return
    fi
    while true; do
        clear
        echo -e "${GREEN}${BOLD}$(t cron_title)${RESET}"
        echo ""
        if [[ -n "$CRON_TIMES" ]]; then
            print_message "INFO" "$(t cron_on) ${BOLD}${CRON_TIMES}${RESET} $(t cron_utc)"
        else
            print_message "INFO" "$(t cron_off)"
        fi
        echo ""
        echo "   1. $(t cron_enable)"
        echo "   2. $(t cron_disable)"
        echo "   0. $(t back_to_menu)"
        echo ""
        read -rp "${GREEN}[?]${RESET} $(t select_option)" choice
        echo ""
        case $choice in
            1)
                local server_offset_str=$(date +%z)
                local offset_sign="${server_offset_str:0:1}"
                local offset_hours=$((10#${server_offset_str:1:2}))
                local offset_minutes=$((10#${server_offset_str:3:2}))

                local server_offset_total_minutes=$((offset_hours * 60 + offset_minutes))
                if [[ "$offset_sign" == "-" ]]; then
                    server_offset_total_minutes=$(( -server_offset_total_minutes ))
                fi

                echo "$(t cron_variant)"
                echo "  1) $(t cron_time)"
                echo "  2) $(t cron_hourly)"
                echo "  3) $(t cron_daily)"
                read -rp "$(t your_choice)" send_choice
                echo ""

                cron_times_to_write=()
                user_friendly_times_local=""
                invalid_format=false

                if [[ "$send_choice" == "1" ]]; then
                    echo "$(t cron_enter_utc)"
                    read -rp "$(t cron_time_space)" times
                    IFS=' ' read -ra arr <<< "$times"

                    for t_val in "${arr[@]}"; do
                        if [[ $t_val =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
                            local hour_utc_input=$((10#${BASH_REMATCH[1]}))
                            local min_utc_input=$((10#${BASH_REMATCH[2]}))

                            if (( hour_utc_input >= 0 && hour_utc_input <= 23 && min_utc_input >= 0 && min_utc_input <= 59 )); then
                                local total_minutes_utc=$((hour_utc_input * 60 + min_utc_input))
                                local total_minutes_local=$((total_minutes_utc + server_offset_total_minutes))

                                while (( total_minutes_local < 0 )); do
                                    total_minutes_local=$((total_minutes_local + 24 * 60))
                                done
                                while (( total_minutes_local >= 24 * 60 )); do
                                    total_minutes_local=$((total_minutes_local - 24 * 60))
                                done

                                local hour_local=$((total_minutes_local / 60))
                                local min_local=$((total_minutes_local % 60))

                                cron_times_to_write+=("$min_local $hour_local")
                                user_friendly_times_local+="$t_val "
                            else
                                print_message "ERROR" "$(t cron_bad_value) ${BOLD}$t_val${RESET} $(t cron_hm_range)"
                                invalid_format=true
                                break
                            fi
                        else
                            print_message "ERROR" "$(t cron_bad_fmt) ${BOLD}$t_val${RESET} $(t cron_expect_hhmm)"
                            invalid_format=true
                            break
                        fi
                    done
                elif [[ "$send_choice" == "2" ]]; then
                    cron_times_to_write=("@hourly")
                    user_friendly_times_local="@hourly"
                elif [[ "$send_choice" == "3" ]]; then
                    cron_times_to_write=("@daily")
                    user_friendly_times_local="@daily"
                else
                    print_message "ERROR" "$(t cron_bad_choice)"
                    continue
                fi

                echo ""

                if [ "$invalid_format" = true ] || [ ${#cron_times_to_write[@]} -eq 0 ]; then
                    print_message "ERROR" "$(t cron_err_input)"
                    continue
                fi

                print_message "INFO" "$(t cron_setting)"

                local temp_crontab_file=$(mktemp)

                if ! crontab -l > "$temp_crontab_file" 2>/dev/null; then
                    touch "$temp_crontab_file"
                fi

                if ! grep -q "^SHELL=" "$temp_crontab_file"; then
                    echo "SHELL=/bin/bash" | cat - "$temp_crontab_file" > "$temp_crontab_file.tmp"
                    mv "$temp_crontab_file.tmp" "$temp_crontab_file"
                    print_message "INFO" "$(t cron_shell)"
                fi

                if ! grep -q "^PATH=" "$temp_crontab_file"; then
                    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin" | cat - "$temp_crontab_file" > "$temp_crontab_file.tmp"
                    mv "$temp_crontab_file.tmp" "$temp_crontab_file"
                    print_message "INFO" "$(t cron_path_add)"
                else
                    print_message "INFO" "$(t cron_path_exists)"
                fi

                grep -vF "$SCRIPT_PATH backup" "$temp_crontab_file" > "$temp_crontab_file.tmp"
                mv "$temp_crontab_file.tmp" "$temp_crontab_file"

                for time_entry_local in "${cron_times_to_write[@]}"; do
                    if [[ "$time_entry_local" == "@hourly" ]] || [[ "$time_entry_local" == "@daily" ]]; then
                        echo "$time_entry_local $SCRIPT_PATH backup >> /var/log/rw_backup_cron.log 2>&1" >> "$temp_crontab_file"
                    else
                        echo "$time_entry_local * * * $SCRIPT_PATH backup >> /var/log/rw_backup_cron.log 2>&1" >> "$temp_crontab_file"
                    fi
                done

                if crontab "$temp_crontab_file"; then
                    print_message "SUCCESS" "$(t cron_ok)"
                else
                    print_message "ERROR" "$(t cron_fail)"
                fi

                rm -f "$temp_crontab_file"

                CRON_TIMES="${user_friendly_times_local% }"
                save_config
                print_message "SUCCESS" "$(t cron_set) ${BOLD}${CRON_TIMES}${RESET} $(t cron_utc)"
                ;;
            2)
                print_message "INFO" "$(t cron_disabling)"
                (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -

                CRON_TIMES=""
                save_config
                print_message "SUCCESS" "$(t cron_disabled)"
                ;;
            0) break ;;
            *) print_message "ERROR" "$(t invalid_input_select)" ;;
        esac
        echo ""
        read -rp "$(t press_enter)"
    done
    echo ""
}

restore_backup() {
    clear
    echo "${GREEN}${BOLD}$(t rs_title)${RESET}"
    echo ""
    
    local S3_STREAM_RESTORE=false

    echo "$(t rs_source_select)"
    echo " 1. $(t rs_source_local)"
    echo " 2. $(t rs_source_s3)"
    echo ""
    echo " 0. $(t back_to_menu)"
    echo ""
    local source_choice
    read -rp "${GREEN}[?]${RESET} $(t select_option)" source_choice

    case "$source_choice" in
        0) return ;;
        2)
            local rs_s3_endpoint="$S3_ENDPOINT"
            local rs_s3_region="${S3_REGION:-us-east-1}"
            local rs_s3_bucket="$S3_BUCKET"
            local rs_s3_access="$S3_ACCESS_KEY"
            local rs_s3_secret="$S3_SECRET_KEY"
            local rs_s3_prefix="$S3_PREFIX"

            if [[ -z "$rs_s3_bucket" || -z "$rs_s3_access" || -z "$rs_s3_secret" || -z "$rs_s3_endpoint" ]]; then
                print_message "ACTION" "$(t rs_s3_enter_creds)"
                echo ""
                [[ -z "$rs_s3_endpoint" ]] && read -rp "   $(t ul_s3_enter_endpoint)" rs_s3_endpoint
                [[ -z "$rs_s3_region" || "$rs_s3_region" == "us-east-1" ]] && { read -rp "   $(t ul_s3_enter_region)" input_region; rs_s3_region="${input_region:-us-east-1}"; }
                [[ -z "$rs_s3_bucket" ]] && read -rp "   $(t ul_s3_enter_bucket)" rs_s3_bucket
                [[ -z "$rs_s3_access" ]] && read -rp "   $(t ul_s3_enter_access)" rs_s3_access
                [[ -z "$rs_s3_secret" ]] && read -rp "   $(t ul_s3_enter_secret)" rs_s3_secret
                echo ""
                echo "   $(t ul_s3_prefix_info1)"
                echo "   $(t ul_s3_prefix_info2)"
                read -rp "   $(t ul_s3_enter_prefix)" rs_s3_prefix
                echo ""

                if [[ -z "$rs_s3_bucket" || -z "$rs_s3_access" || -z "$rs_s3_secret" || -z "$rs_s3_endpoint" ]]; then
                    print_message "ERROR" "$(t ul_s3_fail)"
                    read -rp "$(t press_enter_back)"
                    return
                fi
            fi

            if ! command -v aws &> /dev/null; then
                if ! install_aws_cli; then
                    print_message "ERROR" "$(t s3_aws_not_found)"
                    read -rp "$(t press_enter_back)"
                    return
                fi
            fi

            print_message "INFO" "$(t rs_s3_listing)"

            local s3_endpoint_arg="--endpoint-url $rs_s3_endpoint"
            local s3_prefix_arg="${rs_s3_prefix:+${rs_s3_prefix}/}"

            local s3_file_list
            s3_file_list=$(AWS_ACCESS_KEY_ID="$rs_s3_access" \
                AWS_SECRET_ACCESS_KEY="$rs_s3_secret" \
                AWS_DEFAULT_REGION="$rs_s3_region" \
                aws s3 ls "s3://${rs_s3_bucket}/${s3_prefix_arg}" \
                $s3_endpoint_arg 2>/dev/null | grep -E "remnawave_backup_.*\.tar\.gz|shm_backup_.*\.tar\.gz" | sort -r)

            if [[ -z "$s3_file_list" ]]; then
                print_message "ERROR" "$(t rs_s3_no_files)"
                read -rp "$(t press_enter_back)"
                return
            fi

            local -a s3_files=()
            local -a s3_sizes=()
            while IFS= read -r line; do
                local fname
                fname=$(echo "$line" | awk '{print $NF}')
                local fsize
                fsize=$(echo "$line" | awk '{print $3}')
                if [[ -n "$fname" ]]; then
                    s3_files+=("$fname")
                    s3_sizes+=("$fsize")
                fi
            done <<< "$s3_file_list"

            echo ""
            echo "$(t rs_s3_select)"
            local i=1
            for idx in "${!s3_files[@]}"; do
                local human_size
                human_size=$(numfmt --to=iec-i --suffix=B "${s3_sizes[$idx]}" 2>/dev/null || echo "${s3_sizes[$idx]}B")
                echo " $i) ${s3_files[$idx]} ($human_size)"
                i=$((i+1))
            done
            echo ""
            echo " 0) $(t back)"
            echo ""

            local s3_choice s3_index
            while true; do
                read -rp "${GREEN}[?]${RESET} $(t rs_enter_num)" s3_choice
                [[ "$s3_choice" == "0" ]] && return
                [[ "$s3_choice" =~ ^[0-9]+$ ]] || { print_message "ERROR" "$(t invalid_input)"; continue; }
                s3_index=$((s3_choice - 1))
                (( s3_index >= 0 && s3_index < ${#s3_files[@]} )) && break
                print_message "ERROR" "$(t rs_invalid_num)"
            done

            local selected_s3_file="${s3_files[$s3_index]}"
            local s3_full_key="${s3_prefix_arg}${selected_s3_file}"

            S3_STREAM_RESTORE=true
            S3_RESTORE_KEY="$s3_full_key"
            S3_RESTORE_FILE="$selected_s3_file"
            S3_RESTORE_ENDPOINT_ARG="$s3_endpoint_arg"
            S3_RESTORE_ACCESS="$rs_s3_access"
            S3_RESTORE_SECRET="$rs_s3_secret"
            S3_RESTORE_REGION="$rs_s3_region"
            S3_RESTORE_BUCKET="$rs_s3_bucket"
            ;;
        1) ;;
        *) print_message "ERROR" "$(t invalid_input_select)"; read -rp "$(t press_enter)"; return ;;
    esac

    local temp_restore_dir="$BACKUP_DIR/restore_temp_$$"
    mkdir -p "$temp_restore_dir"

    if [[ "$S3_STREAM_RESTORE" == true ]]; then
        clear
        print_message "INFO" "$(t rs_s3_stream) ${BOLD}${S3_RESTORE_FILE}${RESET}..."

        if ! AWS_ACCESS_KEY_ID="$S3_RESTORE_ACCESS" \
             AWS_SECRET_ACCESS_KEY="$S3_RESTORE_SECRET" \
             AWS_DEFAULT_REGION="$S3_RESTORE_REGION" \
             aws s3 cp "s3://${S3_RESTORE_BUCKET}/${S3_RESTORE_KEY}" - \
             $S3_RESTORE_ENDPOINT_ARG 2>/dev/null | tar -xzf - -C "$temp_restore_dir"; then
            print_message "ERROR" "$(t rs_s3_stream_err)"
            rm -rf "$temp_restore_dir"
            read -rp "$(t press_enter_back)"
            return
        fi

        print_message "SUCCESS" "$(t rs_s3_stream_ok)"
        echo ""
    else
        print_message "INFO" "$(t rs_place_file) ${BOLD}${BACKUP_DIR}${RESET}"
        echo ""

        if ! compgen -G "$BACKUP_DIR/remnawave_backup_*.tar.gz" > /dev/null && \
           ! compgen -G "$BACKUP_DIR/shm_backup_*.tar.gz" > /dev/null; then
            print_message "ERROR" "$(t rs_no_files) ${BOLD}${BACKUP_DIR}${RESET}."
            rm -rf "$temp_restore_dir"
            read -rp "$(t press_enter_back)"
            return
        fi

        readarray -t SORTED_BACKUP_FILES < <(
            find "$BACKUP_DIR" -maxdepth 1 \( -name "remnawave_backup_*.tar.gz" -o -name "shm_backup_*.tar.gz" \) -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-
        )

        echo ""
        echo "$(t rs_select_file)"
        local i=1
        for file in "${SORTED_BACKUP_FILES[@]}"; do
            echo " $i) ${file##*/}"
            i=$((i+1))
        done
        echo ""
        echo " 0) $(t back_to_menu)"
        echo ""

        local user_choice selected_index
        while true; do
            read -rp "${GREEN}[?]${RESET} $(t rs_enter_num)" user_choice
            [[ "$user_choice" == "0" ]] && { rm -rf "$temp_restore_dir"; return; }
            [[ "$user_choice" =~ ^[0-9]+$ ]] || { print_message "ERROR" "$(t invalid_input)"; continue; }
            selected_index=$((user_choice - 1))
            (( selected_index >= 0 && selected_index < ${#SORTED_BACKUP_FILES[@]} )) && break
            print_message "ERROR" "$(t rs_invalid_num)"
        done

        SELECTED_BACKUP="${SORTED_BACKUP_FILES[$selected_index]}"

        clear
        print_message "INFO" "$(t rs_unpacking)"

        if ! tar -xzf "$SELECTED_BACKUP" -C "$temp_restore_dir"; then
            print_message "ERROR" "$(t rs_unpack_err)"
            rm -rf "$temp_restore_dir"
            read -rp "$(t press_enter_back)"
            return
        fi

        print_message "SUCCESS" "$(t rs_unpacked)"
        echo ""
    fi

    local BACKUP_DUMP_TYPE="dumpall"
    local BACKUP_META_VERSION=""
    local BACKUP_META_DB_NAME=""
    local BACKUP_PANEL_VERSION=""

    if [[ -f "$temp_restore_dir/rw_meta.info" ]]; then
        source "$temp_restore_dir/rw_meta.info"
        BACKUP_DUMP_TYPE="${DUMP_TYPE:-dumpall}"
        BACKUP_META_VERSION="${BACKUP_VERSION:-}"
        BACKUP_META_DB_NAME="${DB_NAME:-}"
        BACKUP_PANEL_VERSION="${PANEL_VERSION:-}"
        print_message "INFO" "$(t rs_meta)${BOLD}${BACKUP_DUMP_TYPE}${RESET}"
        print_message "INFO" "$(t rs_meta_ver)${BOLD}${BACKUP_META_VERSION:-$(t rs_meta_unknown)}${RESET}"
        print_message "INFO" "$(t rs_meta_panel)${BOLD}${BACKUP_PANEL_VERSION:-$(t rs_meta_unknown)}${RESET}"
    else
        print_message "INFO" "$(t rs_no_meta)"
    fi
    
    local CURRENT_DUMP_TYPE
    if [[ "$DB_CONNECTION_TYPE" == "docker" ]]; then
        CURRENT_DUMP_TYPE="dumpall"
    else
        CURRENT_DUMP_TYPE="dump"
    fi
    
    if [[ "$BACKUP_DUMP_TYPE" != "$CURRENT_DUMP_TYPE" ]]; then
        echo ""
        print_message "WARN" "${YELLOW}$(t rs_mismatch)${RESET}"
        print_message "WARN" "$(t rs_bk_mode) ${BOLD}${BACKUP_DUMP_TYPE}${RESET}"
        print_message "WARN" "$(t rs_cur_mode) ${BOLD}${CURRENT_DUMP_TYPE}${RESET}"
        echo ""
        
        if [[ "$BACKUP_DUMP_TYPE" == "dump" && "$CURRENT_DUMP_TYPE" == "dumpall" ]]; then
            print_message "INFO" "$(t rs_ext_options)"
            echo ""
            echo " 1. $(t rs_opt_ext)"
            echo " 2. $(t rs_opt_docker)"
            echo " 0. $(t rs_opt_cancel)"
            echo ""
            
            local ext_choice
            read -rp " ${GREEN}[?]${RESET} $(t your_choice)" ext_choice
            
            case "$ext_choice" in
                1)
                    print_message "ACTION" "$(t rs_enter_ext)"
                    echo ""
                    read -rp "   $(t rs_host)" DB_HOST
                    read -rp "   $(t rs_port)" input_db_port
                    DB_PORT="${input_db_port:-5432}"
                    read -rp "   $(t rs_dbname)" input_db_name
                    DB_NAME="${input_db_name:-postgres}"
                    read -rp "   $(t rs_user)" input_db_user
                    DB_USER="${input_db_user:-postgres}"
                    read -rsp "   $(t rs_pass)" DB_PASSWORD
                    echo ""
                    read -rp "   $(t rs_ssl)" input_ssl
                    DB_SSL_MODE="${input_ssl:-prefer}"
                    read -rp "   $(t rs_pgver)" input_pg_ver
                    DB_POSTGRES_VERSION="${input_pg_ver:-17}"
                    
                    DB_CONNECTION_TYPE="external"
                    CURRENT_DUMP_TYPE="dump"
                    
                    echo ""
                    print_message "INFO" "$(t rs_testing)"
                    local pg_image=$(get_postgres_image)
                    if docker run --rm --network host \
                        -e PGPASSWORD="$DB_PASSWORD" \
                        -e PGSSLMODE="$DB_SSL_MODE" \
                        "$pg_image" \
                        pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" 2>/dev/null; then
                        print_message "SUCCESS" "$(t rs_conn_ok)"
                        save_config
                        print_message "SUCCESS" "$(t rs_ext_saved)"
                    else
                        print_message "ERROR" "$(t rs_conn_fail)"
                        rm -rf "$temp_restore_dir"
                        read -rp "$(t press_enter_back)"
                        return
                    fi
                    ;;
                2)
                    print_message "WARN" "$(t rs_globals_skip)"
                    print_message "INFO" "$(t rs_cont_docker)"
                    ;;
                0|*)
                    print_message "INFO" "$(t rs_cancelled)"
                    rm -rf "$temp_restore_dir"
                    read -rp "$(t press_enter_back)"
                    return
                    ;;
            esac
        elif [[ "$BACKUP_DUMP_TYPE" == "dumpall" && "$CURRENT_DUMP_TYPE" == "dump" ]]; then
            print_message "WARN" "$(t rs_dumpall_ext)"
            print_message "WARN" "$(t rs_dumpall_warn)"
            echo ""
            read -rp "$(echo -e "${GREEN}[?]${RESET} $(t rs_continue_q) ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" compat_confirm
            if [[ ! "$compat_confirm" =~ ^[yY]$ ]]; then
                print_message "INFO" "$(t rs_cancelled)"
                rm -rf "$temp_restore_dir"
                read -rp "$(t press_enter_back)"
                return
            fi
        fi
    fi

    local PANEL_DUMP
    PANEL_DUMP=$(find "$temp_restore_dir" -name "dump_*.sql.gz" | head -n 1)
    local PANEL_DIR_ARCHIVE
    PANEL_DIR_ARCHIVE=$(find "$temp_restore_dir" -name "remnawave_dir_*.tar.gz" | head -n 1)
    local SHM_DUMP_CHECK
    SHM_DUMP_CHECK=$(find "$temp_restore_dir" -name "shm_dump_*.sql.gz" | head -n 1)
    local SHM_DIR_CHECK
    SHM_DIR_CHECK=$(find "$temp_restore_dir" -name "shm_dir_*.tar.gz" | head -n 1)

    local _has_rw=false
    local _has_shm=false
    [[ -n "$PANEL_DUMP" && -n "$PANEL_DIR_ARCHIVE" ]] && _has_rw=true
    [[ -n "$SHM_DUMP_CHECK" || -n "$SHM_DIR_CHECK" ]] && _has_shm=true

    local _restore_rw=false
    local _restore_shm=false

    if [[ "$_has_rw" == "true" && "$_has_shm" == "true" ]]; then
        echo ""
        print_message "ACTION" "$(t rs_select_source)"
        echo " 1. $(t src_remnawave)"
        echo " 2. $(t src_shm)"
        echo " 3. $(t bk_source_both)"
        echo ""
        local _rs_choice
        while true; do
            read -rp " ${GREEN}[?]${RESET} $(t your_choice)" _rs_choice
            case "$_rs_choice" in
                1) _restore_rw=true; break ;;
                2) _restore_shm=true; break ;;
                3) _restore_rw=true; _restore_shm=true; break ;;
                *) print_message "ERROR" "$(t invalid_input)" ;;
            esac
        done
        echo ""
    elif [[ "$_has_rw" == "true" ]]; then
        _restore_rw=true
    elif [[ "$_has_shm" == "true" ]]; then
        _restore_shm=true
    fi

    local PANEL_STATUS=2
    local SHM_STATUS=2

    if [[ "$_restore_rw" != "true" || -z "$PANEL_DUMP" || -z "$PANEL_DIR_ARCHIVE" ]]; then
        print_message "WARN" "$(t rs_panel_missing)"
        PANEL_STATUS=2
    else
        print_message "WARN" "$(t rs_panel_found)"
        read -rp "$(echo -e "${GREEN}[?]${RESET} $(t rs_panel_q) (${GREEN}Y${RESET}/${RED}N${RESET}): ")" confirm_panel
        echo ""
        if [[ "$confirm_panel" =~ ^[Yy]$ ]]; then
            check_docker_installed || { rm -rf "$temp_restore_dir"; return 1; }
            print_message "INFO" "$(t rs_enter_dbname)"
            read -rp "$(t input_prompt)" restore_db_name
            restore_db_name="${restore_db_name:-postgres}"

            if [[ "$DB_CONNECTION_TYPE" == "docker" ]]; then
                if [[ -d "$REMNALABS_ROOT_DIR" ]]; then
                    cd "$REMNALABS_ROOT_DIR" 2>/dev/null && docker compose down 2>/dev/null
                    cd ~
                    rm -rf "$REMNALABS_ROOT_DIR"
                fi

                mkdir -p "$REMNALABS_ROOT_DIR"
                local extract_dir="$BACKUP_DIR/extract_temp_$$"
                mkdir -p "$extract_dir"
                tar -xzf "$PANEL_DIR_ARCHIVE" -C "$extract_dir"
                local extracted_dir
                extracted_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
                cp -rf "$extracted_dir"/. "$REMNALABS_ROOT_DIR/"
                rm -rf "$extract_dir"

                docker volume rm remnawave-db-data 2>/dev/null || true
                cd "$REMNALABS_ROOT_DIR" || { print_message "ERROR" "$(t rs_dir_missing)"; return; }
                docker compose up -d remnawave-db

                print_message "INFO" "$(t rs_wait_db)"
                until [[ "$(docker inspect --format='{{.State.Health.Status}}' remnawave-db)" == "healthy" ]]; do
                    sleep 2
                    echo -n "."
                done
                echo ""
            else
                if [[ -d "$REMNALABS_ROOT_DIR" ]]; then
                    cd "$REMNALABS_ROOT_DIR" 2>/dev/null && docker compose down 2>/dev/null
                    cd ~
                    rm -rf "$REMNALABS_ROOT_DIR"
                fi

                mkdir -p "$REMNALABS_ROOT_DIR"
                local extract_dir="$BACKUP_DIR/extract_temp_$$"
                mkdir -p "$extract_dir"
                tar -xzf "$PANEL_DIR_ARCHIVE" -C "$extract_dir"
                local extracted_dir
                extracted_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
                cp -rf "$extracted_dir"/. "$REMNALABS_ROOT_DIR/"
                rm -rf "$extract_dir"
                
                print_message "INFO" "$(t rs_check_ext)"
                local pg_image=$(get_postgres_image)
                if ! docker run --rm --network host \
                    -e PGPASSWORD="$DB_PASSWORD" \
                    -e PGSSLMODE="$DB_SSL_MODE" \
                    "$pg_image" \
                    pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" 2>/dev/null; then
                    print_message "ERROR" "$(t rs_ext_unavail) (${DB_HOST}:${DB_PORT}). $(t rs_check_conn)"
                    rm -rf "$temp_restore_dir"
                    read -rp "$(t press_enter_back)"
                    return 1
                fi
                print_message "SUCCESS" "$(t rs_ext_ok)"
            fi

            print_message "INFO" "$(t rs_restoring_db)"
            gunzip "$PANEL_DUMP"
            local sql_file="${PANEL_DUMP%.gz}"
            local restore_log="$temp_restore_dir/restore_errors.log"

            if ! restore_panel_db_dump "$sql_file" "$restore_db_name" "$restore_log"; then
                echo ""
                print_message "ERROR" "$(t rs_db_err)"
                [[ -f "$restore_log" ]] && cat "$restore_log"
                rm -rf "$temp_restore_dir"
                read -rp "$(t press_enter_back)"
                return 1
            fi

            print_message "SUCCESS" "$(t rs_db_ok)"
            echo ""
            
            if [[ "$DB_CONNECTION_TYPE" == "docker" ]]; then
                print_message "INFO" "$(t rs_start_containers)"
                cd "$REMNALABS_ROOT_DIR" || { print_message "ERROR" "$(t rs_dir_missing)"; return; }
                if docker compose up -d; then
                    print_message "SUCCESS" "$(t rs_panel_ok)"
                    PANEL_STATUS=0
                else
                    print_message "ERROR" "$(t rs_panel_fail)"
                    rm -rf "$temp_restore_dir"
                    read -rp "$(t press_enter_back)"
                    return 1
                fi
            else
                cd "$REMNALABS_ROOT_DIR" || { print_message "ERROR" "$(t rs_dir_missing)"; return; }
                print_message "INFO" "$(t rs_start_no_db)"
                if docker compose up -d; then
                    print_message "SUCCESS" "$(t rs_panel_ok)"
                    PANEL_STATUS=0
                else
                    print_message "ERROR" "$(t rs_panel_fail)"
                    rm -rf "$temp_restore_dir"
                    read -rp "$(t press_enter_back)"
                    return 1
                fi
            fi
        else
            print_message "INFO" "$(t rs_panel_skipped)"
            PANEL_STATUS=2
        fi
    fi

    echo ""

    if [[ "$PANEL_STATUS" == "0" ]]; then
        print_message "SUCCESS" "$(t rs_panel_ready)"
        read -rp ""
    fi

    if [[ "$_restore_shm" == "true" ]]; then
        echo ""
        if restore_shm_backup "$temp_restore_dir"; then
            SHM_STATUS=0
        else
            local shm_res=$?
            if [[ "$shm_res" == "2" ]]; then SHM_STATUS=2; else SHM_STATUS=1; fi
        fi
    fi

    rm -rf "$temp_restore_dir"
    sleep 2

    REMNAWAVE_VERSION=$(get_remnawave_version)
    local telegram_msg
    telegram_msg="💾 #restore_success"$'\n'"➖➖➖➖➖➖➖➖➖"$'\n'"✅ *$(t tg_restore_done)*"

    if [[ "$PANEL_STATUS" == "0" && "$SHM_STATUS" == "0" ]]; then
        telegram_msg+=$'\n'"🌊 *Remnawave:* ${REMNAWAVE_VERSION}"$'\n'"🖥️ *SHM*"
    elif [[ "$PANEL_STATUS" == "0" ]]; then
        telegram_msg+=$'\n'"🌊 *Remnawave:* ${REMNAWAVE_VERSION}"
    elif [[ "$SHM_STATUS" == "0" ]]; then
        telegram_msg+=$'\n'"🖥️ *SHM*"
    else
        telegram_msg+=$'\n'"⚠️ *$(t tg_nothing)*"
    fi

    print_message "SUCCESS" "$(t rs_complete)"
    send_telegram_message "$telegram_msg" >/dev/null 2>&1
    read -rp "$(t press_enter_back)"
}

update_script() {
    print_message "INFO" "$(t upd_checking)"
    echo ""
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}⛔ $(t upd_root)${RESET}"
        read -rp "$(t press_enter)"
        return
    fi

    print_message "INFO" "$(t upd_fetching)"
    local TEMP_REMOTE_VERSION_FILE
    TEMP_REMOTE_VERSION_FILE=$(mktemp)

    if ! curl -fsSL "$SCRIPT_REPO_URL" 2>/dev/null | head -n 100 > "$TEMP_REMOTE_VERSION_FILE"; then
        print_message "ERROR" "$(t upd_fetch_fail)"
        rm -f "$TEMP_REMOTE_VERSION_FILE"
        read -rp "$(t press_enter)"
        return
    fi

    REMOTE_VERSION=$(grep -m 1 "^VERSION=" "$TEMP_REMOTE_VERSION_FILE" | cut -d'"' -f2)
    rm -f "$TEMP_REMOTE_VERSION_FILE"

    if [[ -z "$REMOTE_VERSION" ]]; then
        print_message "ERROR" "$(t upd_parse_fail)"
        read -rp "$(t press_enter)"
        return
    fi

    print_message "INFO" "$(t upd_current) ${BOLD}${YELLOW}${VERSION}${RESET}"
    print_message "INFO" "$(t upd_available) ${BOLD}${GREEN}${REMOTE_VERSION}${RESET}"
    echo ""

    if compare_versions "$VERSION" "$REMOTE_VERSION"; then
        print_message "ACTION" "$(t upd_new_avail) ${BOLD}${REMOTE_VERSION}${RESET}."
        echo -e -n "$(t upd_confirm) ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: "
        read -r confirm_update
        echo ""

        if [[ "${confirm_update,,}" != "y" ]]; then
            print_message "WARN" "$(t upd_cancelled)"
            read -rp "$(t press_enter)"
            return
        fi
    else
        print_message "INFO" "$(t upd_latest)"
        read -rp "$(t press_enter)"
        return
    fi

    local TEMP_SCRIPT_PATH="${INSTALL_DIR}/backup-restore.sh.tmp"
    print_message "INFO" "$(t upd_downloading)"
    if ! curl -fsSL "$SCRIPT_REPO_URL" -o "$TEMP_SCRIPT_PATH"; then
        print_message "ERROR" "$(t upd_download_fail)"
        read -rp "$(t press_enter)"
        return
    fi

    if [[ ! -s "$TEMP_SCRIPT_PATH" ]] || ! head -n 1 "$TEMP_SCRIPT_PATH" | grep -q -e '^#!.*bash'; then
        print_message "ERROR" "$(t upd_invalid_file)"
        rm -f "$TEMP_SCRIPT_PATH"
        read -rp "$(t press_enter)"
        return
    fi

    download_translations

    print_message "INFO" "$(t upd_rm_old_bak)"
    find "$(dirname "$SCRIPT_PATH")" -maxdepth 1 -name "${SCRIPT_NAME}.bak.*" -type f -delete
    echo ""

    local BACKUP_PATH_SCRIPT="${SCRIPT_PATH}.bak.$(date +%s)"
    print_message "INFO" "$(t upd_creating_bak)"
    cp "$SCRIPT_PATH" "$BACKUP_PATH_SCRIPT" || {
        echo -e "${RED}❌ $(t upd_bak_fail)${RESET}"
        rm -f "$TEMP_SCRIPT_PATH"
        read -rp "$(t press_enter)"
        return
    }
    echo ""

    mv "$TEMP_SCRIPT_PATH" "$SCRIPT_PATH" || {
        echo -e "${RED}❌ $(t upd_move_fail)${RESET}"
        echo -e "${YELLOW}⚠️ $(t upd_restoring_bak)${RESET}"
        mv "$BACKUP_PATH_SCRIPT" "$SCRIPT_PATH"
        rm -f "$TEMP_SCRIPT_PATH"
        read -rp "$(t press_enter)"
        return
    }

    chmod +x "$SCRIPT_PATH"
    print_message "SUCCESS" "$(t upd_done) ${BOLD}${GREEN}${REMOTE_VERSION}${RESET}."
    echo ""
    print_message "INFO" "$(t upd_restart)"
    read -rp "$(t press_enter_restart)"
    exec "$SCRIPT_PATH" "$@"
    exit 0
}

remove_script() {
    print_message "WARN" "${YELLOW}$(t rm_warn)${RESET}"
    echo  " - $(t rm_script)"
    echo  " - $(t rm_dir)"
    echo  " - $(t rm_symlink)"
    echo  " - $(t rm_cron)"
    echo ""
    echo -e -n "$(t rm_confirm) ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: "
    read -r confirm
    echo ""
    
    if [[ "${confirm,,}" != "y" ]]; then
    print_message "WARN" "$(t rm_cancelled)"
    read -rp "$(t press_enter)"
    return
    fi

    if [[ "$EUID" -ne 0 ]]; then
        print_message "WARN" "$(t rm_root) ${BOLD}sudo${RESET}."
        read -rp "$(t press_enter)"
        return
    fi

    print_message "INFO" "$(t rm_cron_removing)"
    if crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH backup"; then
        (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH backup") | crontab -
        print_message "SUCCESS" "$(t rm_cron_removed)"
    else
        print_message "INFO" "$(t rm_cron_none)"
    fi
    echo ""

    print_message "INFO" "$(t rm_symlink_removing)"
    if [[ -L "$SYMLINK_PATH" ]]; then
        rm -f "$SYMLINK_PATH" && print_message "SUCCESS" "$(t rm_symlink_removed) ${BOLD}${SYMLINK_PATH}${RESET}" || print_message "WARN" "$(t rm_symlink_fail) ${BOLD}${SYMLINK_PATH}${RESET}"
    elif [[ -e "$SYMLINK_PATH" ]]; then
        print_message "WARN" "${BOLD}${SYMLINK_PATH}${RESET} $(t rm_symlink_not_link)"
    else
        print_message "INFO" "$(t rm_symlink_none) ${BOLD}${SYMLINK_PATH}${RESET}"
    fi
    echo ""

    print_message "INFO" "$(t rm_dir_removing)"
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR" && print_message "SUCCESS" "${BOLD}${INSTALL_DIR}${RESET} $(t rm_dir_removed)" || echo -e "${RED}❌ $(t rm_dir_fail)${RESET}"
    else
        print_message "INFO" "$(t rm_dir_none) ${BOLD}${INSTALL_DIR}${RESET}"
    fi
    exit 0
}

configure_upload_method() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}$(t ul_title)${RESET}"
        echo ""
        print_message "INFO" "$(t ul_current) ${BOLD}${UPLOAD_METHOD^^}${RESET}"
        echo ""
        echo "   1. $(t ul_set_tg)"
        echo "   2. $(t ul_set_gd)"
        echo "   3. $(t ul_set_s3)"
        echo ""
        echo "   0. $(t back_to_menu)"
        echo ""
        read -rp "${GREEN}[?]${RESET} $(t select_option)" choice
        echo ""

        case $choice in
            1)
                UPLOAD_METHOD="telegram"
                save_config
                print_message "SUCCESS" "$(t ul_tg_set)"
                if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
                    print_message "ACTION" "$(t ul_tg_enter)"
                    echo ""
                    print_message "INFO" "$(t cfg_create_bot) ${CYAN}@BotFather${RESET}"
                    read -rp "   $(t ul_enter_token)" BOT_TOKEN
                    echo ""
                    print_message "INFO" "$(t ul_tg_id_help) ${CYAN}@userinfobot${RESET}"
                    read -rp "   $(t ul_enter_tg_id)" CHAT_ID
                    save_config
                    print_message "SUCCESS" "$(t ul_tg_saved)"
                fi
                ;;
            2)
                UPLOAD_METHOD="google_drive"
                print_message "SUCCESS" "$(t ul_gd_set)"
                
                local gd_setup_successful=true

                if [[ -z "$GD_CLIENT_ID" || -z "$GD_CLIENT_SECRET" || -z "$GD_REFRESH_TOKEN" ]]; then
                    print_message "ACTION" "$(t ul_gd_enter)"
                    echo ""
                    echo "$(t st_gd_no_tokens)"
                    local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
                    print_message "LINK" "$(t cfg_gd_guide) ${CYAN}${guide_url}${RESET}"
                    read -rp "   $(t cfg_enter_gd_id)" GD_CLIENT_ID
                    read -rp "   $(t cfg_enter_gd_secret)" GD_CLIENT_SECRET
                    
                    clear
                    
                    print_message "WARN" "$(t cfg_gd_auth_needed)"
                    print_message "INFO" "$(t cfg_gd_open_url)"
                    echo ""
                    local auth_url="https://accounts.google.com/o/oauth2/auth?client_id=${GD_CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=https://www.googleapis.com/auth/drive&response_type=code&access_type=offline"
                    print_message "INFO" "${CYAN}${auth_url}${RESET}"
                    echo ""
                    read -rp "$(t cfg_gd_enter_code)" AUTH_CODE
                    
                    print_message "INFO" "$(t cfg_gd_getting)"
                    local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
                        -d client_id="$GD_CLIENT_ID" \
                        -d client_secret="$GD_CLIENT_SECRET" \
                        -d code="$AUTH_CODE" \
                        -d redirect_uri="urn:ietf:wg:oauth:2.0:oob" \
                        -d grant_type="authorization_code")
                    
                    GD_REFRESH_TOKEN=$(echo "$token_response" | jq -r .refresh_token 2>/dev/null)
                    
                    if [[ -z "$GD_REFRESH_TOKEN" || "$GD_REFRESH_TOKEN" == "null" ]]; then
                        print_message "ERROR" "$(t ul_gd_fail)"
                        print_message "WARN" "$(t ul_gd_not_done)"
                        UPLOAD_METHOD="telegram"
                        gd_setup_successful=false
                    else
                        print_message "SUCCESS" "$(t ul_gd_token_ok)"
                    fi
                    echo
                    
                    if $gd_setup_successful; then
                        echo "   $(t cfg_gd_folder1)"
                        echo "   $(t cfg_gd_folder2)"
                        echo "   $(t cfg_gd_folder3)"
                        echo "      https://drive.google.com/drive/folders/1a2B3cD4eFmNOPqRstuVwxYz"
                        echo "   $(t cfg_gd_folder4)"
                        echo "   $(t cfg_gd_folder5)"
                        echo

                        read -rp "   $(t cfg_enter_gd_folder)" GD_FOLDER_ID
                    fi
                fi

                save_config

                if $gd_setup_successful; then
                    print_message "SUCCESS" "$(t ul_gd_saved)"
                else
                    print_message "SUCCESS" "$(t ul_tg_set)"
                fi
                ;;
            3)
                if ! install_aws_cli; then
                    print_message "WARN" "$(t ul_s3_aws_needed)"
                    echo ""
                    read -rp "$(t press_enter)"
                    continue
                fi
                
                UPLOAD_METHOD="s3"
                print_message "SUCCESS" "$(t ul_s3_set)"
                
                local s3_setup_successful=true

                if [[ -z "$S3_BUCKET" || -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
                    print_message "ACTION" "$(t ul_s3_enter)"
                    echo ""
                    read -rp "   $(t ul_s3_enter_endpoint)" S3_ENDPOINT
                    read -rp "   $(t ul_s3_enter_region)" S3_REGION
                    S3_REGION="${S3_REGION:-us-east-1}"
                    read -rp "   $(t ul_s3_enter_bucket)" S3_BUCKET
                    read -rp "   $(t ul_s3_enter_access)" S3_ACCESS_KEY
                    read -rp "   $(t ul_s3_enter_secret)" S3_SECRET_KEY
                    echo ""
                    echo "   $(t ul_s3_prefix_info1)"
                    echo "   $(t ul_s3_prefix_info2)"
                    read -rp "   $(t ul_s3_enter_prefix)" S3_PREFIX
                    echo ""
                    print_message "INFO" "$(t ul_s3_retain_info)"
                    read -rp "   $(printf "$(t ul_s3_enter_retain)" "$S3_RETAIN_DAYS")" input_s3_retain
                    S3_RETAIN_DAYS="${input_s3_retain:-$S3_RETAIN_DAYS}"
                    
                    if [[ -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" || -z "$S3_BUCKET" ]]; then
                        print_message "ERROR" "$(t ul_s3_fail)"
                        print_message "WARN" "$(t ul_s3_not_done)"
                        UPLOAD_METHOD="telegram"
                        s3_setup_successful=false
                    fi
                fi

                save_config

                if $s3_setup_successful; then
                    print_message "SUCCESS" "$(t ul_s3_saved)"
                else
                    print_message "SUCCESS" "$(t ul_tg_set)"
                fi
                ;;
            0) break ;;
            *) print_message "ERROR" "$(t invalid_input_select)" ;;
        esac
        echo ""
        read -rp "$(t press_enter)"
    done
    echo ""
}

restore_shm_backup() {
    local temp_restore_dir="$1"

    local SHM_DUMP_FILE
    SHM_DUMP_FILE=$(find "$temp_restore_dir" -name "shm_dump_*.sql.gz" | head -n 1)
    local SHM_DIR_ARCHIVE
    SHM_DIR_ARCHIVE=$(find "$temp_restore_dir" -name "shm_dir_*.tar.gz" | head -n 1)

    if [[ -z "$SHM_DUMP_FILE" && -z "$SHM_DIR_ARCHIVE" ]]; then
        print_message "INFO" "$(t rs_shm_missing)"
        return 2
    fi

    print_message "WARN" "$(t rs_shm_found)"
    read -rp "$(echo -e "${GREEN}[?]${RESET} $(t rs_shm_q) (${GREEN}Y${RESET}/${RED}N${RESET}): ")" confirm_shm
    echo ""
    if [[ ! "$confirm_shm" =~ ^[Yy]$ ]]; then
        print_message "INFO" "$(t rs_shm_cancelled)"
        return 1
    fi

    local shm_restore_path="${SHM_ROOT_DIR}"
    if [[ -z "$shm_restore_path" ]]; then
        print_message "ACTION" "$(t rs_shm_path_q)"
        echo " 1. /opt/shm"
        echo " 2. /root/shm"
        echo " 3. /opt/stacks/shm"
        echo " 4. $(t custom_path)"
        echo ""
        local shm_path_choice
        while true; do
            read -rp " ${GREEN}[?]${RESET} $(t select_variant)" shm_path_choice
            case "$shm_path_choice" in
            1) shm_restore_path="/opt/shm"; break ;;
            2) shm_restore_path="/root/shm"; break ;;
            3) shm_restore_path="/opt/stacks/shm"; break ;;
            4)
                echo ""
                print_message "INFO" "$(t cfg_enter_shm_path)"
                read -rp " $(t path_prompt)" custom_shm_restore
                if [[ -n "$custom_shm_restore" ]]; then
                    shm_restore_path="${custom_shm_restore%/}"
                    break
                fi
                ;;
            *) print_message "ERROR" "$(t invalid_input)" ;;
            esac
        done
    fi

    print_message "INFO" "$(t rs_shm_starting)"

    if [[ -d "$shm_restore_path" ]]; then
        if cd "$shm_restore_path" 2>/dev/null && ([[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]] || [[ -f "compose.yml" ]] || [[ -f "compose.yaml" ]]); then
            print_message "INFO" "$(t rs_shm_stopping)"
            docker compose down 2>/dev/null || print_message "WARN" "$(t rs_shm_stop_fail)"
        fi
        cd /
        rm -rf "$shm_restore_path"
    fi

    mkdir -p "$shm_restore_path"

    if [[ -n "$SHM_DIR_ARCHIVE" ]]; then
        print_message "INFO" "$(t rs_shm_unpack_dir)"
        local shm_extract_dir="$BACKUP_DIR/shm_extract_temp_$$"
        mkdir -p "$shm_extract_dir"

        if tar -xzf "$SHM_DIR_ARCHIVE" -C "$shm_extract_dir"; then
            local extracted_dir
            extracted_dir=$(find "$shm_extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
            if [[ -n "$extracted_dir" ]]; then
                cp -rf "$extracted_dir"/. "$shm_restore_path/"
                rm -rf "$shm_extract_dir"
                print_message "SUCCESS" "$(t rs_shm_dir_ok)"
            else
                rm -rf "$shm_extract_dir"
                print_message "ERROR" "$(t rs_shm_dir_err)"
                return 1
            fi
        else
            rm -rf "$shm_extract_dir"
            print_message "ERROR" "$(t rs_shm_dir_err)"
            return 1
        fi
    fi

    if [[ -n "$SHM_DUMP_FILE" ]]; then
        if cd "$shm_restore_path" 2>/dev/null && ([[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]] || [[ -f "compose.yml" ]] || [[ -f "compose.yaml" ]]); then
            print_message "INFO" "$(t rs_shm_start_all)"
            if ! docker compose up -d 2>/dev/null; then
                print_message "ERROR" "$(t rs_shm_start_fail)"
                return 1
            fi
            sleep 5
        fi
        cd /

        local shm_mysql_container
        shm_mysql_container=$(docker ps --format '{{.Names}}' | grep -iE 'shm.*(db|mysql|mariadb)|(db|mysql|mariadb).*shm' | head -n 1)

        if [[ -z "$shm_mysql_container" ]]; then
            print_message "ERROR" "$(t rs_shm_db_not_found)"
            return 1
        fi

        print_message "INFO" "$(t rs_shm_restoring_db)"
        local dump_uncompressed="${SHM_DUMP_FILE%.gz}"

        if gunzip -f "$SHM_DUMP_FILE" 2>/dev/null && docker exec -i "$shm_mysql_container" mysql -u root < "$dump_uncompressed" 2>/dev/null; then
            print_message "SUCCESS" "$(t rs_shm_db_ok)"
        else
            print_message "ERROR" "$(t rs_shm_dump_err)"
            return 1
        fi
    fi

    print_message "SUCCESS" "$(t rs_shm_ok)"
    return 0
}

configure_source_remnawave() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}$(t src_rw_title)${RESET}"
        echo ""

        local rw_status
        if [[ "$REMNAWAVE_ENABLED" == "true" ]]; then
            rw_status="${GREEN}$(t src_enabled)${RESET}"
        else
            rw_status="${RED}$(t src_disabled)${RESET}"
        fi
        print_message "INFO" "$(t src_enabled)/$(t src_disabled): ${rw_status}"
        print_message "INFO" "$(t src_rw_current_path) ${BOLD}${REMNALABS_ROOT_DIR:-$(t not_set)}${RESET}"
        print_message "INFO" "$(t src_rw_current_db_user) ${BOLD}${DB_USER:-$(t not_set)}${RESET}"
        echo ""

        if [[ "$REMNAWAVE_ENABLED" == "true" ]]; then
            echo "   1. $(t src_rw_disable)"
        else
            echo "   1. $(t src_rw_enable)"
        fi
        echo "   2. $(t src_rw_change_path)"
        echo "   3. $(t src_rw_change_db_user)"
        echo ""
        echo "   0. $(t back)"
        echo ""

        read -rp "${GREEN}[?]${RESET} $(t select_option)" choice
        echo ""
        case $choice in
            1)
                if [[ "$REMNAWAVE_ENABLED" == "true" ]]; then
                    REMNAWAVE_ENABLED="false"
                else
                    REMNAWAVE_ENABLED="true"
                fi
                save_config
                print_message "SUCCESS" "$(t config_saved)"
                read -rp "$(t press_enter)"
                ;;
            2)
                print_message "ACTION" "$(t cfg_where_panel)"
                echo " 1. /opt/remnawave"
                echo " 2. /root/remnawave"
                echo " 3. /opt/stacks/remnawave"
                echo " 4. $(t custom_path)"
                echo ""
                local path_choice
                while true; do
                    read -rp " ${GREEN}[?]${RESET} $(t select_variant)" path_choice
                    case "$path_choice" in
                    1) REMNALABS_ROOT_DIR="/opt/remnawave"; break ;;
                    2) REMNALABS_ROOT_DIR="/root/remnawave"; break ;;
                    3) REMNALABS_ROOT_DIR="/opt/stacks/remnawave"; break ;;
                    4)
                        echo ""
                        print_message "INFO" "$(t cfg_enter_panel_path)"
                        read -rp " $(t path_prompt)" custom_path_input
                        if [[ -z "$custom_path_input" ]]; then
                            print_message "ERROR" "$(t cfg_path_empty)"; echo ""; read -rp "$(t press_enter)"; continue
                        fi
                        if [[ ! "$custom_path_input" = /* ]]; then
                            print_message "ERROR" "$(t cfg_path_abs)"; echo ""; read -rp "$(t press_enter)"; continue
                        fi
                        custom_path_input="${custom_path_input%/}"
                        if [[ ! -d "$custom_path_input" ]]; then
                            print_message "WARN" "$(t cfg_dir_missing) ${BOLD}${custom_path_input}${RESET}"
                            read -rp "$(echo -e "${GREEN}[?]${RESET} $(t cfg_continue_path) ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" _confirm
                            if [[ "$_confirm" != "y" ]]; then echo ""; read -rp "$(t press_enter)"; continue; fi
                        fi
                        REMNALABS_ROOT_DIR="$custom_path_input"
                        print_message "SUCCESS" "$(t cfg_custom_set) ${BOLD}${REMNALABS_ROOT_DIR}${RESET}"
                        break
                        ;;
                    *) print_message "ERROR" "$(t invalid_input)" ;;
                    esac
                done
                save_config
                print_message "SUCCESS" "$(t config_saved)"
                read -rp "$(t press_enter)"
                ;;
            3)
                print_message "INFO" "$(t src_rw_db_user_prompt)"
                read -rp "    $(t input_prompt)" input_db_user
                DB_USER="${input_db_user:-postgres}"
                save_config
                print_message "SUCCESS" "$(t config_saved)"
                read -rp "$(t press_enter)"
                ;;
            0) break ;;
            *) print_message "ERROR" "$(t invalid_input)" ; sleep 1 ;;
        esac
    done
}

configure_source_shm() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}$(t src_shm_title)${RESET}"
        echo ""

        local shm_status
        if [[ "$SHM_ENABLED" == "true" ]]; then
            shm_status="${GREEN}$(t src_enabled)${RESET}"
        else
            shm_status="${RED}$(t src_disabled)${RESET}"
        fi
        print_message "INFO" "$(t src_enabled)/$(t src_disabled): ${shm_status}"
        print_message "INFO" "$(t src_shm_current_path) ${BOLD}${SHM_ROOT_DIR:-$(t not_set)}${RESET}"
        echo ""

        if [[ "$SHM_ENABLED" == "true" ]]; then
            echo "   1. $(t src_shm_disable)"
        else
            echo "   1. $(t src_shm_enable)"
        fi
        echo "   2. $(t src_shm_change_path)"
        echo ""
        echo "   0. $(t back)"
        echo ""

        read -rp "${GREEN}[?]${RESET} $(t select_option)" choice
        echo ""
        case $choice in
            1)
                if [[ "$SHM_ENABLED" == "true" ]]; then
                    SHM_ENABLED="false"
                else
                    SHM_ENABLED="true"
                fi
                save_config
                print_message "SUCCESS" "$(t config_saved)"
                read -rp "$(t press_enter)"
                ;;
            2)
                print_message "ACTION" "$(t cfg_where_shm)"
                echo " 1. /opt/shm"
                echo " 2. /root/shm"
                echo " 3. /opt/stacks/shm"
                echo " 4. $(t custom_path)"
                echo ""
                local shm_path_choice
                while true; do
                    read -rp " ${GREEN}[?]${RESET} $(t select_variant)" shm_path_choice
                    case "$shm_path_choice" in
                    1) SHM_ROOT_DIR="/opt/shm"; break ;;
                    2) SHM_ROOT_DIR="/root/shm"; break ;;
                    3) SHM_ROOT_DIR="/opt/stacks/shm"; break ;;
                    4)
                        echo ""
                        print_message "INFO" "$(t cfg_enter_shm_path)"
                        read -rp " $(t path_prompt)" custom_shm_input
                        if [[ -z "$custom_shm_input" ]]; then
                            print_message "ERROR" "$(t cfg_path_empty)"; echo ""; read -rp "$(t press_enter)"; continue
                        fi
                        if [[ ! "$custom_shm_input" = /* ]]; then
                            print_message "ERROR" "$(t cfg_path_abs)"; echo ""; read -rp "$(t press_enter)"; continue
                        fi
                        custom_shm_input="${custom_shm_input%/}"
                        if [[ ! -d "$custom_shm_input" ]]; then
                            print_message "WARN" "$(t cfg_dir_missing) ${BOLD}${custom_shm_input}${RESET}"
                            read -rp "$(echo -e "${GREEN}[?]${RESET} $(t cfg_continue_path) ${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}: ")" _confirm
                            if [[ "$_confirm" != "y" ]]; then echo ""; read -rp "$(t press_enter)"; continue; fi
                        fi
                        SHM_ROOT_DIR="$custom_shm_input"
                        print_message "SUCCESS" "$(t cfg_custom_set) ${BOLD}${SHM_ROOT_DIR}${RESET}"
                        break
                        ;;
                    *) print_message "ERROR" "$(t invalid_input)" ;;
                    esac
                done
                save_config
                print_message "SUCCESS" "$(t config_saved)"
                read -rp "$(t press_enter)"
                ;;
            0) break ;;
            *) print_message "ERROR" "$(t invalid_input)" ; sleep 1 ;;
        esac
    done
}

configure_sources() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}$(t src_title)${RESET}"
        echo ""

        local rw_status shm_status
        if [[ "$REMNAWAVE_ENABLED" == "true" ]]; then
            rw_status="${GREEN}$(t src_enabled)${RESET}"
        else
            rw_status="${RED}$(t src_disabled)${RESET}"
        fi
        if [[ "$SHM_ENABLED" == "true" ]]; then
            shm_status="${GREEN}$(t src_enabled)${RESET}"
        else
            shm_status="${RED}$(t src_disabled)${RESET}"
        fi

        echo -e "   1. $(t src_remnawave) — ${rw_status}"
        echo -e "   2. $(t src_shm) — ${shm_status}"
        echo ""
        echo "   0. $(t back_to_menu)"
        echo ""

        read -rp "${GREEN}[?]${RESET} $(t select_option)" choice
        echo ""
        case $choice in
            1) configure_source_remnawave ;;
            2) configure_source_shm ;;
            0) break ;;
            *) print_message "ERROR" "$(t invalid_input)" ; sleep 1 ;;
        esac
    done
}

configure_settings() {
    while true; do
        clear
        echo -e "${GREEN}${BOLD}$(t st_title)${RESET}"
        echo ""
        echo "   1. $(t st_tg_settings)"
        echo "   2. $(t st_gd_settings)"
        echo "   3. $(t st_s3_settings)"
        echo "   4. $(t st_db_settings)"
        echo "   5. $(t st_retention_settings)"
        echo "   6. $(t st_lang)"
        echo "   7. $(t st_auto_update)"
        echo ""
        echo "   0. $(t back_to_menu)"
        echo ""
        read -rp "${GREEN}[?]${RESET} $(t select_option)" choice
        echo ""

        case $choice in
            1)
                while true; do
                    clear
                    echo -e "${GREEN}${BOLD}$(t st_tg_title)${RESET}"
                    echo ""
                    print_message "INFO" "$(t st_tg_token) ${BOLD}${BOT_TOKEN}${RESET}"
                    print_message "INFO" "$(t st_tg_chatid) ${BOLD}${CHAT_ID}${RESET}"
                    print_message "INFO" "$(t st_tg_thread) ${BOLD}${TG_MESSAGE_THREAD_ID:-$(t not_set)}${RESET}"
                    print_message "INFO" "$(t st_tg_proxy) ${BOLD}${TG_PROXY:-$(t not_set)}${RESET}"
                    echo ""
                    echo ""
                    echo "   1. $(t st_tg_change_token)"
                    echo "   2. $(t st_tg_change_id)"
                    echo "   3. $(t st_tg_change_thread)"
                    echo "   4. $(t st_tg_change_proxy)"
                    echo ""
                    echo "   0. $(t back)"
                    echo ""
                    read -rp "${GREEN}[?]${RESET} $(t select_option)" telegram_choice
                    echo ""

                    case $telegram_choice in
                        1)
                            print_message "INFO" "$(t cfg_create_bot)"
                            read -rp "   $(t st_tg_enter_token)" NEW_BOT_TOKEN
                            BOT_TOKEN="$NEW_BOT_TOKEN"
                            save_config
                            print_message "SUCCESS" "$(t st_tg_token_ok)"
                            ;;
                        2)
                            print_message "INFO" "$(t st_tg_chatid_desc)"
                            echo -e "       $(t cfg_chatid_help)"
                            read -rp "   $(t st_tg_enter_id)" NEW_CHAT_ID
                            CHAT_ID="$NEW_CHAT_ID"
                            save_config
                            print_message "SUCCESS" "$(t st_tg_id_ok)"
                            ;;
                        3)
                            print_message "INFO" "$(t st_tg_thread_info)"
                            echo -e "       $(t cfg_thread_empty)"
                            read -rp "   $(t st_tg_enter_thread)" NEW_TG_MESSAGE_THREAD_ID
                            TG_MESSAGE_THREAD_ID="$NEW_TG_MESSAGE_THREAD_ID"
                            save_config
                            print_message "SUCCESS" "$(t st_tg_thread_ok)"
                            ;;
                        4)
                            print_message "INFO" "$(t st_tg_proxy_info)"
                            print_message "INFO" "$(t st_tg_proxy_examples)"
                            echo ""
                            read -rp "   $(t st_tg_enter_proxy)" NEW_TG_PROXY
                            TG_PROXY="$NEW_TG_PROXY"
                            save_config
                            if [[ -n "$TG_PROXY" ]]; then
                                print_message "SUCCESS" "$(t st_tg_proxy_ok)"
                            else
                                print_message "SUCCESS" "$(t st_tg_proxy_cleared)"
                            fi
                            ;;
                        0) break ;;
                        *) print_message "ERROR" "$(t invalid_input_select)" ;;
                    esac
                    echo ""
                    read -rp "$(t press_enter)"
                done
                ;;

            2)
                while true; do
                    clear
                    echo -e "${GREEN}${BOLD}$(t st_gd_title)${RESET}"
                    echo ""
                    print_message "INFO" "$(t st_gd_client_id) ${BOLD}${GD_CLIENT_ID:0:8}...${RESET}"
                    print_message "INFO" "$(t st_gd_secret) ${BOLD}${GD_CLIENT_SECRET:0:8}...${RESET}"
                    print_message "INFO" "$(t st_gd_refresh) ${BOLD}${GD_REFRESH_TOKEN:0:8}...${RESET}"
                    print_message "INFO" "$(t st_gd_folder) ${BOLD}${GD_FOLDER_ID:-$(t root_folder)}${RESET}"
                    echo ""
                    echo "   1. $(t st_gd_change_id)"
                    echo "   2. $(t st_gd_change_secret)"
                    echo "   3. $(t st_gd_change_refresh)"
                    echo "   4. $(t st_gd_change_folder)"
                    echo ""
                    echo "   0. $(t back)"
                    echo ""
                    read -rp "${GREEN}[?]${RESET} $(t select_option)" gd_choice
                    echo ""

                    case $gd_choice in
                        1)
                            echo "$(t st_gd_no_tokens)"
                            local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
                            print_message "LINK" "$(t cfg_gd_guide) ${CYAN}${guide_url}${RESET}"
                            read -rp "   $(t st_gd_enter_id)" NEW_GD_CLIENT_ID
                            GD_CLIENT_ID="$NEW_GD_CLIENT_ID"
                            save_config
                            print_message "SUCCESS" "$(t st_gd_id_ok)"
                            ;;
                        2)
                            echo "$(t st_gd_no_tokens)"
                            local guide_url="https://telegra.ph/Nastrojka-Google-API-06-02"
                            print_message "LINK" "$(t cfg_gd_guide) ${CYAN}${guide_url}${RESET}"
                            read -rp "   $(t st_gd_enter_secret)" NEW_GD_CLIENT_SECRET
                            GD_CLIENT_SECRET="$NEW_GD_CLIENT_SECRET"
                            save_config
                            print_message "SUCCESS" "$(t st_gd_secret_ok)"
                            ;;
                        3)
                            clear
                            print_message "WARN" "$(t st_gd_auth_needed)"
                            print_message "INFO" "$(t cfg_gd_open_url)"
                            echo ""
                            local auth_url="https://accounts.google.com/o/oauth2/auth?client_id=${GD_CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=https://www.googleapis.com/auth/drive&response_type=code&access_type=offline"
                            print_message "LINK" "${CYAN}${auth_url}${RESET}"
                            echo ""
                            read -rp "$(t st_gd_enter_code)" AUTH_CODE
                            
                            print_message "INFO" "$(t cfg_gd_getting)"
                            local token_response=$(curl -s -X POST https://oauth2.googleapis.com/token \
                                -d client_id="$GD_CLIENT_ID" \
                                -d client_secret="$GD_CLIENT_SECRET" \
                                -d code="$AUTH_CODE" \
                                -d redirect_uri="urn:ietf:wg:oauth:2.0:oob" \
                                -d grant_type="authorization_code")
                            
                            NEW_GD_REFRESH_TOKEN=$(echo "$token_response" | jq -r .refresh_token 2>/dev/null)
                            
                            if [[ -z "$NEW_GD_REFRESH_TOKEN" || "$NEW_GD_REFRESH_TOKEN" == "null" ]]; then
                                print_message "ERROR" "$(t st_gd_fail)"
                                print_message "WARN" "$(t st_gd_not_done)"
                            else
                                GD_REFRESH_TOKEN="$NEW_GD_REFRESH_TOKEN"
                                save_config
                                print_message "SUCCESS" "$(t st_gd_token_ok)"
                            fi
                            ;;
                        4)
                            echo
                            echo "   $(t cfg_gd_folder1)"
                            echo "   $(t cfg_gd_folder2)"
                            echo "   $(t cfg_gd_folder3)"
                            echo "      https://drive.google.com/drive/folders/1a2B3cD4eFmNOPqRstuVwxYz"
                            echo "   $(t cfg_gd_folder4)"
                            echo "   $(t cfg_gd_folder5)"
                            echo
                            read -rp "   $(t st_gd_enter_folder)" NEW_GD_FOLDER_ID
                            GD_FOLDER_ID="$NEW_GD_FOLDER_ID"
                            save_config
                            print_message "SUCCESS" "$(t st_gd_folder_ok)"
                            ;;
                        0) break ;;
                        *) print_message "ERROR" "$(t invalid_input_select)" ;;
                    esac
                    echo ""
                    read -rp "$(t press_enter)"
                done
                ;;

            3)
                while true; do
                    clear
                    echo -e "${GREEN}${BOLD}$(t st_s3_title)${RESET}"
                    echo ""
                    print_message "INFO" "$(t st_s3_endpoint) ${BOLD}${S3_ENDPOINT:-$(t not_set)}${RESET}"
                    print_message "INFO" "$(t st_s3_region) ${BOLD}${S3_REGION:-$(t not_set)}${RESET}"
                    print_message "INFO" "$(t st_s3_bucket) ${BOLD}${S3_BUCKET:-$(t not_set)}${RESET}"
                    print_message "INFO" "$(t st_s3_access) ${BOLD}${S3_ACCESS_KEY:+****${S3_ACCESS_KEY: -4}}${RESET}"
                    print_message "INFO" "$(t st_s3_secret) ${BOLD}${S3_SECRET_KEY:+****}${RESET}"
                    print_message "INFO" "$(t st_s3_prefix) ${BOLD}${S3_PREFIX:-$(t root_folder)}${RESET}"
                    echo ""
                    echo "   1. $(t st_s3_change_endpoint)"
                    echo "   2. $(t st_s3_change_region)"
                    echo "   3. $(t st_s3_change_bucket)"
                    echo "   4. $(t st_s3_change_access)"
                    echo "   5. $(t st_s3_change_secret)"
                    echo "   6. $(t st_s3_change_prefix)"
                    echo "   7. $(t st_s3_test)"
                    echo ""
                    echo "   0. $(t back)"
                    echo ""
                    read -rp "${GREEN}[?]${RESET} $(t select_option)" s3_choice
                    echo ""

                    case $s3_choice in
                        1)
                            read -rp "   $(t st_s3_enter_endpoint)" NEW_S3_ENDPOINT
                            S3_ENDPOINT="$NEW_S3_ENDPOINT"
                            save_config
                            print_message "SUCCESS" "$(t st_s3_endpoint_ok)"
                            ;;
                        2)
                            read -rp "   $(t st_s3_enter_region)" NEW_S3_REGION
                            S3_REGION="${NEW_S3_REGION:-us-east-1}"
                            save_config
                            print_message "SUCCESS" "$(t st_s3_region_ok)"
                            ;;
                        3)
                            read -rp "   $(t st_s3_enter_bucket)" NEW_S3_BUCKET
                            S3_BUCKET="$NEW_S3_BUCKET"
                            save_config
                            print_message "SUCCESS" "$(t st_s3_bucket_ok)"
                            ;;
                        4)
                            read -rp "   $(t st_s3_enter_access)" NEW_S3_ACCESS_KEY
                            S3_ACCESS_KEY="$NEW_S3_ACCESS_KEY"
                            save_config
                            print_message "SUCCESS" "$(t st_s3_access_ok)"
                            ;;
                        5)
                            read -rp "   $(t st_s3_enter_secret)" NEW_S3_SECRET_KEY
                            S3_SECRET_KEY="$NEW_S3_SECRET_KEY"
                            save_config
                            print_message "SUCCESS" "$(t st_s3_secret_ok)"
                            ;;
                        6)
                            echo "   $(t ul_s3_prefix_info1)"
                            echo "   $(t ul_s3_prefix_info2)"
                            read -rp "   $(t st_s3_enter_prefix)" NEW_S3_PREFIX
                            S3_PREFIX="$NEW_S3_PREFIX"
                            save_config
                            print_message "SUCCESS" "$(t st_s3_prefix_ok)"
                            ;;
                        7)
                            if [[ -z "$S3_BUCKET" || -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
                                print_message "ERROR" "$(t st_s3_test_missing)"
                            else
                                print_message "INFO" "$(t st_s3_testing)"
                                if install_aws_cli; then
                                    local s3_test_endpoint=""
                                    if [[ -n "$S3_ENDPOINT" ]]; then
                                        s3_test_endpoint="--endpoint-url $S3_ENDPOINT"
                                    fi
                                    local test_prefix="${S3_PREFIX:+${S3_PREFIX}/}"
                                    if AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
                                       AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
                                       AWS_DEFAULT_REGION="$S3_REGION" \
                                       aws s3 ls "s3://${S3_BUCKET}/${test_prefix}" \
                                       $s3_test_endpoint >/dev/null 2>&1; then
                                        print_message "SUCCESS" "$(t st_s3_test_ok)"
                                    else
                                        print_message "ERROR" "$(t st_s3_test_fail)"
                                    fi
                                fi
                            fi
                            ;;
                        0) break ;;
                        *) print_message "ERROR" "$(t invalid_input_select)" ;;
                    esac
                    echo ""
                    read -rp "$(t press_enter)"
                done
                ;;

            4)
                while true; do
                    clear
                    echo -e "${GREEN}${BOLD}$(t st_db_title)${RESET}"
                    echo ""
                    if [[ "$DB_CONNECTION_TYPE" == "external" ]]; then
                        print_message "INFO" "$(t st_db_type) ${BOLD}${GREEN}$(t st_db_type_ext)${RESET}"
                        print_message "INFO" "$(t st_db_host_label) ${BOLD}${DB_HOST:-$(t not_set)}${RESET}"
                        print_message "INFO" "$(t st_db_port_label) ${BOLD}${DB_PORT}${RESET}"
                        print_message "INFO" "$(t st_db_user_label) ${BOLD}${DB_USER}${RESET}"
                        print_message "INFO" "$(t st_db_name_label) ${BOLD}${DB_NAME}${RESET}"
                        print_message "INFO" "$(t st_db_ssl_label) ${BOLD}${DB_SSL_MODE}${RESET}"
                        print_message "INFO" "$(t st_db_pgver_label) ${BOLD}${DB_POSTGRES_VERSION}${RESET}"
                    else
                        print_message "INFO" "$(t st_db_type) ${BOLD}${GREEN}$(t st_db_type_docker)${RESET} (remnawave-db)"
                        print_message "INFO" "$(t st_db_user_label) ${BOLD}${DB_USER}${RESET}"
                    fi
                    echo ""
                    echo "   1. $(t st_db_change_type)"
                    echo "   2. $(t st_db_change_user)"
                    if [[ "$DB_CONNECTION_TYPE" == "external" ]]; then
                        echo "   3. $(t st_db_ext_settings)"
                        echo "   4. $(t st_db_test)"
                    fi
                    echo ""
                    echo "   0. $(t back)"
                    echo ""
                    read -rp "${GREEN}[?]${RESET} $(t select_option)" db_choice
                    echo ""

                    case $db_choice in
                        1)
                            echo "$(t st_db_select_type)"
                            echo " 1. $(t st_db_docker)"
                            echo " 2. $(t st_db_external)"
                            echo ""
                            read -rp " ${GREEN}[?]${RESET} $(t your_choice)" conn_type_choice
                            case "$conn_type_choice" in
                                1)
                                    DB_CONNECTION_TYPE="docker"
                                    save_config
                                    print_message "SUCCESS" "$(t st_db_switched_docker)"
                                    ;;
                                2)
                                    DB_CONNECTION_TYPE="external"
                                    if [[ -z "$DB_HOST" ]]; then
                                        echo ""
                                        print_message "ACTION" "$(t st_db_need_ext_params)"
                                        echo ""
                                        read -rp "   $(t rs_host)" DB_HOST
                                        read -rp "   $(t rs_port)" input_db_port
                                        DB_PORT="${input_db_port:-5432}"
                                        read -rp "   $(t rs_dbname)" input_db_name
                                        DB_NAME="${input_db_name:-postgres}"
                                        read -rsp "   $(t rs_pass)" DB_PASSWORD
                                        echo ""
                                        read -rp "   $(t rs_ssl)" input_ssl
                                        DB_SSL_MODE="${input_ssl:-prefer}"
                                        read -rp "   $(t rs_pgver)" input_pg_ver
                                        DB_POSTGRES_VERSION="${input_pg_ver:-17}"
                                    fi
                                    save_config
                                    print_message "SUCCESS" "$(t st_db_switched_ext)"
                                    ;;
                                *)
                                    print_message "ERROR" "$(t invalid_input)"
                                    ;;
                            esac
                            ;;
                        2)
                            print_message "INFO" "$(t st_db_user_label) ${BOLD}${DB_USER}${RESET}"
                            echo ""
                            read -rp "   $(printf "$(t st_db_enter_user)" "$DB_USER")" NEW_DB_USER
                            DB_USER="${NEW_DB_USER:-postgres}"
                            save_config
                            print_message "SUCCESS" "$(t st_db_user_ok) ${BOLD}${DB_USER}${RESET}."
                            ;;
                        3)
                            if [[ "$DB_CONNECTION_TYPE" != "external" ]]; then
                                print_message "ERROR" "$(t invalid_input)"
                            else
                                clear
                                echo -e "${GREEN}${BOLD}$(t st_db_ext_settings)${RESET}"
                                echo ""
                                print_message "INFO" "$(t st_db_host_label) ${BOLD}${DB_HOST:-$(t not_set)}${RESET}"
                                print_message "INFO" "$(t st_db_port_label) ${BOLD}${DB_PORT}${RESET}"
                                print_message "INFO" "$(t st_db_name_label) ${BOLD}${DB_NAME}${RESET}"
                                print_message "INFO" "$(t st_db_ssl_label) ${BOLD}${DB_SSL_MODE}${RESET}"
                                print_message "INFO" "$(t st_db_pgver_label) ${BOLD}${DB_POSTGRES_VERSION}${RESET}"
                                echo ""
                                read -rp "   $(printf "$(t st_db_enter_host)" "$DB_HOST")" new_host
                                [[ -n "$new_host" ]] && DB_HOST="$new_host"
                                read -rp "   $(printf "$(t st_db_enter_port)" "$DB_PORT")" new_port
                                [[ -n "$new_port" ]] && DB_PORT="$new_port"
                                read -rp "   $(printf "$(t st_db_enter_name)" "$DB_NAME")" new_dbname
                                [[ -n "$new_dbname" ]] && DB_NAME="$new_dbname"
                                read -rsp "   $(t st_db_enter_pass)" new_pass
                                echo ""
                                [[ -n "$new_pass" ]] && DB_PASSWORD="$new_pass"
                                read -rp "   $(printf "$(t st_db_enter_ssl)" "$DB_SSL_MODE")" new_ssl
                                [[ -n "$new_ssl" ]] && DB_SSL_MODE="$new_ssl"
                                read -rp "   $(printf "$(t st_db_enter_pgver)" "$DB_POSTGRES_VERSION")" new_pgver
                                [[ -n "$new_pgver" ]] && DB_POSTGRES_VERSION="$new_pgver"
                                
                                save_config
                                print_message "SUCCESS" "$(t st_db_ext_saved)"
                            fi
                            ;;
                        4)
                            if [[ "$DB_CONNECTION_TYPE" != "external" ]]; then
                                print_message "ERROR" "$(t st_db_only_ext)"
                            else
                                print_message "INFO" "$(t st_db_testing) ${BOLD}${DB_HOST}:${DB_PORT}${RESET}..."
                                local pg_image=$(get_postgres_image)
                                
                                if docker run --rm --network host \
                                    -e PGPASSWORD="$DB_PASSWORD" \
                                    -e PGSSLMODE="$DB_SSL_MODE" \
                                    "$pg_image" \
                                    pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" 2>/dev/null; then
                                    print_message "SUCCESS" "$(t st_db_test_ok)"
                                else
                                    print_message "ERROR" "$(t st_db_test_fail)"
                                fi
                            fi
                            ;;
                        0) break ;;
                        *) print_message "ERROR" "$(t invalid_input)" ;;
                    esac
                    echo ""
                    read -rp "$(t press_enter)"
                done
                ;;

            5)
                clear
                echo -e "${GREEN}${BOLD}$(t st_retention_title)${RESET}"
                echo ""
                print_message "INFO" "$(t st_retention_local) ${BOLD}${RETAIN_BACKUPS_DAYS}${RESET} $(t st_retention_days)"
                print_message "INFO" "$(t st_retention_s3) ${BOLD}${S3_RETAIN_DAYS}${RESET} $(t st_retention_days)"
                echo ""
                echo "   1. $(t st_retention_change_local)"
                echo "   2. $(t st_retention_change_s3)"
                echo ""
                echo "   0. $(t back)"
                echo ""
                read -rp "${GREEN}[?]${RESET} $(t select_option)" ret_choice
                echo ""

                case $ret_choice in
                    1)
                        read -rp "   $(printf "$(t st_retention_enter_local)" "$RETAIN_BACKUPS_DAYS")" new_local_ret
                        RETAIN_BACKUPS_DAYS="${new_local_ret:-$RETAIN_BACKUPS_DAYS}"
                        save_config
                        print_message "SUCCESS" "$(t st_retention_local_ok) ${BOLD}${RETAIN_BACKUPS_DAYS}${RESET} $(t st_retention_days)"
                        ;;
                    2)
                        read -rp "   $(printf "$(t st_retention_enter_s3)" "$S3_RETAIN_DAYS")" new_s3_ret
                        S3_RETAIN_DAYS="${new_s3_ret:-$S3_RETAIN_DAYS}"
                        save_config
                        print_message "SUCCESS" "$(t st_retention_s3_ok) ${BOLD}${S3_RETAIN_DAYS}${RESET} $(t st_retention_days)"
                        ;;
                    0) ;;
                    *) print_message "ERROR" "$(t invalid_input_select)" ;;
                esac
                echo ""
                read -rp "$(t press_enter)"
                ;;

            6)
                clear
                echo -e "${GREEN}${BOLD}$(t st_lang)${RESET}"
                echo ""
                print_message "INFO" "$(t st_lang_current) ${BOLD}${LANG_CODE}${RESET}"
                echo ""
                select_language_interactive
                save_config
                print_message "SUCCESS" "$(t st_lang_changed) ${BOLD}${LANG_CODE}${RESET}"
                echo ""
                read -rp "$(t press_enter)"
                ;;

            7)
                clear
                echo -e "${GREEN}${BOLD}$(t st_auto_update)${RESET}"
                echo ""
                if [[ "$AUTO_UPDATE" == "true" ]]; then
                    print_message "INFO" "$(t st_auto_update_status) ${BOLD}${GREEN}$(t st_auto_update_on)${RESET}"
                else
                    print_message "INFO" "$(t st_auto_update_status) ${BOLD}${RED}$(t st_auto_update_off)${RESET}"
                fi
                echo ""
                echo "   1. $(t st_auto_update_enable)"
                echo "   2. $(t st_auto_update_disable)"
                echo ""
                echo "   0. $(t back)"
                echo ""
                read -rp "${GREEN}[?]${RESET} $(t select_option)" auto_upd_choice
                echo ""
                case $auto_upd_choice in
                    1)
                        AUTO_UPDATE="true"
                        save_config
                        print_message "SUCCESS" "$(t st_auto_update_enabled)"
                        ;;
                    2)
                        AUTO_UPDATE="false"
                        save_config
                        print_message "SUCCESS" "$(t st_auto_update_disabled)"
                        ;;
                    0) ;;
                    *) print_message "ERROR" "$(t invalid_input_select)" ;;
                esac
                echo ""
                read -rp "$(t press_enter)"
                ;;

            0) break ;;
            *) print_message "ERROR" "$(t invalid_input_select)" ;;
        esac
        echo ""
    done
}

check_update_status() {
    local TEMP_REMOTE_VERSION_FILE
    TEMP_REMOTE_VERSION_FILE=$(mktemp)

    if ! curl -fsSL "$SCRIPT_REPO_URL" 2>/dev/null | head -n 100 > "$TEMP_REMOTE_VERSION_FILE"; then
        UPDATE_AVAILABLE=false
        rm -f "$TEMP_REMOTE_VERSION_FILE"
        return
    fi

    local REMOTE_VERSION
    REMOTE_VERSION=$(grep -m 1 "^VERSION=" "$TEMP_REMOTE_VERSION_FILE" | cut -d'"' -f2)
    rm -f "$TEMP_REMOTE_VERSION_FILE"

    if [[ -z "$REMOTE_VERSION" ]]; then
        UPDATE_AVAILABLE=false
        return
    fi

    if compare_versions "$VERSION" "$REMOTE_VERSION"; then
        UPDATE_AVAILABLE=true
    else
        UPDATE_AVAILABLE=false
    fi
}

main_menu() {
    while true; do
        check_update_status
        clear
        echo -e "${GREEN}${BOLD}$(t menu_title)${RESET} "
        if [[ "$UPDATE_AVAILABLE" == true ]]; then
            echo -e "${BOLD}${LIGHT_GRAY}$(t menu_version) ${VERSION} ${RED}$(t menu_update_avail)${RESET}"
        else
            echo -e "${BOLD}${LIGHT_GRAY}$(t menu_version) ${VERSION}${RESET}"
        fi
        
        local _rw_badge _shm_badge
        if [[ "$REMNAWAVE_ENABLED" == "true" ]]; then
            _rw_badge="${GREEN}[$(t src_remnawave) ✓]${RESET}"
        else
            _rw_badge="${LIGHT_GRAY}[$(t src_remnawave) ✗]${RESET}"
        fi
        if [[ "$SHM_ENABLED" == "true" ]]; then
            _shm_badge="${GREEN}[$(t src_shm) ✓]${RESET}"
        else
            _shm_badge="${LIGHT_GRAY}[$(t src_shm) ✗]${RESET}"
        fi
        echo -e "${_rw_badge} ${_shm_badge}"

        echo ""
        echo "   1. $(t menu_create_backup)"
        echo "   2. $(t menu_restore)"
        echo ""
        echo "   3. $(t menu_sources)"
        echo "   4. $(t menu_auto_send)"
        echo "   5. $(t menu_upload_method)"
        echo "   6. $(t menu_settings)"
        echo ""
        echo "   7. $(t menu_update)"
        echo "   8. $(t menu_remove)"
        echo ""
        echo "   0. $(t exit)"
        echo -e "   —  $(t menu_shortcut)"
        echo ""

        read -rp "${GREEN}[?]${RESET} $(t select_option)" choice
        echo ""
        case $choice in
            1) create_backup ; read -rp "$(t press_enter)" ;;
            2) restore_backup ;;
            3) configure_sources ;;
            4) setup_auto_send ;;
            5) configure_upload_method ;;
            6) configure_settings ;;
            7) update_script ;;
            8) remove_script ;;
            0) echo "$(t exit_dots)"; exit 0 ;;
            *) print_message "ERROR" "$(t invalid_input_select)" ; read -rp "$(t press_enter)" ;;
        esac
    done
}

if ! command -v jq &> /dev/null; then
    print_message "INFO" "$(t jq_installing)"
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ $(t jq_root)${RESET}"
        exit 1
    fi
    if command -v apt-get &> /dev/null; then
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y jq > /dev/null 2>&1 || { echo -e "${RED}❌ $(t jq_fail)${RESET}"; exit 1; }
        print_message "SUCCESS" "$(t jq_installed)"
    else
        print_message "ERROR" "$(t jq_no_apt)"
        exit 1
    fi
fi

if [[ -z "$1" ]]; then
    load_or_create_config
    setup_symlink
    main_menu
elif [[ "$1" == "backup" ]]; then
    load_or_create_config
    create_backup
elif [[ "$1" == "restore" ]]; then
    load_or_create_config
    restore_backup
elif [[ "$1" == "update" ]]; then
    load_or_create_config
    update_script
elif [[ "$1" == "remove" ]]; then
    load_or_create_config
    remove_script
else
    echo -e "${RED}❌ $(t jq_bad_usage) ${BOLD}${0} [backup|restore|update|remove]${RESET}${RESET}"
    exit 1
fi
