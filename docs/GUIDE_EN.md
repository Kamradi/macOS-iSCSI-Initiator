# Complete guide: an iSCSI disk on Mac and file exchange with Windows

This application, its source code and this guide were created with assistance from **OpenAI’s Codex and ChatGPT**, in collaboration with the project author.

Application version: **0.5.0, experimental**. Runtime testing used Apple M4, macOS 27.0.1 and Synology DS220j. The downloadable app is for Apple Silicon. Other Macs and macOS releases require separate validation.

[Русский гайд](GUIDE_RU.md) · [Project overview](../README.md)

The application uses the standard iSCSI protocol and is not specific to Synology. Other NAS devices and servers with an iSCSI target are intended to work, but have not been tested: compatibility depends on target capabilities and the application’s limitations. Runtime testing has only used Synology DS220j. Synology is used below as a configuration example.

## Contents

1. [What you get](#1-what-you-get)
2. [Before you begin](#2-before-you-begin)
3. [Create a target and LUN (Synology example)](#3-create-a-target-and-lun-synology-example)
4. [Install the application](#4-install-the-application)
5. [Language and first connection](#5-language-and-first-connection)
6. [Format a new LUN](#6-format-a-new-lun)
7. [Take turns between Mac and Windows](#7-take-turns-between-mac-and-windows)
8. [Sleep, working away from home and VPN](#8-sleep-working-away-from-home-and-vpn)
9. [Connect other LUNs](#9-connect-other-luns)
10. [Troubleshooting](#10-troubleshooting)
11. [Diagnostics and development](#11-diagnostics-and-development)
12. [Uninstall](#12-uninstall)

## 1. What you get

A LUN is a virtual block device allocated on the NAS. iSCSI carries its read and write commands over a network. A target is the connection endpoint identified by an IQN; one or more numbered LUNs can be mapped to it.

The app exposes a LUN as a macOS virtual disk. A volume with a supported filesystem appears in Finder, where applications can use its files normally. Data remains on the NAS. The app does not download a complete local copy of the LUN.

Disk Utility reports **Disk Image** as the transport because the app uses the built-in macOS raw disk-image infrastructure over a private local bridge. It does not install a native SCSI driver. NFS does not need to be enabled on the NAS.

## 2. Before you begin

You need the NAS / server address, access to its iSCSI port (normally TCP 3260), the target IQN, the LUN number and, if enabled, the separate CHAP username and secret. Your server administrator password is not an iSCSI login password.

Start with a separate empty test LUN. This is experimental software, not a qualified place for the only copy of important data. The app does not prevent another computer from accessing the same LUN.

**Do not mount an ordinary APFS or exFAT LUN simultaneously on Mac and Windows.** One host must fully release it before another host connects. Remember that wake or OS startup can trigger automatic connections.

Use a trusted local network or an existing VPN. The app does not enable a VPN, encrypt iSCSI traffic or require you to expose the NAS port publicly. CHAP authenticates knowledge of a secret; it does not encrypt disk contents.

## 3. Create a target and LUN (Synology example)

On another server, enable an iSCSI target, create a LUN, map it to the target and allow access from this Mac. Record the address, port, IQN, LUN number and optional CHAP settings. Management labels vary by vendor.

On Synology with DSM 7, open **SAN Manager**:

1. Create an empty LUN under **LUN** and choose its name, location and capacity.
2. Create or select a target under **iSCSI**. Record its complete IQN.
3. Map the LUN to the target and check its assigned numeric LUN address. The LUN name and number are different; the number is not necessarily 0.
4. Configure one-way CHAP and initiator access permissions if needed. Mutual CHAP is not supported by this app. Its current initiator IQN is `iqn.2026-10.local.synologyinitiator:mac`; it is shared rather than unique per installation, and the GUI does not yet include an IQN editor. Windows has its own initiator IQN, shown in its initiator settings.
5. Confirm that the LUN is healthy and the NAS has sufficient space. With thin provisioning, monitor the underlying NAS volume's free space as well.

Names vary by DSM release; DSM 6 uses iSCSI Manager. See [Synology's instructions](https://kb.synology.com/en-my/DSM/tutorial/How_to_use_the_iSCSI_Target_service_on_Synology_NAS_7) for model-dependent details and limits.

If you restrict access by initiator IQN, permit the appropriate initiator. Discovering a target does not by itself prove that its LUN is accessible.

## 4. Install the application

### Download a build

1. Open the project's [Releases](https://github.com/Kamradi/macOS-iSCSI-Initiator/releases).
2. Download `macOS-iSCSI-Initiator-0.5.0-macos-arm64.zip` and `SHA256SUMS.txt`.
3. Optionally compare `shasum -a 256 ARCHIVE_NAME.zip` with the published checksum. A matching hash verifies the archive bytes, not a trusted publisher signature.
4. Extract the ZIP, move `SynologyInitiator.app` to Applications or another permanent folder, and open it.

The build is ad-hoc signed and **not notarized by Apple**. A downloaded copy may be blocked on another Mac. Verify its source and release contents, and consult [Apple's instructions for opening a trusted unverified app](https://support.apple.com/en-hk/102445). Building reviewed source yourself is an alternative. Do not disable SIP or Gatekeeper globally. Installation of a quarantined download on a clean second Mac has not been tested.

If macOS asks for local-network permission, allow it for communication with your NAS.

### Build from source

Install Xcode and Swift 6. Development used Swift 6.4. The deployment target is macOS 14, but this is not a runtime compatibility guarantee for earlier systems.

```sh
git clone https://github.com/Kamradi/macOS-iSCSI-Initiator.git
cd macOS-iSCSI-Initiator
zsh build-app.sh
swift test
python3 scripts/check-localization.py
```

Open `dist/SynologyInitiator.app`. Building does not install a driver or format a disk.

## 5. Language and first connection

Use the **Language / Язык** selector to choose **System default / Системный**, **English** or **Русский**. The choice is saved and takes effect immediately, including existing status messages and the menu-bar controls. System default uses Russian when the first preferred macOS language is Russian; otherwise it uses English.

App-defined connection and protocol errors are translated. Messages originating from macOS tools and native system dialogs may follow the macOS language instead. A helper that is already running retains its initial language for its own technical log; changing the UI does not disconnect the disk. The next helper receives the selected language. CLI tools also accept `ISCSI_LANGUAGE=en` or `ISCSI_LANGUAGE=ru`.

| Field | Meaning | Example placeholder |
| --- | --- | --- |
| NAS / server address | IP address or DNS name reachable from this Mac | `nas.example.net` |
| Port | NAS iSCSI TCP port | `3260` |
| Target IQN | Complete target name from the server management interface | `iqn.2026-10.example:storage.target1` |
| LUN | Numeric address mapped to the target | `0` |
| CHAP authentication | Enable if required by the target | disabled, or a separate username and secret |

Replace the examples with your own settings.

1. Enter the NAS / server address and port.
2. Click **Discover targets**, then choose the target. You can paste its IQN manually. If the NAS does not support CHAP for discovery, disable CHAP while discovering, then enable it again before connecting to the known IQN.
3. Enter the LUN number. Target discovery does not choose the LUN number automatically.
4. Enter CHAP credentials if required. The password stays in memory and must be entered again after restarting the app.
5. Optionally click **Inspect LUN** to check availability without formatting or writing user files.
6. Click **Connect disk**. This also enables automatic reconnect. Connection took about a minute on the tested setup.
7. A recognized filesystem enables **Open in Finder**. For an empty LUN, continue below.

Settings are saved locally. Closing the window leaves the app running in the menu bar.

Selecting another target in the discovery list pauses automatic connection. Check the LUN number: different targets may expose different numbers. The app checks the mapping before connecting and lists available LUNs when the number is incorrect. Target selection is disabled while a disk is attached.

## 6. Format a new LUN

**Formatting destroys existing data on the selected disk.** Do not rely on a fixed `diskN` identifier: macOS can change it after reconnect. Match the app's device, LUN capacity and selected external virtual disk. Never select Macintosh HD or a physical Mac disk by mistake.

1. Connect the intended LUN from the Mac only.
2. Open **Disk Utility → View → Show All Devices**.
3. Select the whole virtual disk for this LUN, not an unrelated volume.
4. Choose **Erase**. For a modern Mac/Windows pair, select **GUID Partition Map** and **ExFAT**. For Mac-only use, APFS is another option. Name the volume, for example `ISCSI`.
5. Wait until completion. Keep the Mac awake and the network connected during formatting.

[Apple lists exFAT as a Windows-compatible format](https://support.apple.com/en-ie/guide/disk-utility/dsku19ed921c/mac). This does not allow concurrent multi-host access to a LUN. Windows does not read APFS natively.

Real persistence tests of this app used APFS. End-to-end exFAT/Windows switching has not been tested; validate it on an empty disposable LUN first. Changing APFS to exFAT requires reformatting, so copy existing files elsewhere beforehand.

## 7. Take turns between Mac and Windows

### Release the LUN from Mac

1. Close files and applications using the Mac volume.
2. Click **Eject disk** and wait for successful completion. This disables automatic reconnect.
3. Confirm that the Mac no longer owns an iSCSI session to this LUN; use the server management interface (SAN Manager on Synology) to verify this.
4. Only then connect Windows.

There are no separate Transfer to Windows or Return to Mac buttons in this version.

### Connect Windows

1. Open the built-in **iSCSI Initiator** (`iscsicpl.exe`). Start its service if prompted.
2. Enter the NAS / server address and connect to the intended target. For CHAP, use the connection's advanced authentication settings.
3. For alternating use, avoid persistent automatic reconnection on Windows; review Favorite Targets/persistent connections.
4. Open **Disk Management** (`diskmgmt.msc`) and identify the disk by capacity and partitions.
5. If it already contains exFAT, do not initialize or format it again. Assign a drive letter to the existing volume if needed.

Administrators can alternatively use elevated PowerShell. This example does not configure CHAP:

```powershell
Start-Service MSiSCSI
New-IscsiTargetPortal -TargetPortalAddress 'nas.example.net' -TargetPortalPortNumber 3260
Get-IscsiTarget
Connect-IscsiTarget -NodeAddress 'iqn.2026-10.example:storage.target1' -IsPersistent $false
```

Microsoft documentation: [create a portal](https://learn.microsoft.com/en-us/powershell/module/iscsi/new-iscsitargetportal), [connect a target](https://learn.microsoft.com/en-us/powershell/module/iscsi/connect-iscsitarget). Replace the address and IQN. These commands do not format a disk.

### Release Windows and return to Mac

1. Finish copying and close all files on Windows.
2. Safely remove the volume using Windows. If normal eject is unavailable, take this exact disk Offline in Disk Management after closing its files.
3. Disconnect the target in iSCSI Initiator; closing its window is not enough. In PowerShell, `Disconnect-IscsiTarget -NodeAddress 'YOUR_IQN'` requests confirmation. See [Microsoft documentation](https://learn.microsoft.com/en-us/powershell/module/iscsi/disconnect-iscsitarget).
4. Ensure that a persistent Windows connection will not reattach the target.
5. Click **Connect disk** on Mac and verify your files before continuing.

Mac sleep is not a transfer of ownership: if Mac auto-reconnect remains enabled, wake can reconnect the LUN. Always explicitly eject and disable automatic reconnect when transferring ownership to Windows.

## 8. Sleep, working away from home and VPN

Keep the app running in the menu bar and enable automatic connection.

- Before ordinary sleep, it stops new connections and attempts a clean disk eject.
- After waking without access to the NAS, it waits. It does not connect a VPN or create a new inaccessible volume.
- When access returns, it reconnects. Failed checks back off to 15, 30, 60 and then 120 seconds.
- Clicking **Eject disk** stops retries until you explicitly enable them again.
- After uncertain I/O or an incomplete eject, automatic mounting is blocked. Close files and retry eject. For an incomplete connection, use **Check previous connection**.

macOS permits only a limited preparation interval. A busy volume, large write or already failed network can prevent successful eject. Lid close under load, power loss and force-quitting a process are not guaranteed safe. Startup at login is not installed.

If an open file prevents ejection before sleep, the app first checks the existing iSCSI session after wake. A fresh successful response from the same bridge after wake preserves the working attachment without ejection or reconnect. If the session cannot be confirmed healthy, the app retries ordinary safe ejection with backoff and reconnects only after it succeeds. Reading cached files alone does not confirm a live NAS connection. Close files, players and Finder Quick Look windows. A stuck system thumbnail helper can retain a file even after its window closes. Recovery waits while the volume is busy or a clean flush cannot be confirmed; it never force-ejects. Seamless sleep with open files or active writes is not guaranteed. Manual ejection cancels automatic recovery.

From 0.5.0, idle keepalive or read-only transport loss can recover within the bridge when no write is uncertain. The bridge validates a stable LUN identifier and geometry; the macOS device and open descriptors remain unchanged. File operations may wait or fail under macOS rules while the NAS is unavailable. A possibly transmitted write or failed flush is never automatically replayed. Recovery is disabled when a stable LUN identity is unavailable. **Never mount this LUN from another computer or change its contents while the Mac retains its attachment, including while waiting for network access.**

## 9. Connect other LUNs

The app supports **one saved profile and one connected LUN**.

Eject the current disk, edit the address/target/LUN and optional CHAP settings, then connect. This replaces the saved profile. Multiple LUNs or targets can exist on the NAS, but this version connects them one at a time.

You can inspect available LUN numbers with:

```sh
dist/iscsi luns nas.example.net iqn.2026-10.example:storage.target1
```

Connection checks the target/LUN, starts the local bridge and attaches the volume in macOS. The UI shows the current stage and elapsed seconds. Network-backed disks can take tens of seconds. An operation timeout is reported as an error; safely eject any partial attachment before retrying.

## 10. Troubleshooting

| Symptom | Check |
| --- | --- |
| No targets found | NAS / server address, routing/VPN, TCP 3260, iSCSI service and discovery permissions; try the known IQN manually |
| Login rejected | Full IQN, CHAP credentials, initiator permissions, and whether Mutual CHAP must be disabled |
| LUN unavailable | Its numeric address, health and target mapping |
| Device exists but no Finder volume | It may be empty or use an unsupported filesystem. Do not erase it if its data matters |
| Windows asks to initialize the disk | Confirm the LUN and filesystem. Attaching APFS in Windows does not convert it to exFAT |
| Eject failed | Close documents, terminal sessions whose working directory is on the volume, background operations and applications; retry |
| Volume remains after a network loss | It may be offline. Do not keep writing or start another initiator over it; eject the old connection first |
| Disk does not return after manual eject | This is intentional; enable automatic connection or click Connect disk |
| CHAP fails after restarting | The password is not saved; enter it again |
| Connection or formatting is slow | Commands are serialized and writes are acknowledged after flush; maximum throughput has not been qualified |
| A system error is still in another language | Native macOS tool output can follow the OS language; app-defined statuses use the app's selected language |

Do not copy arbitrary erase or forced-eject commands for `/dev/diskN` without identifying the device. If the situation is unclear, stop and keep sanitized logs for diagnosis.

## 11. Diagnostics and development

Settings directory: `~/Library/Application Support/SynologyInitiator/`.

- `profile.json`: connection settings, automatic reconnect and incomplete-disconnect flag; no password.
- `active.json`: owned attachment and local bridge paths.
- `connection.log`: stages and durations of system connection operations.
- `lifecycle.log`: sleep, wake and connection events.
- Per-session directories: `ready.json` and `bridge.log`.

Language choice is saved in the app's macOS preferences, separately from the NAS profile.

Even without passwords, logs/settings can contain private addresses, IQNs, usernames, paths and local identifiers. Do not publish them unredacted. Include application/macOS/DSM versions, Mac/NAS models, reproduction steps and sanitized errors in a report. Do not share LUN contents.

Read-only diagnostics:

```sh
ISCSI_LANGUAGE=en dist/iscsi discover nas.example.net
ISCSI_LANGUAGE=en dist/iscsi luns nas.example.net iqn.2026-10.example:storage.target1
ISCSI_LANGUAGE=en dist/iscsi inspect nas.example.net iqn.2026-10.example:storage.target1 0
ISCSI_LANGUAGE=en dist/iscsi readcheck nas.example.net iqn.2026-10.example:storage.target1 0
```

Do not run another diagnostic session against a LUN already managed by the app. CLI CHAP credentials come from `ISCSI_USERNAME` and `ISCSI_PASSWORD`; the GUI is easier for normal use. Do not place a secret in a command that will remain in shell history.

The source includes a separate `writecheck` developer command gated by `ISCSI_ALLOW_WRITE_TEST`. It temporarily overwrites part of the LUN and may fail before restoring it. **Use it only on disposable developer test storage, never on a disk containing files you need.** The helper's `--read-write` mode also permits writes; do not run it manually alongside the GUI.

For contributors:

```sh
swift test
python3 scripts/check-localization.py
zsh build-app.sh
```

The translation checker verifies English coverage for Russian source messages and matching interpolation placeholders. The storage test suite does not require a NAS. Real write tests always require separate disposable storage.

## 12. Uninstall

1. Close files on the volume and click **Eject disk**.
2. Confirm successful completion, then quit through the menu bar.
3. Delete the app and any unneeded source or download archives.
4. Remove the settings directory only after confirming that no disk or bridge remains active. Do not remove active connection records while the bridge is running.

Uninstalling the app does not delete the LUN or its contents on the NAS. Deleting a LUN in DSM is a separate destructive operation.
