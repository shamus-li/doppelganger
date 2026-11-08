# Doppelganger

A Mac menu bar app that mounts folders from SSH servers at the same paths they have on the server. `/home/you` on the cluster is `/home/you` on your laptop, so scripts and config files with absolute paths work in both places.

Each mount is a patched [sshfs](https://github.com/libfuse/sshfs) on macFUSE, run by a background service. Mounts stay up when you quit the menu bar app or update it.

If the connection drops, the folders stay where they are and sshfs reconnects the next time something uses them. Open files and Terminal windows inside a mount keep working, and writes that were lost get sent again. Nothing is cached for offline use. While the server is unreachable, reads and writes fail after about 5 seconds.

## Install

You need macOS 15 or later, [macFUSE](https://macfuse.github.io) with its kernel extension allowed, and SSH access to the server that doesn't ask for a password.

Download the zip from [Releases](https://github.com/shamus-li/doppelganger/releases) and open the app. It isn't notarized, so macOS blocks it the first time; allow it under System Settings > Privacy & Security. The Setup tab in Settings shows anything else that still needs doing.

Paths outside your home folder, like `/home` or `/scratch`, need Full Disk Access so the app can create them.

## Build

You need Swift 6, macFUSE 5, and `meson`, `ninja`, `pkgconf` and `glib` from Homebrew. Change `IDENTITY` in the `Makefile` to your own signing certificate, then run:

```bash
make install
```

## License

MIT, for the code in this repo apart from `sshfs/patches`. Those patches and the sshfs binary in the release are under sshfs's GPLv2.
