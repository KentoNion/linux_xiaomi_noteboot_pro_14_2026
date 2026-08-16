# Full-speed for Xiaomi Book Pro 14 (2026 / TM2424)

DKMS-модуль поверх in-tree драйвера `bitland-mifs-wmi`. Включает режим
**Full-speed** (~50 Вт устойчиво на AC) через обычный `platform_profile` /
`powerprofilesctl`. Отдельной утилиты нет.

Проверено на Xiaomi Book Pro 14 2026, плата `TM2424`, ядро 7.1.4.

Протокол WMI: [XiControl](https://github.com/Oksion/XiControl)
(`docs/01-wmi-protocol.md`).

## Что чинит

Штатный `bitland-mifs-wmi` написан под игровую линейку Tongfang/Redmi G
(байты `0..3` + гейт «только DC-разъём»). На TM2424 прошивка другая:

| `powerprofilesctl` | Прошивка (cmd 0x08) |
|---|---|
| `power-saver` | Eco (`0x0A`) |
| `balanced` | Auto (`0x09`) |
| `performance` | Full-speed (`0x04`), на батарее fallback Turbo (`0x03`) |

Full-speed без зарядки прошивка отвергает сама. Это не баг драйвера.

Другие Bitland-машины не затрагиваются: квирк срабатывает только при
`sys_vendor=XIAOMI` и `board_name=TM2424`.

## Установка

Нужны `dkms` и заголовки текущего ядра (`linux-headers` на Arch,
`linux-headers-$(uname -r)` на Debian/Ubuntu).

```sh
sudo bash scripts/install.sh
```

Проверка:

```sh
modinfo -n bitland_mifs_wmi
# .../updates/dkms/bitland-mifs-wmi.ko.zst

dmesg | grep thin-ultrabook
# detected thin-ultrabook MIFS firmware (DMI quirk) ...

powerprofilesctl set performance   # на зарядке -> Full-speed ~50 Вт
```

Откат:

```sh
bash scripts/uninstall.sh
```

DKMS переживает `pacman -Syu` / обновление ядра, пока стоят заголовки той же
версии. Если WMI API в новом ядре разъедется, модуль не соберётся и загрузится
уже новый in-tree драйвер без квирка.
