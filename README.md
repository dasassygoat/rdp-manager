# RDP Manager

[![Tests](https://github.com/dasassygoat/rdp-manager/actions/workflows/tests.yml/badge.svg)](https://github.com/dasassygoat/rdp-manager/actions/workflows/tests.yml)

A macOS utility for the computers on your local network. Scan the network to find them,
or add them by name, and the app keeps track of their IP addresses as they change, shows
whether each is online, and connects with one click over RDP, VNC, SSH, or a web admin
page. See [SPEC.md](SPEC.md) for the design decisions.

## Requirements

* macOS 14 or later (built and tested on macOS 26 with Xcode 27).
* For RDP: [Windows App](https://apps.apple.com/app/id1295203466) from the App Store
  (preferred), or the FreeRDP client bundled into the app by `scripts/bundle-freerdp.sh`.
* Macs you want to reach over RDP need an RDP server such as [Pro RDP](https://prordp.app/).
  Without one, use VNC (System Settings → General → Sharing → Screen Sharing).

## Build

```bash
brew install xcodegen freerdp
scripts/run.sh
```

`scripts/run.sh` generates the Xcode project, builds a Debug app, copies `sdl-freerdp`
and its libraries into the bundle (so it works on Macs without Homebrew), and launches it.

## Test

```bash
scripts/test.sh
```

Unit tests cover the shared store: the last-writer-wins merge that runs when another Mac
writes the file, IP history recording and its 200-entry cap, and the atomic saves that keep
a reader on a share from ever seeing a half-written list. `scripts/test.sh -v` prints the
whole log. The tests compile the store and model straight into the test bundle, so they run
without launching the app.

The same script runs on every push and pull request via
[.github/workflows/tests.yml](.github/workflows/tests.yml) on a macOS runner.

## Finding machines

**Find Machines** in the toolbar (⇧⌘F, or File → Find Machines on This Network…) sweeps
the subnet this Mac is on and lists what it finds, ticked and ready to add.

Each address is probed on 3389, 5900, 22, 80 and 443, all five at once, so a /24 takes
under ten seconds. What answers decides how the machine is set up: 3389 makes it a Windows
machine that connects over RDP, 5900 a Mac over VNC, 22 alone a Linux box over SSH, and a
web port alone a device opened in the browser. The reverse-DNS name becomes the machine
name when the network has one, otherwise `host-<last octet>`.

The sweep then reads the ARP cache to fill in MAC addresses, which is what Wake-on-LAN
needs and the one field nobody wants to type. The cache is read from the routing socket
rather than by running `arp`, which is handed an empty table as a subprocess and reports
no error for it. A host found only in the cache is listed but left unticked: there is no
way to connect to something that answered on nothing, so adding it is a decision.

A host already in your list is shown greyed out rather than offered again. It is matched by
address, then by MAC, then by name, so a machine that picked up a new DHCP lease is
recognised instead of added twice. If that machine has no MAC recorded, the sweep fills one
in and says how many it filled; a MAC already on record is left alone.

Discovery only ever runs when you ask it to, and it refuses a subnet larger than 1,024
addresses rather than sweeping something enormous.

## Command line

In the app: **RDP Manager → Install Command Line Tool…**, or Settings → Connections →
Command line, which also shows where it is installed and can remove it again. Either way
it links `/usr/local/bin/rdpm`, asking for an administrator only if that folder is not
already writable.

From a checkout:

```bash
scripts/install-cli.sh          # or: scripts/install-cli.sh ~/bin
```

`rdpm` ships inside `RDP Manager.app`, so it travels with the app and needs no separate
build. The script links `/usr/local/bin/rdpm` to the copy in the bundle, which means
replacing the app updates the command too. On a Mac that has the app installed this is all
it does; it only builds if no app can be found.

`rdpm` starts sessions from the same machine list the app keeps, so an address the app
recorded seconds ago is the one it uses. It only reads the file.

```bash
rdpm ssh nas                    # connect, in the terminal you are already in
rdpm ssh nas -- -A -L 8080:localhost:80   # anything after -- goes to ssh
rdpm ip nas                     # 192.168.1.9
rdpm list office                # filter by name, hostname, group or tag
rdpm show nas                   # everything known, including IP history
rdpm version                    # the version of the app it came from
ssh "$(rdpm ip shop-pc)"        # compose it yourself
```

A name matches exactly first, then by hostname, then by prefix, then by substring, so `nas`
still means `nas` when `nas-backup` exists. Two matches and no exact one is an error rather
than a guess, because guessing opens a session on the wrong machine.

It reads `--store <path>`, else `$RDP_MANAGER_STORE`, else the folder set in the app's
Settings, else the default location. Exit status is 0 fine, 1 no such machine or unreadable
list, 2 a malformed command line. `rdpm ssh` replaces itself with `ssh`, so the exit status
and Ctrl-C behave as if you had typed the ssh command.

## Install on another Mac

```bash
scripts/package.sh
```

This produces `dist/RDP-Manager-<version>.zip` with a universal (Apple Silicon and Intel)
Release build. On the other Mac:

1. Copy the zip over (AirDrop, a share, or a USB stick) and double-click it to unzip.
2. Drag `RDP Manager.app` into `/Applications`.
3. Open it. A notarized build opens normally, with no Privacy & Security detour.
4. Allow notifications when asked, and install Windows App from the App Store if you
   prefer it over the bundled FreeRDP.
5. For the `rdpm` command, use **RDP Manager → Install Command Line Tool…**. No
   checkout and no build is needed: the binary is already inside the app.

If the build was not notarized, macOS refuses the first launch instead: open System
Settings → Privacy & Security, scroll to the message about RDP Manager and click
**Open Anyway**, or clear the quarantine flag with
`xattr -dr com.apple.quarantine "/Applications/RDP Manager.app"`.

Notes:

* The bundled FreeRDP is Apple Silicon only (it comes from Homebrew on the build Mac).
  On an Intel Mac the app runs, but RDP needs Windows App. The app checks the Mach-O
  header before offering FreeRDP, so an Intel Mac is told to use Windows App rather
  than being handed a binary its CPU cannot start.
* Machine passwords live in each Mac's own Keychain and are not part of the zip or the
  shared machine list. Enter them once per Mac.
* To share one machine list, point every Mac at the same folder in Settings → Storage.

### Signing and notarization

`package.sh` signs the app, the bundled FreeRDP and `rdpm` with the Developer ID
certificate it finds in the Keychain, with the hardened runtime and a secure timestamp,
then checks both before going further. Debug builds stay ad-hoc signed, so building and
testing needs no certificate and CI keeps working.

Notarization needs a credential profile, stored once per Mac. It takes an
**app-specific password** from [appleid.apple.com](https://appleid.apple.com), not the
Apple ID password:

```bash
xcrun notarytool store-credentials notarytool \
  --apple-id you@example.com --team-id YOURTEAMID
```

With that in place `package.sh` submits the zip, waits for the result, staples the ticket
to the app and zips it again, so the app validates on first launch without a network
round trip. Without it the app is still signed and the script says what to run, which is
the only difference between a build that opens cleanly and one that needs **Open Anyway**.

Useful overrides: `SIGN_IDENTITY` to choose a different certificate, `NOTARY_PROFILE` for
another profile name, `SKIP_NOTARIZE=1` to sign without submitting.

## Using it

* **Add a machine** with ⌘N. Name, hostname (or IP), type, and how to connect are enough.
  Username and password are optional; the password goes into this Mac's Keychain only.
* **Click a machine's name** in the list to connect with its primary method. Right-click
  for the other methods, Wake-on-LAN, copy IP, edit, and delete.
* **Status** is checked every 30 seconds (Settings → General). A TCP connection to the
  service port counts as online, so Windows machines that block ping still show correctly.
* **IP changes** are logged per machine (Details → IP History) and announced with a
  notification, as are machines going offline or coming back.
* **Share the list** from Settings → Storage by pointing the app at a folder on a network
  share or in iCloud Drive. Other Macs running the app pick up changes within seconds.
  Passwords are never written to that file.
* **SSH terminal** is chosen in Settings → Connections. Warp is used when it is installed,
  otherwise `ssh://` goes to macOS, which means Terminal. Pick iTerm, Ghostty or any other
  terminal to override it, **Choose…** an app that is not listed, or pick System default to
  hand `ssh://` back to macOS.
* **Menu bar** item lists every machine for quick connections while the window is closed.

## Layout

```
RDPManager/
  App/        entry point, app delegate
  Models/     Machine, connection types, status
  Store/      JSON persistence, file watching, cross-Mac merge
  Services/   resolver, prober, monitor, Keychain, Wake-on-LAN, launcher, notifications
  Views/      SwiftUI windows, sheets, settings, menu bar
  CLI/        rdpm, the command-line companion (embedded in the app bundle at build time)
Tests/        unit tests for the store, SSH launching, executable architectures,
              network discovery and the CLI's machine lookup
scripts/      run.sh, test.sh, install-cli.sh, package.sh, bundle-freerdp.sh, make-icon.sh
project.yml   xcodegen project definition
```
