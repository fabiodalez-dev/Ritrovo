# Ritrovo

Ritrovo is a native macOS app for recovering photos, videos and documents from disks, memory cards, USB drives and disk images: a deleted folder, a formatted card, a drive that is starting to fail.

**The recovery engine is [PhotoRec](https://www.cgsecurity.org/wiki/PhotoRec) by Christophe Grenier (CGSecurity).** Ritrovo is only an interface: every file is found and rebuilt by the PhotoRec command line program bundled inside the app, so recovery results are the same as PhotoRec's own. Ritrovo is not an official CGSecurity product. This repository is a fork of [cgsecurity/testdisk](https://github.com/cgsecurity/testdisk); the app lives in [`macos/`](https://github.com/fabiodalez-dev/Ritrovo/tree/main/macos).

The interface is in English and Italian: English by default, Italian (or the system language) in Ritrovo › Settings.

![Choosing what to recover from a memory card](https://github.com/fabiodalez-dev/Ritrovo/raw/main/macos/screenshots/setup.png)

## Download

Get `Ritrovo-<version>.dmg` from the [latest release](https://github.com/fabiodalez-dev/Ritrovo/releases/latest), open it and drag Ritrovo to Applications. Universal app (Apple Silicon and Intel), macOS 13 or later.

The app is signed ad-hoc, not with an Apple Developer ID. The first time, right click on Ritrovo in Applications and choose Open.

## How it works

1. **Pick a source.** Physical disks appear in the sidebar by themselves when a card or drive is connected. A disk image (`.img`, `.dd`, `.dmg`, `.iso`, `.raw`) can be opened, dropped on the window or sent with Open With.
2. **Choose what to look for.** Photos, videos, audio, documents, archives, or any of the 349 formats one by one. An image filter skips thumbnails and web images.
3. **Recover.** The progress shows read speed, remaining time and read errors. The Mac does not sleep during a recovery, and a stopped recovery can be resumed later.
4. **Browse the results.** A gallery with Quick Look, search and sorting; tools to organize files by type (photos renamed after their capture date), set duplicates aside and export a CSV list.

The source is only ever read: Ritrovo never writes to it, and warns when the destination folder is on the disk being recovered.

![Recovery in progress](https://github.com/fabiodalez-dev/Ritrovo/raw/main/macos/screenshots/recovery.png)

![Recovered files](https://github.com/fabiodalez-dev/Ritrovo/raw/main/macos/screenshots/results.png)

## Features

- Physical disks, updated automatically; disk images; eject from the sidebar
- Partitions as detected by the engine, with every table type (auto, Intel/MBR, GPT, Apple, none, Sun, Xbox, Humax)
- File types by category or one by one, with search
- Image filters: minimum width, height, megapixels and file size, presets "no thumbnails" and "real photos"
- Every engine option: whole or free space, file check (normal, off, deep JPEG rebuild), keep corrupted files, ext2/3/4 mode with start group or inode, FAT unformat (names and folders back after a quick format), block size, low memory, disk geometry, detailed log
- Byte for byte copy of a failing disk into an image, then recovery from the copy, so the disk is read only once
- History of recoveries; a stopped recovery can be resumed
- Notification, sound and Dock badge when a recovery ends; keyboard shortcuts (⌘O, ⌘R, ⌘., ⇧⌘F, ⇧⌘R)
- Light and dark appearance
- English and Italian interface, chosen in Settings (⌘,)

![Choosing the interface language](https://github.com/fabiodalez-dev/Ritrovo/raw/main/macos/screenshots/language.png)

| Formats | Advanced options | Dark appearance |
|---|---|---|
| ![Every format, by category](https://github.com/fabiodalez-dev/Ritrovo/raw/main/macos/screenshots/formats.png) | ![Every engine option](https://github.com/fabiodalez-dev/Ritrovo/raw/main/macos/screenshots/advanced.png) | ![Results in dark appearance](https://github.com/fabiodalez-dev/Ritrovo/raw/main/macos/screenshots/dark.png) |

## Security

Reading a raw disk needs root, so PhotoRec runs as root after the standard macOS administrator prompt, and only to read a physical disk: disk images are always read as the user. The helper script creates the destination folder itself, refuses existing folders and symbolic links, makes the engine write only inside that folder, and gives the files back to the user at the end. Details and the known limit of an ad-hoc signed app are in [`macos/README.md`](https://github.com/fabiodalez-dev/Ritrovo/blob/main/macos/README.md#security).

## Build and tests

Requirements: Xcode command line tools, Homebrew `autoconf automake libtool pkgconf cmake`, python3.

```sh
macos/build-app.sh
cd macos/Ritrovo && swift run RitrovoCoreTests
```

The end to end self test drives the real app through every screen and takes the screenshots on this page. See [`macos/README.md`](https://github.com/fabiodalez-dev/Ritrovo/blob/main/macos/README.md#tests).

## License

GNU General Public License, version 2 or later, like PhotoRec. See [`COPYING`](https://github.com/fabiodalez-dev/Ritrovo/blob/main/COPYING). The original TestDisk and PhotoRec README is [`README.md`](https://github.com/fabiodalez-dev/Ritrovo/blob/main/README.md) at the root of the repository.
