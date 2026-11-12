# RDP Manager — Specification

A small macOS utility for managing the computers on a local network: keep a list of
named machines, follow their IP addresses as they change, show whether each is online,
and connect with one click over RDP, VNC, SSH, or a web admin page.

## Decisions (from requirements interview, 2026-10-25)

| Topic | Decision |
|---|---|
| Platform | Native macOS app (SwiftUI). Main window plus a menu bar item for quick connect. |
| Targets | Windows (RDP), Macs running the Pro RDP server (RDP, with VNC / Screen Sharing as an alternative), Linux (VNC or SSH), network gear (web admin or SSH). |
| Discovery | Either direction. The user adds a machine by hostname, or sweeps the local subnet (**Find Machines**, never automatically) and picks from what answered. Either way the app then resolves it (DNS and mDNS `.local`) on a schedule, records every IP change, and pings for online/offline status. |
| Network sweep | TCP connect to 3389, 5900, 22, 80 and 443, five ports at a time per host and 32 hosts at a time, so a /24 completes in under ten seconds. Open ports decide kind and primary connection; the ARP cache, read from the routing socket, supplies the MAC for Wake-on-LAN, and the sheet says so when that read comes back empty rather than leaving the field quietly blank. Subnets over 1,024 addresses are refused. |
| Updates | Checked against the repository's GitHub releases at launch and at most once a day, and installed only on confirmation. A download must carry the same bundle identifier, be signed by the same Developer ID team as the running copy, and pass `spctl` as an install; anything unprovable is refused. The old bundle is moved aside and restored if the new one fails to land, and the swap is abandoned if the app has not quit. Requires the repository to be public, since the API hides a private one behind a 404. What a check finds opens in a window of its own, so the answer still appears when the app is running with every window closed. |
| Credentials | Stored in the macOS Keychain, per machine, so one click connects. A machine can instead point at a **shared sign-in**: a named account several machines use, whose name, username and domain travel in the shared list (none of them is a secret, and the other admins need to see which account a machine uses) while the password stays in each Mac's own Keychain under the sign-in's id. Changing it once changes it for every machine using it. A machine whose sign-in has been deleted elsewhere falls back to its own username rather than signing in as nobody. |
| Passwords on the wire | Never on a command line. FreeRDP is given `/from-stdin` and the password down a pipe: process arguments are readable with `ps` by anything else running as this user, so `/p:` shared every saved password with every other program on the Mac for the life of the session. The username and domain stay on the command line, which means the only thing FreeRDP can still be missing is the password, so the single line written cannot be read as an answer to anything else. A machine with a password but no username sends nothing, because FreeRDP asks for the username first. |
| RDP client | A machine with a password saved goes to the bundled FreeRDP, the only client that can be given one. Otherwise prefer Microsoft Windows App when installed, and fall back to FreeRDP — but only when its Mach-O header holds an architecture this Mac can start, the bundled copy being whatever the packaging Mac's Homebrew built. |
| Features v1 | Wake-on-LAN, groups/tags/notes, SSH and web links, IP change history, offline/IP-change alerts. |
| Wake-on-LAN | The magic packet goes to the limited broadcast and to the subnet broadcast worked out from the mask of the interface this Mac shares with the machine — putting 255 in the last octet is only right on a /24, and the wrong broadcast wakes nothing. Waking then waits for the port the machine's own connection type uses and connects when it answers, giving up after two minutes with a reason; the address is resolved again on each attempt, since it may have changed while the machine was off. |
| Session options | Per machine, passed to whichever RDP client carries the connection so the two agree: sound (see below), scale at 100/140/180, all displays or one, clipboard shared or not, and a folder shared into the session. The folder is FreeRDP only — Windows App does not take one from a `.rdp` file it is handed, so nothing is written there rather than promising something that silently does not happen. A scale the clients would reject is read back as 100, since a bad one fails the whole connection. |
| Monitoring | Per machine, and can be turned off. A laptop that is meant to be off half the time otherwise reports itself offline all day, which teaches you to ignore the alerts that matter. Turning it off clears whatever status was known rather than leaving a stale dot. |
| Network scope | One local network (no multi-site logic), with two exceptions that need none of it: a machine may name an SSH **jump host** (`ssh -J`) or an **RD Gateway** for RDP, for one this Mac cannot reach directly. |
| Quick connect | A global shortcut (⌃⌥⌘K, switchable) opens a box: a few letters, Return, connected. Registered through Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor, which would need accessibility permission and let the app read every keystroke typed anywhere. It is an `NSPanel` rather than a SwiftUI `Window`, because a scene can only be opened through `openWindow` from the environment and the shortcut fires outside any view. |
| Sharing | Machine list lives in a JSON file the user can place on a network share or iCloud Drive. Credentials never leave each Mac's Keychain. |

