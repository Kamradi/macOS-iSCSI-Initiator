# macOS iSCSI Initiator 0.4.4 — recovery after sleep

Если файл не позволил извлечь диск перед сном, после пробуждения приложение повторяет безопасное извлечение с паузами и подключает диск только после успеха. Ручное извлечение отменяет восстановление. Используется штатный `diskutil eject`; причина неудачного извлечения записывается в локальный журнал.

Open files, players, Finder Quick Look or a stuck thumbnail helper can prevent ejection before sleep. After wake the app now retries ordinary safe ejection with backoff and reconnects only after it succeeds. Manual stop cancels recovery. Uses `diskutil eject` and records the ejection error in the local log. No forced unmount, write replay or remount over an outstanding attachment was added. Close blocking files or previews; recovery still cannot proceed until clean ejection succeeds.

The application, source code and documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Experimental Apple Silicon build, ad-hoc signed and not notarized. Use one host per ordinary APFS/exFAT LUN. See the guides for limitations.
