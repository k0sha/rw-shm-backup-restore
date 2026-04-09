#!/bin/bash
# Tests for backup-restore.sh
# Run: bash test.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/backup-restore.sh"
RU_TRANS="$SCRIPT_DIR/translations/ru.sh"
EN_TRANS="$SCRIPT_DIR/translations/en.sh"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

pass=0; fail=0; warn=0

ok()   { echo -e "${GREEN}  ✓${RESET} $1"; ((pass++)); }
fail() { echo -e "${RED}  ✗${RESET} $1"; ((fail++)); }
warn() { echo -e "${YELLOW}  !${RESET} $1"; ((warn++)); }
section() { echo ""; echo -e "${BOLD}▶ $1${RESET}"; }

# ── 1. Синтаксис ────────────────────────────────────────────────────────────
section "Синтаксис скрипта"

if bash -n "$SCRIPT" 2>/dev/null; then
    ok "backup-restore.sh: синтаксис верный"
else
    fail "backup-restore.sh: ошибка синтаксиса"
    bash -n "$SCRIPT"
fi

if bash -n "$RU_TRANS" 2>/dev/null; then
    ok "translations/ru.sh: синтаксис верный"
else
    fail "translations/ru.sh: ошибка синтаксиса"
fi

if bash -n "$EN_TRANS" 2>/dev/null; then
    ok "translations/en.sh: синтаксис верный"
else
    fail "translations/en.sh: ошибка синтаксиса"
fi

# ── 2. Консистентность переводов ─────────────────────────────────────────────
section "Консистентность переводов ru.sh ↔ en.sh"

ru_keys=$(grep -oE 'L\[[a-z_]+\]' "$RU_TRANS" | sed 's/L\[//;s/\]//' | sort -u)
en_keys=$(grep -oE 'L\[[a-z_]+\]' "$EN_TRANS" | sed 's/L\[//;s/\]//' | sort -u)

ru_count=$(echo "$ru_keys" | wc -l | tr -d ' ')
en_count=$(echo "$en_keys" | wc -l | tr -d ' ')

only_in_ru=$(comm -23 <(echo "$ru_keys") <(echo "$en_keys"))
only_in_en=$(comm -13 <(echo "$ru_keys") <(echo "$en_keys"))

if [[ -z "$only_in_ru" ]]; then
    ok "Все ключи ru.sh присутствуют в en.sh ($ru_count ключей)"
else
    fail "Ключи есть в ru.sh но отсутствуют в en.sh:"
    echo "$only_in_ru" | while read -r k; do echo "      - $k"; done
fi

if [[ -z "$only_in_en" ]]; then
    ok "Все ключи en.sh присутствуют в ru.sh ($en_count ключей)"
else
    fail "Ключи есть в en.sh но отсутствуют в ru.sh:"
    echo "$only_in_en" | while read -r k; do echo "      - $k"; done
fi

# ── 3. Все ключи используемые в скрипте существуют в переводах ───────────────
section "Вызовы \$(t key) → наличие в переводах"

script_keys=$(grep -oE '\$\(t [a-z_]+\)' "$SCRIPT" | sed 's/\$(t //;s/)//' | sort -u)
missing_in_ru=""
missing_in_en=""

while IFS= read -r key; do
    if ! echo "$ru_keys" | grep -qx "$key"; then
        missing_in_ru+="$key"$'\n'
    fi
    if ! echo "$en_keys" | grep -qx "$key"; then
        missing_in_en+="$key"$'\n'
    fi
done <<< "$script_keys"

if [[ -z "$missing_in_ru" ]]; then
    ok "Все $(echo "$script_keys" | wc -l | tr -d ' ') вызовов t() найдены в ru.sh"
else
    fail "Следующие ключи вызываются в скрипте но отсутствуют в ru.sh:"
    echo "$missing_in_ru" | grep -v '^$' | while read -r k; do echo "      - $k"; done
fi

if [[ -z "$missing_in_en" ]]; then
    ok "Все вызовы t() найдены в en.sh"
else
    fail "Следующие ключи вызываются в скрипте но отсутствуют в en.sh:"
    echo "$missing_in_en" | grep -v '^$' | while read -r k; do echo "      - $k"; done
fi

# ── 4. Мёртвые ключи в переводах ─────────────────────────────────────────────
section "Мёртвые ключи в переводах (есть в файлах, не вызываются)"

