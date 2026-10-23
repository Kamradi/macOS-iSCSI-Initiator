# macOS iSCSI Initiator 0.4.3 — connection progress

При долгом подключении теперь отображаются текущий этап и прошедшее время. Добавлен локальный журнал длительности операций `connection.log`. Убран лишний вызов `diskutil info`, который повторно сканировал сетевой диск. У локального NFS-моста отключено упреждающее чтение; размер блока чтения и записи сохранён. Корректно выбирается физическое виртуальное устройство, даже если macOS перечисляет раздел или синтезированный APFS-диск раньше него.

The app now shows connection stages and elapsed seconds. A local `connection.log` records operation durations. Removed a redundant `diskutil info` probe and disabled NFS read-ahead on the private bridge, retaining the existing read/write sizes. Backing-device selection handles partition slices and synthesized APFS devices appearing first in macOS output.

Network-backed mounting can still take tens of seconds. Filesystem checks, durable write acknowledgements and safe detach remain enabled. No force-eject or write replay was added.

The application, source code and documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Experimental Apple Silicon build, ad-hoc signed and not notarized. Use one host per ordinary APFS/exFAT LUN. See the guides for limitations.
