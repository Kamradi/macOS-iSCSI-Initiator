# macOS iSCSI Initiator 0.4.0 — English / Русский

Добавлены английский интерфейс и полный английский гайд. В приложении можно выбрать язык системы, English или Русский; подписи и состояние обновляются сразу, выбор сохраняется. Русский интерфейс и гайд сохранены.

В обоих гайдах и README явно указано: приложение, исходный код и документация созданы при помощи **Codex и ChatGPT (OpenAI)** в совместной работе с автором проекта.

English interface and a complete English guide are now available. Choose System default, English or Русский in the app; labels and status update immediately and the preference is saved. Both guides and READMEs acknowledge that the application, source code and documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

## Downloads / Загрузка

- `macOS-iSCSI-Initiator-0.4.0-macos-arm64.zip`: Apple Silicon app, diagnostic CLI and both guides.
- `macOS-iSCSI-Initiator-0.4.0-source.zip`: MIT-licensed source.
- `GUIDE_EN.md` / `GUIDE_RU.md`: complete guides.
- `SHA256SUMS.txt`: download checksums.

30 automated tests passed locally; the translation checker validates 131 English entries. Storage behavior is unchanged. System dialogs and external errors can follow the macOS language; a running helper keeps its initial log language until the next connection.

Experimental, arm64, ad-hoc signed and **not notarized**. Previously tested on M4/macOS 27.0.1/Synology DS220j with APFS, reconnect and an idle sleep/wake cycle. Use only one host per ordinary APFS/exFAT LUN. Windows/exFAT switching and sustained workloads remain unverified. See the guides and validation record for limitations.
