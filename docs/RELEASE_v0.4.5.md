# macOS iSCSI Initiator 0.4.5 — preserve a working session after wake

Исправлено лишнее переподключение после сна: если диск остался подключённым, приложение сначала ждёт свежего успешного ответа существующей iSCSI-сессии. При подтверждении сохраняется тот же диск; извлечение и новое подключение отменяются. Чтение из кэша не используется как доказательство связи с NAS. Если сеанс действительно потерян, остаётся безопасное восстановление 0.4.4. При ручном извлечении занятого диска сообщение объясняет, что открытый файл или просмотр удерживает том.

After wake, an outstanding attachment is now preserved when a fresh successful heartbeat confirms the same existing iSCSI session. This cancels unnecessary ejection and reconnect attempts. Cached reads, a pre-wake heartbeat or another helper’s response are not sufficient. Lost sessions still use the safe recovery path. Busy manual ejection explains that an open file or preview is blocking the operation. No force-ejection, automatic termination of players, or write replay was added.

The application, source code and documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Experimental Apple Silicon build, ad-hoc signed and not notarized. Use one host per ordinary APFS/exFAT LUN. The precise lid-close/video scenario for this revision has not yet been repeated as a runtime sleep test; see validation notes.
