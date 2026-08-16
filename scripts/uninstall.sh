#!/usr/bin/env bash
#
# Полный откат изменений, сделанных scripts/install.sh и
# scripts/omarchy-disable-autoswitch.sh: удаляет патченный DKMS-модуль
# bitland-mifs-wmi, возвращает штатный in-tree драйвер и восстанавливает
# автопереключение профилей питания omarchy.
#
# Запуск от обычного пользователя (НЕ через sudo целиком - часть шагов
# правит файлы в $HOME и должна идти от пользователя, часть требует
# root и сама вызывает sudo где нужно):
#   bash scripts/uninstall.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$REPO_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall-$(date +%Y%m%d-%H%M%S).log"

PKG_NAME="bitland-mifs-wmi-tm2424"
PKG_VERSION="1.0"
SRC_DIR="/usr/src/${PKG_NAME}-${PKG_VERSION}"
STOCK_MODULE="bitland_mifs_wmi"

UDEV_RULE="/etc/udev/rules.d/99-power-profile.rules"
UDEV_RULE_DISABLED="${UDEV_RULE}.disabled-by-fullspeed-fix"
SHIM_DIR="$HOME/.local/bin/fullspeed-fix-shims"
UWSM_ENV="$HOME/.config/uwsm/env"
SHIM_MARKER_BEGIN="# --- fullspeed-fix: no-op shim for omarchy-powerprofiles-init ---"
SHIM_MARKER_END="# --- end fullspeed-fix shim ---"

mkdir -p "$LOG_DIR"

log() {
	echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Проверка «модуль загружен?» БЕЗ пайпа lsmod|grep: с set -o pipefail
# grep -q выходит после первого совпадения, lsmod ловит SIGPIPE (rc=141)
# и весь пайплайн считается проваленным, хотя совпадение было.
is_loaded() {
	grep -q "^$1 " /proc/modules
}

main() {
	log "=== Откат Full-speed фикса ==="

	if [[ $EUID -eq 0 ]]; then
		log "ВНИМАНИЕ: скрипт запущен через sudo/от root целиком - правки \$HOME (uwsm/env, shim) применятся к root, а не к твоему пользователю. Запусти без sudo: bash scripts/uninstall.sh"
	fi

	if command -v omarchy >/dev/null 2>&1; then
		log "Создаю снапшот omarchy перед откатом..."
		omarchy snapshot create 2>&1 | tee -a "$LOG_FILE" || log "Предупреждение: снапшот не создан, продолжаю без него"
	fi

	# --- DKMS + модуль (требует root, вызываем sudo точечно) ---
	if command -v dkms >/dev/null 2>&1 && [[ "$(sudo dkms status -m "$PKG_NAME" 2>/dev/null)" == *"$PKG_NAME"* ]]; then
		log "Удаляю DKMS-модуль $PKG_NAME..."
		sudo dkms remove -m "$PKG_NAME" -v "$PKG_VERSION" --all 2>&1 | tee -a "$LOG_FILE"
	else
		log "DKMS-модуль $PKG_NAME не найден - пропускаю"
	fi
	sudo rm -rf "$SRC_DIR"

	if is_loaded mifs_probe; then
		log "Выгружаю оставшийся mifs_probe..."
		sudo rmmod mifs_probe 2>&1 | tee -a "$LOG_FILE"
	fi

	if is_loaded "$STOCK_MODULE"; then
		log "Выгружаю текущий $STOCK_MODULE..."
		sudo rmmod "$STOCK_MODULE" 2>&1 | tee -a "$LOG_FILE"
	fi
	sudo depmod -a
	log "Загружаю штатный in-tree $STOCK_MODULE..."
	sudo modprobe "$STOCK_MODULE" 2>&1 | tee -a "$LOG_FILE"

	MODULE_PATH=$(modinfo -n "$STOCK_MODULE" 2>/dev/null)
	log "Активный путь модуля после отката: $MODULE_PATH"

	# --- udev-правило (требует root) ---
	if [[ -f $UDEV_RULE_DISABLED ]]; then
		log "Восстанавливаю udev-правило $UDEV_RULE..."
		sudo mv "$UDEV_RULE_DISABLED" "$UDEV_RULE"
		sudo udevadm control --reload-rules 2>&1 | tee -a "$LOG_FILE"
	else
		log "$UDEV_RULE_DISABLED не найден - нечего восстанавливать (либо не применялось, либо уже восстановлено)"
	fi

	# --- shim + uwsm/env (пользовательские файлы, без sudo) ---
	if [[ -f $UWSM_ENV ]] && grep -qF "$SHIM_MARKER_BEGIN" "$UWSM_ENV"; then
		log "Убираю правку из $UWSM_ENV..."
		awk -v begin="$SHIM_MARKER_BEGIN" -v end="$SHIM_MARKER_END" '
			$0 == begin { skip = 1; next }
			$0 == end { skip = 0; next }
			skip { next }
			{ print }
		' "$UWSM_ENV" > "$UWSM_ENV.tmp" && mv "$UWSM_ENV.tmp" "$UWSM_ENV"
		log "OK: $UWSM_ENV очищен от shim-правки"
	else
		log "$UWSM_ENV не содержит нашей правки - пропускаю"
	fi

	if [[ -d $SHIM_DIR ]]; then
		log "Удаляю shim-директорию $SHIM_DIR..."
		rm -rf "$SHIM_DIR"
	fi

	rm -f "$HOME/.config/omarchy/hooks/post-update.d/ensure-no-power-autoswitch.sh" 2>/dev/null

	log "=== Откат завершён ==="
	log "ВАЖНО: PATH для сессии обновится только после перезапуска Hyprland (перелогин)."
	log "Полный лог: $LOG_FILE"
}

main "$@"
