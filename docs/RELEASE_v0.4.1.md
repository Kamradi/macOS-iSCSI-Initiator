# macOS iSCSI Initiator 0.4.1 — NAS / server

Интерфейс переименован в **iSCSI Initiator**. Подписи, статусы подключения и ошибки на русском и английском больше не привязаны к Synology. В обоих гайдах добавлена общая схема создания Target и LUN; Synology используется как пример настройки.

Приложение использует стандартный iSCSI. Другие NAS и серверы предполагаются совместимыми в пределах реализованных возможностей протокола, но пока не проверены. Фактические проверки выполнены только с Synology DS220j. Логика подключения не менялась. Сохранённый профиль и настройки совместимы с предыдущей версией; внутреннее имя пакета `SynologyInitiator.app` сохранено.

The interface is now named **iSCSI Initiator**. English and Russian labels, connection states and errors use generic NAS/server terminology. Both guides include general target/LUN setup steps and identify Synology as a configuration example. Standard iSCSI targets from other vendors are intended to work within the implemented protocol features, but remain untested. Only Synology DS220j has been used for runtime testing. Connection logic is unchanged. Existing preferences remain compatible; the internal bundle filename `SynologyInitiator.app` is retained.

The application, source code and documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Download the arm64 application ZIP, source ZIP, English/Russian guides and SHA256SUMS.txt below. Experimental, ad-hoc signed and **not notarized**. Use only one host per ordinary APFS/exFAT LUN. See the guides for limitations.
