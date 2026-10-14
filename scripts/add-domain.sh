#!/bin/bash
set -Eeuo pipefail

# The repository root is the parent directory of scripts/.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

AUTO_LIST="$REPO_DIR/auto-proxy.list"
CUSTOM_LIST="$REPO_DIR/custom-proxy.list"

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

# Получаем URL активной вкладки Safari.
URL="${1:-}"

[[ -n "$URL" ]] || die "Не передан URL страницы Safari."

# Извлекаем и проверяем hostname средствами Python.
DOMAIN="$(
    /usr/bin/python3 - "$URL" <<'PY'
import ipaddress
import re
import sys
from urllib.parse import urlsplit

try:
    url = urlsplit(sys.argv[1])

    if url.scheme not in ("http", "https"):
        raise ValueError("поддерживаются только HTTP и HTTPS")

    host = url.hostname
    if not host:
        raise ValueError("в URL отсутствует hostname")

    host = host.rstrip(".").encode("idna").decode("ascii").lower()

    # Не добавляем IP-адреса и localhost в DOMAIN-SUFFIX.
    try:
        ipaddress.ip_address(host)
        raise ValueError("URL содержит IP-адрес, а не домен")
    except ValueError as exc:
        if str(exc).startswith("URL содержит"):
            raise

    if host == "localhost" or "." not in host:
        raise ValueError("это локальное имя хоста")

    labels = host.split(".")
    if any(
        not label
        or len(label) > 63
        or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label)
        for label in labels
    ):
        raise ValueError("некорректное доменное имя")

    # Убираем стандартный префикс www.
    if host.startswith("www."):
        host = host[4:]

    print(host)

except Exception as exc:
    print(f"Некорректный URL: {exc}", file=sys.stderr)
    sys.exit(1)
PY
)" || die "Не удалось определить домен."

[[ -n "$DOMAIN" ]] || die "Получен пустой домен."

cd "$REPO_DIR"

# Убеждаемся, что это Git-репозиторий.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "Каталог не является Git-репозиторием."

# Не смешиваем автоматизацию с посторонними изменениями.
if [[ -n "$(git status --porcelain)" ]]; then
    die "Рабочая копия содержит изменения. Сначала закоммить или убери их."
fi

# Требуем настроенную удалённую ветку.
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' \
    >/dev/null 2>&1 \
    || die "У текущей ветки не настроена upstream-ветка."

# Проверяем наличие файлов.
[[ -f "$CUSTOM_LIST" ]] \
    || die "Не найден custom-proxy.list."

[[ -f "$AUTO_LIST" ]] \
    || die "Не найден auto-proxy.list."

# Проверяем, есть ли уже правило для этого домена.
# Комментарии после # игнорируются.
if /usr/bin/python3 - "$DOMAIN" "$AUTO_LIST" "$CUSTOM_LIST" <<'PY'
import re
import sys

domain = sys.argv[1]
found = False

for filename in sys.argv[2:]:
    with open(filename, encoding="utf-8") as f:
        for line in f:
            rule = line.split("#", 1)[0].strip()
            match = re.match(
                r"^DOMAIN-SUFFIX\s*,\s*([^,\s]+)",
                rule,
                re.IGNORECASE,
            )
            if match and match.group(1).lower().rstrip(".") == domain:
                print(f"Правило уже существует: {domain} ({filename})")
                found = True

sys.exit(0 if found else 1)
PY
then
    exit 0
fi

# Записываем правило с локальной датой и временем.
TIMESTAMP="$(/bin/date '+%d.%m.%Y %H:%M')"
printf 'DOMAIN-SUFFIX,%s # %s\n' "$DOMAIN" "$TIMESTAMP" \
    >> "$AUTO_LIST"

# В коммит попадает только автоматический список.
git add -- auto-proxy.list

git diff --cached --check \
    || die "Обнаружены ошибки форматирования."

git diff --cached --quiet \
    && die "Изменения для коммита отсутствуют."

git commit -m "Add $DOMAIN"

# Публикуем изменения в настроенную upstream-ветку.
git push \
    || die "Push не удался. Локальный коммит сохранён."

printf 'Добавлен %s\n' "$DOMAIN"
printf 'Время: %s\n' "$TIMESTAMP"
printf 'GitHub обновлён. Теперь можно обновить конфиг в Shadowrocket.\n'