# RDP Manager

[![Tests](https://github.com/dasassygoat/rdp-manager/actions/workflows/tests.yml/badge.svg)](https://github.com/dasassygoat/rdp-manager/actions/workflows/tests.yml)

A macOS utility for the computers on your local network. Add machines by name, and the
app keeps track of their IP addresses as they change, shows whether each is online, and
connects with one click over RDP, VNC, SSH, or a web admin page. See [SPEC.md](SPEC.md)
for the design decisions.

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

## Install on another Mac

```bash
scripts/package.sh
```

This produces `dist/RDP-Manager-<version>.zip` with a universal (Apple Silicon and Intel)
Release build. On the other Mac:

1. Copy the zip over (AirDrop, a share, or a USB stick) and double-click it to unzip.
2. Drag `RDP Manager.app` into `/Applications`.
3. Open it once. Because the app is not notarized, macOS will refuse the first launch.
   Go to System Settings → Privacy & Security, scroll to the message about RDP Manager,
   and click **Open Anyway**. This is needed only once per Mac.

   Alternatively, clear the quarantine flag from Terminal and it opens normally:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/RDP Manager.app"
   ```

4. Allow notifications when asked, and install Windows App from the App Store if you
   prefer it over the bundled FreeRDP.

Notes:

* The bundled FreeRDP is Apple Silicon only (it comes from Homebrew on the build Mac).
  On an Intel Mac the app runs, but RDP needs Windows App.
* Machine passwords live in each Mac's own Keychain and are not part of the zip or the
  shared machine list. Enter them once per Mac.
* To share one machine list, point every Mac at the same folder in Settings → Storage.
* Signing with a Developer ID and notarizing would remove the first-launch warning.
  That needs an Apple Developer account.

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
* **Menu bar** item lists every machine for quick connections while the window is closed.

## Layout

```
RDPManager/
  App/        entry point, app delegate
  Models/     Machine, connection types, status
  Store/      JSON persistence, file watching, cross-Mac merge
  Services/   resolver, prober, monitor, Keychain, Wake-on-LAN, launcher, notifications
  Views/      SwiftUI windows, sheets, settings, menu bar
Tests/        unit tests for the store (merge, IP history, atomic writes)
scripts/      run.sh, test.sh, package.sh, bundle-freerdp.sh, make-icon.sh
project.yml   xcodegen project definition
```