dead_ru=$(comm -23 <(echo "$ru_keys") <(echo "$script_keys"))
dead_en=$(comm -23 <(echo "$en_keys") <(echo "$script_keys"))

if [[ -z "$dead_ru" ]]; then
    ok "ru.sh: мёртвых ключей нет"
else
    dead_count=$(echo "$dead_ru" | grep -c .)
    warn "ru.sh: $dead_count ключей не используются в скрипте:"
    echo "$dead_ru" | while read -r k; do echo "      - $k"; done
fi

if [[ -z "$dead_en" ]]; then
    ok "en.sh: мёртвых ключей нет"
else
    dead_count=$(echo "$dead_en" | grep -c .)
    warn "en.sh: $dead_count ключей не используются в скрипте:"
    echo "$dead_en" | while read -r k; do echo "      - $k"; done
fi

# ── 5. compare_versions() ────────────────────────────────────────────────────
section "Функция compare_versions()"

# Извлекаем только функцию, без set -e
eval "$(grep -A 30 '^compare_versions()' "$SCRIPT")"

run_ver_test() {
    local v1="$1" op="$2" v2="$3"
    if [[ "$op" == "<" ]]; then
        if compare_versions "$v1" "$v2"; then
            ok "compare_versions: $v1 < $v2"
        else
            fail "compare_versions: ожидалось $v1 < $v2"
        fi
    else
        if ! compare_versions "$v1" "$v2"; then
            ok "compare_versions: $v1 >= $v2"
        else
            fail "compare_versions: ожидалось $v1 >= $v2"
        fi
    fi
}

run_ver_test "3.1.0" "<"  "3.2.0"
run_ver_test "3.2.0" ">=" "3.1.0"
run_ver_test "3.2.0" ">=" "3.2.0"
run_ver_test "2.9.9" "<"  "3.0.0"
run_ver_test "3.2.0" "<"  "3.10.0"
run_ver_test "3.2.0" ">=" "3.2.0"
run_ver_test "1.0.0" "<"  "1.0.1"

# ── 6. escape_markdown_v2() ──────────────────────────────────────────────────
section "Функция escape_markdown_v2()"

eval "$(grep -A 25 '^escape_markdown_v2()' "$SCRIPT")"

check_escape() {
    local input="$1" expected="$2" desc="$3"
    local result
    result=$(escape_markdown_v2 "$input")
    if [[ "$result" == "$expected" ]]; then
        ok "escape: $desc"
    else
        fail "escape: $desc — ожидалось '${expected}', получено '${result}'"
    fi
}

check_escape "hello"     "hello"      "обычный текст без изменений"
check_escape "v3.2.0"    "v3\.2\.0"   "точки экранируются"
check_escape "a_b"       "a\_b"       "подчёркивание экранируется"
check_escape "(test)"    "\(test\)"   "скобки экранируются"
check_escape "[url]"     "\[url\]"    "квадратные скобки экранируются"
check_escape "a*b"       "a*b"        "звёздочка не экранируется (нет в escape_markdown_v2)"

# ── 7. Структура save_config ──────────────────────────────────────────────────
section "Структура save_config() — сохранение переменных"

required_in_config=(
    "BOT_TOKEN"
    "CHAT_ID"
    "DB_USER"
    "UPLOAD_METHOD"
    "RETAIN_BACKUPS_DAYS"
    "REMNALABS_ROOT_DIR"
    "REMNAWAVE_ENABLED"
    "SHM_ENABLED"
    "SHM_ROOT_DIR"
    "LANG_CODE"
    "DB_CONNECTION_TYPE"
    "TG_MESSAGE_THREAD_ID"
    "TG_PROXY"
    "AUTO_UPDATE"
    "CRON_TIMES"
)

save_config_body=$(sed -n '/^save_config()/,/^}/p' "$SCRIPT")

for var in "${required_in_config[@]}"; do
    if echo "$save_config_body" | grep -qF '"$'"$var"'"'; then
        ok "save_config сохраняет $var"
    else
        fail "save_config НЕ сохраняет $var"
    fi
done

# ── 8. Глобальные переменные объявлены ───────────────────────────────────────
section "Объявление глобальных переменных"

