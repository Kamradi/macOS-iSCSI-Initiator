# Contributing

Build with `zsh build-app.sh` and run `swift test` on a Mac with Xcode/Swift 6. The test suite does not require a NAS. Keep changes small and describe behavior, validation and remaining limits.

Use only a disposable test LUN for live write checks. Never run a second writer against a LUN mounted by another host. Do not include credentials, private IQNs, real NAS addresses, logs with private paths or file contents in issues, screenshots, fixtures or commits.

For bug reports include app version, CPU, macOS/DSM version, the sanitized sequence of events and the relevant error. Distinguish simulation/unit tests from real NAS validation. Never label a new filesystem, OS or authentication mode supported without end-to-end evidence.

Potential work: independent saved connections, per-installation initiator identities and explicit IQN editing, cross-host ownership, stronger crash cleanup, broader protocol validation and a tested notarized distribution process. These are not implemented features.
