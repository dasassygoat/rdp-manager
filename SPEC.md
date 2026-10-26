# RDP Manager — Specification

A small macOS utility for managing the computers on a local network: keep a list of
named machines, follow their IP addresses as they change, show whether each is online,
and connect with one click over RDP, VNC, SSH, or a web admin page.

## Decisions (from requirements interview, 2026-10-25)

| Topic | Decision |
|---|---|
| Platform | Native macOS app (SwiftUI). Main window plus a menu bar item for quick connect. |
| Targets | Windows (RDP), Macs running the Pro RDP server (RDP, with VNC / Screen Sharing as an alternative), Linux (VNC or SSH), network gear (web admin or SSH). |
| Discovery | User adds a machine by hostname. App resolves it (DNS and mDNS `.local`) on a schedule, records every IP change, and pings for online/offline status. |
| Credentials | Stored in the macOS Keychain, per machine, so one click connects. |
| RDP client | Prefer Microsoft Windows App when installed. Fall back to a bundled FreeRDP (`xfreerdp`). |
| Features v1 | Wake-on-LAN, groups/tags/notes, SSH and web links, IP change history, offline/IP-change alerts. |
| Network scope | One local network (no multi-site logic). |
| Sharing | Machine list lives in a JSON file the user can place on a network share or iCloud Drive. Credentials never leave each Mac's Keychain. |

## How connections launch

| Type | Mechanism |
|---|---|
| RDP via Windows App | App writes a temporary `.rdp` file (full address, username, display options) and opens it with Windows App. Windows App prompts for the password once and can remember it. |
| RDP via FreeRDP | `xfreerdp /v:host /u:user /p:password` with the password pulled from the Keychain. Fully unattended. |
| VNC | Opens `vnc://user:password@host` which launches the built-in Screen Sharing app. |
| SSH | Opens `ssh://user@host`, which macOS hands to Terminal. |
| Web | Opens the stored URL (defaults to `https://<ip>`). |

The per-machine "primary" connection type is what a single click on the name runs.
Other types are available from a context menu.

## IP tracking

* Every `pollInterval` seconds (default 30) the app resolves each hostname with
  `getaddrinfo`, which covers DNS, the hosts file, and Bonjour `.local` names.
* If the resolved address differs from the last known one, an entry is appended to that
  machine's `ipHistory` with a timestamp, and a notification is posted.
* Reachability is checked with an ICMP ping (via `/sbin/ping`) and, for machines with a
  service port, a TCP connect to that port (3389, 5900, 22, 80/443). Status is one of
  `online`, `offline`, or `unknown`.
* Transitions from online to offline post a notification (debounced: two consecutive
  failures before a machine is called offline).
* If a hostname stops resolving, the app keeps trying the last known IP so the machine
  stays reachable.

## Data model

```
Machine
  id            UUID
  name          display name
  hostname      what gets resolved (may equal name)
  lastIP        last resolved address
  macAddress    optional, for Wake-on-LAN
  group         optional string (site, role, etc.)
  tags          [String]
  notes         free text
  primary       .rdp | .vnc | .ssh | .web
  username      optional (password lives in Keychain under the machine id)
  rdpPort, vncPort, sshPort   defaults 3389 / 5900 / 22
  webURL        optional
  ipHistory     [{ ip, seenAt }]
  status        online | offline | unknown   (runtime only, not persisted)
  lastSeen      Date
```

## Shared store

* One JSON document, default `~/Library/Application Support/RDP Manager/machines.json`.
  Settings let the user point it at a folder on a share or iCloud Drive.
* The app watches the file (DispatchSource on the file descriptor) and reloads when
  another Mac writes it. Writes are atomic (write to temp, rename).
* Each machine carries a `modifiedAt`. On reload, a machine whose on-disk `modifiedAt`
  is newer than the in-memory copy wins. This is last-writer-wins per machine, which is
  enough for a handful of admins.
* Export / import of the same JSON for backup.

## Not in v1

* Subnet scanning / MAC-based tracking.
* Multiple sites with separate DNS.
* App Store sandboxing (the app launches other apps and `ping`, so it runs unsandboxed).

## Build

* Xcode project generated with `xcodegen` from `project.yml`.
* FreeRDP is built from Homebrew and copied into the app bundle with its dylibs
  (`scripts/bundle-freerdp.sh`). Until that script runs, the app also looks for
  `/opt/homebrew/bin/xfreerdp`.
