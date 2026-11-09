# Doppelganger

Doppelganger mounts folders from SSH servers at the same paths on your Mac. Scripts and configuration files that use absolute paths run unchanged on the Mac and on the server.

Doppelganger runs [sshfs](https://github.com/libfuse/sshfs) on [macFUSE](https://macfuse.github.io). When the connection drops, sshfs reconnects the next time a program uses the mount. Open files and Terminal windows in the mount keep working.

## Install

Doppelganger requires macOS 15 or later, macFUSE with its kernel extension allowed, and an SSH login to the server without a password prompt.

Download the zip from the [latest release](https://github.com/shamus-li/doppelganger/releases/latest), unzip it, and open the app. macOS blocks the first launch because Apple has not notarized the app. To allow the launch, click Open Anyway under System Settings → Privacy & Security.

## License

Doppelganger is licensed under the [GNU General Public License v2.0](LICENSE).