global_vars=(
    "REMNAWAVE_ENABLED"
    "SHM_ENABLED"
    "SHM_ROOT_DIR"
    "REMNALABS_ROOT_DIR"
    "UPLOAD_METHOD"
    "RETAIN_BACKUPS_DAYS"
    "S3_RETAIN_DAYS"
    "DB_CONNECTION_TYPE"
    "AUTO_UPDATE"
    "LANG_CODE"
    "TRANSLATIONS_DIR"
    "INSTALL_DIR"
    "BACKUP_DIR"
    "CONFIG_FILE"
    "VERSION"
)

# Берём только первые 80 строк (блок глобальных переменных)
header=$(head -n 80 "$SCRIPT")

for var in "${global_vars[@]}"; do
    if echo "$header" | grep -q "^${var}="; then
        ok "Глобальная переменная $var объявлена"
    else
        warn "Глобальная переменная $var не объявлена в начале скрипта"
    fi
done

# ── 9. Старый код удалён ─────────────────────────────────────────────────────
section "Отсутствие удалённого кода"

deleted_patterns=(
    "BOT_BACKUP_ENABLED"
    "BOT_BACKUP_PATH"
    "BOT_BACKUP_SELECTED"
    "SKIP_PANEL_BACKUP"
    "configure_bot_backup"
    "create_bot_backup"
    "restore_bot_backup"
    "get_bot_params"
    "backup_meta.info"
    "compare_versions_for_check"
    "menu_db_docker"
    "menu_db_ext"
    "src_nothing_warn"
    "tg_only_panel"
    "st_path_settings"
)

for pattern in "${deleted_patterns[@]}"; do
    hits=$(grep -c "$pattern" "$SCRIPT" "$RU_TRANS" "$EN_TRANS" 2>/dev/null | grep -v ':0' | grep -v 'Binary')
    if [[ -z "$hits" ]]; then
        ok "Удалён: $pattern"
    else
        fail "Найден удалённый паттерн: $pattern"
        grep -n "$pattern" "$SCRIPT" "$RU_TRANS" "$EN_TRANS" 2>/dev/null | grep -v ':0'
    fi
done

# ── 10. Новые функции присутствуют ───────────────────────────────────────────
section "Наличие новых функций"

new_functions=(
    "create_shm_backup"
    "restore_shm_backup"
    "configure_source_remnawave"
    "configure_source_shm"
    "configure_sources"
    "send_backup_file"
    "compare_versions"
)

for fn in "${new_functions[@]}"; do
    if grep -q "^${fn}()" "$SCRIPT"; then
        ok "Функция $fn() объявлена"
    else
        fail "Функция $fn() НЕ найдена"
    fi
done

# ── 11. Архивы бэкапа — два отдельных паттерна ───────────────────────────────
section "Двухпроходная архитектура бэкапа"

if grep -q 'remnawave_backup_\${TIMESTAMP}' "$SCRIPT"; then
    ok "Паттерн remnawave_backup_*.tar.gz присутствует"
else
    fail "Паттерн remnawave_backup_*.tar.gz не найден"
fi

if grep -q 'shm_backup_\${TIMESTAMP}' "$SCRIPT"; then
    ok "Паттерн shm_backup_*.tar.gz присутствует"
else
    fail "Паттерн shm_backup_*.tar.gz не найден"
fi

if grep -q 'rw_meta.info' "$SCRIPT"; then
    ok "rw_meta.info используется"
else
    fail "rw_meta.info не найден"
fi

if grep -q 'shm_meta.info' "$SCRIPT"; then
    ok "shm_meta.info используется"
else
    fail "shm_meta.info не найден"
fi

if grep -q 'SOURCE="remnawave"' "$SCRIPT" && grep -q 'SOURCE="shm"' "$SCRIPT"; then
    ok "SOURCE поле записывается в оба мета-файла"
else
    fail "SOURCE поле отсутствует в мета-файлах"
fi

# S3 и local листинг включают оба паттерна
if grep -q 'shm_backup_.*\\\.tar\\\.gz' "$SCRIPT"; then
    ok "S3/local листинг включает shm_backup_*.tar.gz"
else
    fail "S3/local листинг НЕ включает shm_backup_*.tar.gz"
fi

# ── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}${BOLD}PASS: $pass${RESET}  ${RED}${BOLD}FAIL: $fail${RESET}  ${YELLOW}${BOLD}WARN: $warn${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]]
