#!/usr/bin/env bash
#
# Устанавливает патченный bitland-mifs-wmi (TM2424 thin-ultrabook
# perf-mode fix, driver/bitland-mifs-wmi.c) как DKMS-модуль, который
# depmod предпочтёт in-tree версии из ядра. Переживает обновления
# ядра - DKMS пересобирает модуль автоматически через свой pacman-хук.
#
# Запуск: sudo bash scripts/install.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_DIR="$REPO_DIR/driver"
LOG_DIR="$REPO_DIR/logs"
LOG_FILE="$LOG_DIR/install-dkms-$(date +%Y%m%d-%H%M%S).log"

PKG_NAME="bitland-mifs-wmi-tm2424"
PKG_VERSION="1.0"
SRC_DIR="/usr/src/${PKG_NAME}-${PKG_VERSION}"
STOCK_MODULE="bitland_mifs_wmi"

mkdir -p "$LOG_DIR"

log() {
	echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
	log "ОШИБКА: $*"
	exit 1
}

require_root() {
	if [[ $EUID -ne 0 ]]; then
		echo "Нужны права root. Перезапусти: sudo bash $0" >&2
		exit 1
	fi
}

# Проверка «модуль загружен?» БЕЗ пайпа lsmod|grep: с set -o pipefail
# grep -q выходит после первого совпадения, lsmod ловит SIGPIPE (rc=141)
# и весь пайплайн считается проваленным, хотя совпадение было -
# воспроизводится детерминированно. Читаем /proc/modules напрямую.
is_loaded() {
	grep -q "^$1 " /proc/modules
}

# Снапшот omarchy из root-скрипта: omarchy-snapshot внутри зовёт
# omarchy-version (нужен PATH с ~/.local/share/omarchy/bin) и читает
# $OMARCHY_PATH/version - под sudo ни того ни другого нет, поэтому
# явно передаём окружение пользователя, вызвавшего sudo. Сам скрипт
# может работать от root: его внутренний `sudo snapper` от root
# беспарольный.
omarchy_snapshot_create() {
	local home omdir
	if [[ -n ${SUDO_USER:-} ]]; then
		home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
	else
		home="$HOME"
	fi
	omdir="$home/.local/share/omarchy"
	if [[ ! -x "$omdir/bin/omarchy-snapshot" ]]; then
		log "omarchy-snapshot не найден - пропускаю снапшот"
		return 0
	fi
	log "Создаю снапшот omarchy перед вмешательством в систему..."
	OMARCHY_PATH="$omdir" PATH="$omdir/bin:$PATH" \
		"$omdir/bin/omarchy-snapshot" create 2>&1 | tee -a "$LOG_FILE" \
		|| log "Предупреждение: снапшот не создан, продолжаю без него"
}

