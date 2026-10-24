# macOS iSCSI Initiator 0.5.0 — recover transport without unmounting

Исправлена причина постоянной остановки после сна при открытом видео: ошибка проверки связи или чтения больше не делает мост навсегда неисправным, если неподтверждённых записей нет. Перед восстановлением сверяются стабильный идентификатор, размер, блок и модель LUN. Сохраняются устройство macOS и открытые файлы. Приложение ждёт восстановления связи вместо попыток извлечь работающий том.

Idle keepalive and read-only transport loss can now reconnect within the existing mounted disk, after validating the stable LUN identity and geometry. Requests that have not attempted a write can receive NFS JUKEBOX so the client can wait/retry. A possibly transmitted write or failed write flush permanently offlines the backend; no write replay is performed. SCSI/protocol errors and changed or unavailable identifiers do not authorize recovery. Do not mount or modify the LUN from another host while the Mac retains its attachment.

Validation: 50 automated tests. A real TCP-drop test used a read-only NAS attachment and an open video handle with uncached reads: the checksum matched afterward, and the helper and device entries were unchanged. This is not qualification for sustained writes, arbitrary long sleeps, all network failures or other NAS models.

The application, source code and documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Experimental Apple Silicon build, ad-hoc signed and not notarized. See both guides and the validation record for limitations.
