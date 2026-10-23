# macOS iSCSI Initiator 0.4.2 — Target / LUN selection

Исправлена смена Target в списке обнаружения: текущая цель отмечена, переключение запрещено во время подключения и при подключённом диске. Выбор другой цели отключает автоподключение до явного подключения пользователем. Перед запуском дискового моста приложение проверяет, что выбранный LUN доступен именно у этого Target, и показывает доступные номера вместо непонятной ошибки SCSI.

Discovery now marks the selected target and disables changes while connecting or while a disk is attached. Selecting a different target pauses automatic connection until the user explicitly connects. Before starting the disk bridge, the app checks that the requested LUN belongs to the selected target and lists available LUN numbers if it does not.

The application, source code and documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Experimental Apple Silicon build, ad-hoc signed and not notarized. Use one host per ordinary APFS/exFAT LUN. See the guides for limitations.