main() {
	require_root

	log "=== Установка патченного bitland-mifs-wmi через DKMS ==="
	log "Пакет: ${PKG_NAME} v${PKG_VERSION}"

	omarchy_snapshot_create

	if ! command -v dkms >/dev/null 2>&1; then
		die "dkms не установлен. Arch: pacman -S dkms linux-headers; Debian/Ubuntu: apt install dkms linux-headers-\$(uname -r)"
	fi

	if [[ ! -d /lib/modules/$(uname -r)/build ]]; then
		die "нет заголовков ядра для $(uname -r) - поставь linux-headers (или соответствующий -headers для твоего ядра)"
	fi

	# Если пакет уже был установлен раньше (переустановка/апгрейд) - снести
	# старую версию из DKMS. Без пайпа в grep -q (см. is_loaded выше).
	if [[ "$(dkms status -m "$PKG_NAME" -v "$PKG_VERSION" 2>/dev/null)" == *"$PKG_NAME"* ]]; then
		log "Найдена уже установленная версия ${PKG_NAME}/${PKG_VERSION} в DKMS - удаляю перед переустановкой"
		dkms remove -m "$PKG_NAME" -v "$PKG_VERSION" --all 2>&1 | tee -a "$LOG_FILE"
	fi

	log "Копирую исходники в $SRC_DIR"
	rm -rf "$SRC_DIR"
	mkdir -p "$SRC_DIR"
	# Копируем полноценный Makefile (с KDIR/all:), а не голое
	# "obj-m += ...": без явного MAKE[0] в dkms.conf DKMS запускает
	# `make` прямо в исходной директории, а такой минимальный
	# Makefile сам по себе не знает, как собираться против заголовков
	# ядра (нужен именно `make -C $KDIR M=$PWD modules`).
	cp "$DRIVER_DIR/bitland-mifs-wmi.c" "$DRIVER_DIR/dkms.conf" "$DRIVER_DIR/Makefile" "$SRC_DIR/"

	log "dkms add..."
	dkms add "$SRC_DIR" 2>&1 | tee -a "$LOG_FILE" || die "dkms add не удался, смотри $LOG_FILE"

	log "dkms build..."
	dkms build -m "$PKG_NAME" -v "$PKG_VERSION" 2>&1 | tee -a "$LOG_FILE" || die "dkms build не удался, смотри $LOG_FILE"

	log "dkms install..."
	dkms install -m "$PKG_NAME" -v "$PKG_VERSION" 2>&1 | tee -a "$LOG_FILE" || die "dkms install не удался, смотри $LOG_FILE"

	log "Перезагружаю модуль, чтобы подхватить патченную версию..."

	# Если с прошлых экспериментов остался mifs_probe - выгрузить ДО
	# rmmod штатного: незанятый mifs_probe перехватил бы освободившееся
	# WMI-устройство, и патченный драйвер не смог бы забиндиться.
	if is_loaded mifs_probe; then
		log "Выгружаю оставшийся mifs_probe (иначе он перехватит WMI-устройство)"
		rmmod mifs_probe 2>&1 | tee -a "$LOG_FILE"
	fi

	if is_loaded "$STOCK_MODULE"; then
		rmmod "$STOCK_MODULE" 2>&1 | tee -a "$LOG_FILE" || die "не удалось выгрузить текущий $STOCK_MODULE - что-то его держит?"
	fi
	depmod -a
	modprobe "$STOCK_MODULE" 2>&1 | tee -a "$LOG_FILE" || die "modprobe не удался после установки - смотри dmesg"

	sleep 1

	log "--- Проверка ---"
	MODULE_PATH=$(modinfo -n "$STOCK_MODULE" 2>/dev/null)
	log "Путь модуля по depmod: $MODULE_PATH"
	if [[ $MODULE_PATH != *"/updates/dkms/"* ]]; then
		log "ВНИМАНИЕ: depmod резолвит модуль НЕ в /updates/dkms/ - приоритет не подхвачен. Проверь вручную: modinfo $STOCK_MODULE"
	fi

	# modinfo -n говорит лишь, что загрузится в СЛЕДУЮЩИЙ раз. Что
	# работает СЕЙЧАС - сверяем по srcversion работающего модуля.
	RUNNING_SRCV=$(cat "/sys/module/${STOCK_MODULE}/srcversion" 2>/dev/null)
	ONDISK_SRCV=$(modinfo -F srcversion "$MODULE_PATH" 2>/dev/null)
	if [[ -n $RUNNING_SRCV && $RUNNING_SRCV == "$ONDISK_SRCV" ]]; then
		log "OK: в памяти работает именно DKMS-сборка (srcversion $RUNNING_SRCV)"
	else
		log "ВНИМАНИЕ: в памяти srcversion=$RUNNING_SRCV, на диске=$ONDISK_SRCV - работает НЕ патченный модуль!"
	fi

	# Ищем именно наш platform-profile хендлер по имени: на этой машине
	# есть ещё минимум один ('SoC Power Slider'), head -n1 мог бы
	# показать не тот.
	PP_DEV=""
	for d in /sys/class/platform-profile/*/; do
		if [[ "$(cat "$d/name" 2>/dev/null)" == "bitland-mifs-wmi" ]]; then
			PP_DEV="${d%/}"
			break
		fi
	done
	if [[ -n $PP_DEV ]]; then
		log "platform_profile ($PP_DEV) choices: $(cat "$PP_DEV/choices" 2>/dev/null)"
		log "platform_profile текущий: $(cat "$PP_DEV/profile" 2>/dev/null)"
		log "Ожидается ровно 3 профиля: low-power balanced performance"
	else
		log "ВНИМАНИЕ: platform-profile хендлер bitland-mifs-wmi не найден - проверь dmesg на ошибки probe()"
	fi

	dmesg | grep -i "bitland-mifs-wmi" | tail -n 5 | tee -a "$LOG_FILE"

	# Пересинхронизировать power-profiles-daemon с пересозданным
	# platform-profile хендлером (try-restart = только если запущен).
	if systemctl try-restart power-profiles-daemon 2>>"$LOG_FILE"; then
		log "power-profiles-daemon перезапущен"
	fi

	log "=== Готово ==="
	log "Проверь вручную: powerprofilesctl set performance / balanced / power-saver"
	log "Полный лог: $LOG_FILE"
}

main "$@"
