# macOS iSCSI Initiator

This application, its source code and its documentation were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Experimental native macOS application that presents an iSCSI LUN as a writable disk in Finder. Tested on Apple M4, macOS 27.0.1, and Synology DS220j.

**[Complete English guide](docs/GUIDE_EN.md)** · **[Полный гайд на русском](docs/GUIDE_RU.md)** · [Русское описание](README_RU.md) · [Architecture](docs/ARCHITECTURE.md) · [License](LICENSE)

## Download and build

Download the Apple Silicon application ZIP from this repository's **Releases** page, or build from source:

```sh
zsh build-app.sh
swift test
python3 scripts/check-localization.py
```

The application is `dist/SynologyInitiator.app`. The diagnostic tool is `dist/iscsi`.

The prebuilt app is **arm64 only** and **ad-hoc signed, not notarized**. macOS may block a downloaded build. Prefer a local source build if you cannot independently verify the download. No SIP changes or custom kernel extension are required. Other Macs, macOS releases, NAS models, and long-running workloads have not been validated. The package declares macOS 14 as its deployment target; that is not a compatibility certification.

## Use

1. Create a LUN and iSCSI Target on your NAS and note its address, IQN, LUN number and optional CHAP credentials.
2. Open the app, enter those settings and click **Подключить диск** (Connect disk).
3. Format a **new empty** LUN with Disk Utility, or mount an existing supported filesystem. Formatting destroys existing data.
4. Keep the app running. It attempts a clean detach before sleep, waits quietly when the NAS is unavailable, and reconnects when access returns.
5. **Извлечь диск** (Eject) disables auto-reconnect until you explicitly enable it again.

Only one saved connection and one mounted LUN are supported. The application does not contain a Windows initiator; Windows uses its built-in iSCSI Initiator. The GUI supports English and Russian. Choose System default, English or Русский in the Language selector; the choice is saved and applied immediately. Native macOS dialogs and external tool errors may follow the system language.

## How it works

Finder → APFS/exFAT → macOS Raw DiskImage → private loopback NFS file → userspace iSCSI → NAS.

The virtual file streams I/O to the real LUN; it is not a downloaded local image. This is a file-backed virtual block device, **not a native SCSI HBA driver**. The NFS server binds only to `127.0.0.1`. You do not need to enable NFS on the NAS.

## Important limitations

- Experimental storage software: start with a disposable LUN and keep independent backups.
- **One computer at a time per ordinary APFS/exFAT LUN.** Cross-host ownership is not enforced by the app. Do not mount it simultaneously from Windows and macOS.
- exFAT is a compatible filesystem choice, but end-to-end Windows/exFAT switching has not been tested with this app. Real write/persistence tests used APFS.
- Sleep preparation has a limited OS deadline. Busy files, active writes, lid-close behavior under load, and an already lost connection may prevent clean detach.
- After an uncertain I/O failure, the session is offlined and automatic remount is blocked. There is no write replay or automatic forced eject.
- CHAP is supported in protocol tests, but has not been validated on the real NAS. Mutual CHAP, digests, multipath and full RFC compliance are not implemented.
- Local settings and bridge logs live under `~/Library/Application Support/SynologyInitiator/`. CHAP passwords are not saved in those files.
- Startup at login is not installed. Reconnect can take about a minute on the tested setup.

## Validation

30 automated tests; real discovery, LUN capacity/read/write/flush, APFS formatting and mounting, file checksum after a full reconnect, and one real sleep/wake cycle. No sustained-load or full fault-injection qualification has been performed. See [validation notes](docs/VALIDATION.md).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Do not include NAS credentials, real target IQNs, file contents or private network logs in issues. Use a disposable LUN for write tests.
