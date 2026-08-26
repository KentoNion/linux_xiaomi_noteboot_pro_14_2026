#!/usr/bin/env bash
#
# Удаляет DKMS-модуль bitland-mifs-wmi-tm2424 и возвращает штатный
# in-tree bitland_mifs_wmi.
#
# Запуск: bash scripts/uninstall.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$REPO_DIR/logs"
LOG_FILE="$LOG_DIR/uninstall-$(date +%Y%m%d-%H%M%S).log"

PKG_NAME="bitland-mifs-wmi-tm2424"
PKG_VERSION="1.0"
SRC_DIR="/usr/src/${PKG_NAME}-${PKG_VERSION}"
STOCK_MODULE="bitland_mifs_wmi"

mkdir -p "$LOG_DIR"

log() {
	echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Проверка «модуль загружен?» БЕЗ пайпа lsmod|grep: с set -o pipefail
# grep -q выходит после первого совпадения, lsmod ловит SIGPIPE (rc=141).
is_loaded() {
	grep -q "^$1 " /proc/modules
}

main() {
	log "=== Откат DKMS bitland-mifs-wmi ==="

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
	log "=== Откат завершён ==="
	log "Полный лог: $LOG_FILE"
}

main "$@"
