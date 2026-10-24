# Architecture

The GUI launches a userspace helper with a single iSCSI session. A private NFSv3 server exposes one virtual file, `lun.raw`, whose length is the remote LUN capacity. macOS mounts this loopback-only export and attaches the file through its built-in `CRawDiskImage` support. The resulting block device is formatted/mounted by the normal macOS storage stack.

```text
Finder / applications
  → APFS or another supported filesystem
  → macOS virtual block device (Disk Image)
  → virtual lun.raw on private loopback NFS mount
  → serialized iSCSI READ(16), WRITE(16), SYNCHRONIZE CACHE(16)
  → NAS LUN
```

No full local backing image is created. NFS binds to 127.0.0.1 on an ephemeral port; export names and file handles are random capabilities. The export is not advertised and normal local filesystem permissions restrict access. This is not a general-purpose NFS service and is not intended for hostile local multi-user environments.

## Code layout

- `Sources/ISCSICore`: framing, bounded TCP I/O, login, CHAP, discovery, read/write/flush, keepalive.
- `Sources/DiskBridge`: byte/block adapter, XDR and restricted NFSv3 server.
- `Sources/ISCSIBridge`: helper process entry point.
- `Sources/ISCSIApp`: SwiftUI, mounted-device ownership, settings, IOKit sleep/wake and network observation.
- `Sources/ConnectionLifecycle`: reconnect policy, persisted non-secret profile, bounded subprocess runner.
- `Sources/ISCSICLI`: read diagnostics and explicitly gated destructive developer checks.
- `Tests/ISCSICoreTests`: protocol, bridge and lifecycle tests.

## I/O and failure behavior

One command is outstanding per session. Writes use solicited R2T/Data-Out. NFS write acknowledgements claim FILE_SYNC only after a SCSI cache synchronization succeeds. A transport error during a possibly transmitted write or a failed flush permanently offlines the backend; writes are not replayed automatically. Idle keepalive and read-only transport failures close the old socket and permit a replacement session only after matching stable SCSI VPD identity, geometry, vendor and model. An unavailable backend returns NFS3ERR_JUKEBOX for requests that have not attempted a write, allowing the client to wait/retry. No dirty bridge data remains after FILE_SYNC acknowledgements. Protocol/SCSI errors and changed or missing identities do not authorize automatic recovery. There is no distributed reservation/ownership enforcement and no multipath.

The app records the owned backing-file path before attaching a disk image. Recovery and detach match that path against macOS disk-image records rather than trusting a reused disk number. A recovered helper is not killed solely by a saved PID; an orphan helper may need manual diagnosis after an application crash. Keepalive runs every 10 seconds.

## Sleep and reconnect

The app registers with IORegisterForSystemPower. Sleep preparation stops new mounts and attempts a clean detach, with an approximately 23-second operation budget and a bounded power acknowledgement. After wake, a retained backend can restore an idle/read-only transport without unmounting its NFS file or macOS disk. The app waits while this recovery is pending and preserves a confirmed healthy session. An uncertain write/flush still blocks recovery and requires safe cleanup. A new mount is never placed over the old attachment. After a clean detach and wake, background reachability checks back off to at most one attempt every 120 seconds. A new mount performs real iSCSI login against the configured target.

These mechanics do not make forced sleep, power loss, active writes or arbitrary network failures lossless. One idle sleep/wake cycle has been tested, not a full failure matrix.

## Protocol scope

Implemented: iSCSI discovery/normal login, None and one-way CHAP-MD5, REPORT LUNS, INQUIRY, READ CAPACITY(16), READ(16), WRITE(16), SYNCHRONIZE CACHE(16), NOP keepalive. Only no-digest/ErrorRecoveryLevel 0 negotiation is supported. Login continuation and some text continuation cases intentionally fail closed. This is not a complete RFC 7143 implementation.

## References

- [RFC 7143 — iSCSI](https://www.rfc-editor.org/rfc/rfc7143.html)
- [RFC 1813 — NFSv3](https://www.rfc-editor.org/rfc/rfc1813.html)
- [RFC 5531 — ONC RPC](https://www.rfc-editor.org/rfc/rfc5531.html)
- Local macOS manuals: `man mount_nfs`, `man hdiutil`.
- [Apple DTS discussion of virtual storage through a filesystem and Raw DiskImage](https://developer.apple.com/forums/thread/837879).
