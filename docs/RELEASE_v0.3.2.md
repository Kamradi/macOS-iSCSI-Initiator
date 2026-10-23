# macOS iSCSI Initiator 0.3.2 — experimental / экспериментальная версия

## Скачать и начать

- **macOS-iSCSI-Initiator-0.3.2-macos-arm64.zip** — приложение для Apple Silicon, консольная диагностика, лицензия и гайды.
- **GUIDE_RU.md** — полный русский гайд: Synology, новые LUN, форматирование, Windows/exFAT, сон, работа без домашней сети и решение проблем.
- **macOS-iSCSI-Initiator-0.3.2-source.zip** — исходники этого выпуска.
- **SHA256SUMS.txt** — контрольные суммы файлов.

Распакуйте ZIP и запустите SynologyInitiator.app. Укажите свои адрес NAS, Target IQN и номер LUN. Настройки реального NAS в публичной сборке отсутствуют. Подробности — в [полном гайде](https://github.com/Kamradi/macOS-iSCSI-Initiator/blob/main/docs/GUIDE_RU.md).

## Исправление 0.3.2

Исправлена сборка GUI обычным Swift Package Manager на чистой машине: файл с `@main` переименован, чтобы не конфликтовать с особой обработкой имени `main.swift`. Сетевая логика не менялась.

## Возможности

Подключение iSCSI LUN как виртуального диска Finder с чтением/записью, безопасное извлечение, подготовка ко сну, ожидание недоступного NAS и автоматическое подключение при возвращении доступа. Используются встроенный Raw DiskImage macOS и приватный локальный NFS-мост; полный образ LUN на Mac не копируется. Это не нативный SCSI-драйвер.

## Проверки и границы

23 теста прошли локально. Проверены на M4/macOS 27.0.1/Synology DS220j: APFS, реальная запись/flush, сохранность файла после переподключения и один настоящий цикл сна/пробуждения. Один LUN/профиль. **Только один компьютер может использовать обычный APFS/exFAT LUN одновременно.** Владение между компьютерами автоматически не контролируется. Полный обмен exFAT ↔ Windows, CHAP на реальном NAS, длительные нагрузки и закрытие крышки во время большой записи не проверены.

Сборка arm64, ad-hoc signed, **не нотариально заверена Apple**. Проверяйте источник загрузки и следуйте официальным инструкциям macOS либо собирайте приложение самостоятельно. Не требуется отключать SIP/Gatekeeper. Начинайте с одноразового тестового LUN и сохраняйте независимые копии важных данных.

---

Native macOS GUI for an experimental iSCSI-to-Finder bridge. The arm64 ZIP includes the app, diagnostic CLI and documentation. Source is MIT licensed. Tested locally on M4/macOS 27.0.1/Synology DS220j with APFS. The app is ad-hoc signed and **not notarized**. Other machines and OS versions are not validated. Do not concurrently mount an ordinary APFS/exFAT LUN on multiple hosts. Windows/exFAT switching is documented but not end-to-end tested. Start with disposable storage, not irreplaceable data.