## How connections launch

| Type | Mechanism |
|---|---|
| RDP via Windows App | App writes a temporary `.rdp` file (full address, username, display options) and opens it with Windows App. The password cannot be included: a `.rdp` file carries one in `password 51:b:` as a Windows DPAPI blob, and the Mac build has no code for that field, so Windows App asks every time. It remembers credentials only for connections created inside it, not for a file it is handed. |
| RDP via FreeRDP | `xfreerdp /v:host /u:user /p:password` with the password pulled from the Keychain. Fully unattended. |
| Session sound | Per machine: on the remote machine (the default), on this Mac, or not at all. One setting for both clients — `audiomode:i:` in the .rdp file and `/audio-mode:` on FreeRDP's command line take the same 0/1/2. Always passed to FreeRDP, which otherwise opens no audio channel while Windows App defaults to redirecting here. |
| VNC | Opens `vnc://user:password@host` which launches the built-in Screen Sharing app. |
| SSH | Writes a `.command` script holding the `ssh` command and opens it with the terminal chosen in Settings, which defaults to Warp when installed. With System default chosen, or no terminal found, opens `ssh://user@host` and lets macOS pick the app. |
| Web | Opens the stored URL (defaults to `https://<ip>`). |

The per-machine "primary" connection type is what a single click on the name runs.
Other types are available from a context menu.

A terminal cannot be reached through `ssh://` unless it registers for that scheme, and most
(Warp included) register only their own. What they do declare is a document type with the
`Shell` role, meaning they run a script handed to them rather than display it. So choosing a
terminal writes `~/Library/Application Support/RDP Manager/ssh/<machine>.command` and opens
it with that app. Warp is the registered default when installed, so the picker and the
launch path agree without anything being written to the user's preferences until they
choose for themselves. The app refuses to use an app that does not declare the role, which would
otherwise show the script in an editor. The Keychain password is deliberately not written
into the script: `ssh` prompts, or the user connects with a key.

## IP tracking

* Every `pollInterval` seconds (default 30) the app resolves each hostname with
  `getaddrinfo`, which covers DNS, the hosts file, and Bonjour `.local` names.
* If the resolved address differs from the last known one, an entry is appended to that
  machine's `ipHistory` with a timestamp, and a notification is posted.
* Reachability is checked with an ICMP ping (via `/sbin/ping`) and, for machines with a
  service port, a TCP connect to that port (3389, 5900, 22, 80/443). Status is one of
  `online`, `offline`, or `unknown`.
* A machine is looked for at its resolved name, then the address last recorded, then
  wherever its MAC is in the ARP cache. That last one is what finds a machine on plain DHCP
  with no DNS record after its lease changes; the MAC is already collected for Wake-on-LAN,
  and the address it answered at is recorded so the next cycle starts in the right place.
* Transitions from online to offline post a notification (debounced: two consecutive
  failures before a machine is called offline). Notifications are gathered per cycle, so
  one event affecting many machines is one notification naming their shared group rather
  than twenty alerts arriving at once.
* Every transition is written to a per-Mac uptime log, which is what the detail view's
  outage list and weekly reachability figure are built from. Per-Mac because each Mac sees
  the network from where it stands, and because polling then writes nothing to the shared
  file.
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
  domain        optional, for RDP; a backslash in username is still split as before
  credentialID  optional, a shared sign-in to use instead of the above
  monitored     whether the poller watches it
  audio, displayScale, multipleMonitors, shareClipboard, sharedFolder
  jumpHost, gateway           for a machine not directly reachable
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
* Each machine carries a `modifiedAt`, and each field is merged against the last version
  both Macs are known to have seen. A field only one side touched is kept from that side
  whatever the timestamps say; only a field both sides changed, to different values, falls
  back to `modifiedAt`, and it settles that field alone. Whole-record last-writer-wins threw
  away one of two unrelated edits depending on who saved last.
* The baseline is not moved forward when this Mac saves — another Mac editing at that
  moment started from what was on disk before the write — but a machine with no baseline is
  seeded on its first save, since that write is the first time it existed anywhere. A record
  older than the baseline is a copy that has not caught up, not an edit.
