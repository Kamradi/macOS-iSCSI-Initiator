# Validation record

## Verified locally, 2026-10-23

Environment: Apple M4, macOS 27.0.1, Synology DS220j. Builds used Swift 6.4/Xcode and arm64. The deployment target in Package.swift is macOS 14; no compatibility matrix for older releases is claimed.

- 33 automated tests: iSCSI framing, text parsing, CHAP vectors, discovery, digest rejection, read boundaries/order, R2T/Data-Out write and flush, unavailable LUNs, NFS export capabilities, read-only/bounds checks, durable acknowledgements, malformed XDR, reconnect backoff, sleep/wake policy, manual disconnect intent, persisted fault flags and subprocess deadlines.
- Seven of the automated tests cover language selection, saved preferences, live translation, nested error messages, interpolation and catalog consistency.
- Real NAS discovery, login without CHAP, LUN capacity, first/last block and repeated 1 MiB reads.
- Guarded write/read/flush test on a disposable LUN.
- GPT/APFS formatting and mounting a 500 GiB LUN through the loopback bridge.
- A 1 MiB random test file matched its original SHA-256 after full image detach, NFS unmount, helper termination and fresh GUI reconnect.
- During a real idle sleep test, the app received sleep preparation, completed clean detach in about 3 seconds, received wake and reconnected automatically in about a minute. The same file checksum matched afterward.
- A temporarily unavailable endpoint showed quiet waiting in the GUI; restoring the endpoint resumed automatic connection. This was not a physical test in a different network.

- Version 0.4.0: release app build succeeded; changing the GUI language to English updated labels and the in-progress connection status immediately. The catalog checker verified 131 English entries.

- Version 0.4.2: regression test verifies that a missing target/LUN mapping is rejected before inquiry, disk read or write commands.

- Version 0.4.3: added regression coverage for a partition slice appearing before the backing device and a synthesized APFS device appearing before its partition map. Added stage/timing diagnostics; no filesystem-check bypass or forced detach was introduced.

## Not verified

- Real CHAP NAS sessions, Mutual CHAP or digest negotiation.
- exFAT/Windows end-to-end switching and crash recovery.
- Sustained high load, lid close during a large write, NAS power loss or adversarial fault injection.
- Other CPU architectures, other macOS versions, other NAS models or a clean downloaded installation on another Mac.
- Notarization or Gatekeeper approval of a public download.

A successful test run is not a storage durability guarantee or a complete protocol conformance test. Do not run destructive developer tests against a live LUN with valuable files.
