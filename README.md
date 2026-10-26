# RDP Manager

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
xcodegen generate
xcodebuild -project RDPManager.xcodeproj -scheme RDPManager -configuration Release -derivedDataPath build/DerivedData build
scripts/bundle-freerdp.sh "build/DerivedData/Build/Products/Release/RDP Manager.app"
```

The last step copies `sdl-freerdp` and its libraries into the app so it works on Macs
without Homebrew. Then drag `RDP Manager.app` to `/Applications`.

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
scripts/      bundle-freerdp.sh
project.yml   xcodegen project definition
```