* Recording an address or a sighting is deliberately not an edit and does not touch
  `modifiedAt`. Every Mac watching the same machine notices the same change, and if that
  counted as an edit the Mac that polled last would win every merge and carry its own stale
  settings over everyone else's work.
* Deletes are written to the document as tombstones, kept for a month. Without them a
  delete does not stick: another Mac that has not reloaded still has the machine and saves
  it back. A machine edited after its delete was put back deliberately and survives.
* Reading failures are never written over. If the file is there but unreadable or will not
  decode, or the volume it is on is not mounted, the app says so and refuses to save: the
  empty list it is showing must not replace a file that is still good. A share that mounts
  late recovers on its own.
* The list is backed up on this Mac before each change that replaces it, ten deep, so a bad
  merge or a mistaken import can be undone. Backups are local rather than beside the list,
  so several Macs do not each drop copies on the share.
* Export / import of the same JSON for backup. An import previews what it will add and
  replace before doing it.

## Command line

`rdpm` is a second target in the same project, copied into
`RDP Manager.app/Contents/Helpers/rdpm` by a post-build step so it is distributed,
signed and notarized with the app rather than installed separately; `install-cli.sh`
only symlinks it onto `PATH`. The app does the same from
**Install Command Line Tool…** and from Settings, writing the symlink directly when the
folder is writable and otherwise asking for an administrator through `osascript`, so no
password reaches the app. Uninstalling only removes a link that points inside an
`RDP Manager.app`, leaving an unrelated `rdpm` on the PATH alone.

`rdpm version` reads an Info.plist embedded in the binary, carrying the same
`MARKETING_VERSION` as the app, so the two cannot drift apart. It shares `Machine` and `StoreLocation` with
the app, decodes `machines.json` directly, and never writes to it, so it cannot disturb the
merge between Macs. `rdpm ssh <name>` builds the ssh arguments from the machine's username,
port and jump host and then `execvp`s ssh, handing over the tty, signals and exit status
rather than wrapping them. `rdpm wake` sends the packet itself, being pure sockets and
address arithmetic. `rdpm connect|rdp|vnc|web` hands the machine to the app over an `rdpm:`
URL instead of reimplementing a launch: the client preference, the Keychain, the shared
sign-ins and the rules about which client can be handed a password all live there, and two
implementations would drift apart. The machine's id travels, not its name, so a rename
between the lookup and the handling cannot connect to the wrong machine.

Name resolution widens only when a narrower match misses: exact name, exact hostname, name
prefix, hostname prefix, name substring. Several matches with no exact one is an error, not
a guess. The file is found from `--store`, then `$RDP_MANAGER_STORE`, then the app's own
`storeFilePath` preference (read from the app's domain, since the command runs outside the
bundle), then the default location.

## Not in v1

* Multiple sites with separate DNS (a jump host and an RD Gateway cover the cases that
  matter without it).
* App Store sandboxing (the app launches other apps and `ping`, so it runs unsandboxed).

## Distribution

* Release builds are signed with a Developer ID Application certificate, with the hardened
  runtime and a secure timestamp, which is what notarization requires. The bundled FreeRDP
  dylibs are signed with the same identity: `sdl-freerdp` runs under the hardened runtime,
  and library validation only loads dylibs from its own team.
* Inner code is signed before the outer bundle rather than with `codesign --deep`, and the
  app is signed again after the helpers are copied in, since that invalidates the signature
  `xcodebuild` applied.
* Debug builds stay ad-hoc signed so building and testing needs no certificate.
* `package.sh` notarizes and staples when a `notarytool` credential profile exists, and
  otherwise says how to create one.

## Build

* Xcode project generated with `xcodegen` from `project.yml`.
* FreeRDP is built from Homebrew and copied into the app bundle with its dylibs and
  OpenSSL's provider modules (`scripts/bundle-freerdp.sh`). The providers are
  `dlopen`ed rather than linked, so they have to be copied deliberately; the legacy
  one carries MD4, MD4 is what NTLM needs, and under the hardened runtime library
  validation refuses to load Homebrew's copy. The app points `OPENSSL_MODULES` at
  the bundled directory, without which NLA fails as `SEC_E_NO_CREDENTIALS` and a
  saved password appears to be ignored. Until that script runs, the app also looks for
  `/opt/homebrew/bin/xfreerdp`.
