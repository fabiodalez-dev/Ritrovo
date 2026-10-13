# Ritrovo

Ritrovo is a native macOS app (SwiftUI) for recovering photos, videos and documents from disks, memory cards and disk images.

**The recovery engine is [PhotoRec](https://www.cgsecurity.org/wiki/PhotoRec) by Christophe Grenier (CGSecurity).** Ritrovo is only an interface: every file is found and rebuilt by the PhotoRec command line program bundled inside the app, so recovery results are the same as PhotoRec's own. Ritrovo is not an official CGSecurity product.

## Features

- Physical disks (updated automatically when a card or drive is connected), disk images opened, dropped or sent with "Open With"; eject from the sidebar
- Partitions as detected by the engine, with every table type (auto, Intel/MBR, GPT, Apple, none, Sun, Xbox, Humax)
- File types by category (photo, video, audio, documents, archives, other) or one by one, with search
- Image filters: minimum width, height, megapixels and file size, presets "no thumbnails" and "real photos"
- Every engine option: whole or free space, file check (normal, off, deep JPEG rebuild), keep corrupted files, ext2/3/4 mode with start group or inode, FAT unformat, block size, low memory, disk geometry, detailed log
- Live progress with read speed, remaining time and read error warnings; the Mac does not sleep during a recovery
- Gallery of recovered files: categories, search, sort, Quick Look (space), multiple selection, drag to the Finder, copy to a folder
- Results tools: organize by type (optionally renaming photos by capture date), move duplicates aside, export a CSV list
- History of recoveries; a stopped recovery can be resumed
- Byte for byte copy of a failing disk into an image, then recovery from the copy
- Notification, sound and Dock badge when a recovery ends; settings remembered between launches; keyboard shortcuts (⌘O, ⌘R, ⌘., ⇧⌘F, ⇧⌘R)
- Light and dark appearance, Italian interface

## How it works

- The app runs the bundled engine (`ritrovo-engine`, built from this fork) in batch mode (`/cmd`), reads its progress from the JSON log and watches the output folders.
- Its working files are hidden in the recovery folder: `.ritrovo.ses` (session), `.ritrovo.log`, `.ritrovo-progress.jsonl`.
- Stopping sends SIGINT: the engine saves its session, which the app can resume later.

## Tests

- `cd macos/Ritrovo && swift run RitrovoCoreTests`: logic tests. A base suite plus 57 named tests (`Tests/RitrovoCoreTests/ReviewTests.swift`) for formats, categories, filters and sorting, partitions, the engine command line, JSON events, incremental log reading, folder scanning, organizer, duplicates, CSV, speed, history, saved settings, resume sessions, gallery selection, privileges and shell quoting.
- End to end self test of the installed app, without clicks, with a screenshot of every screen. The disk images come from a script, no administrator rights needed:

```sh
python3 macos/tools/make_selftest_images.py /tmp/ritrovo-fixtures
RITROVO_SELFTEST="/tmp/ritrovo self test" RITROVO_SELFTEST_IMAGE=/tmp/ritrovo-fixtures/selftest.img RITROVO_SELFTEST_FAT=/tmp/ritrovo-fixtures/fat.img /Applications/Ritrovo.app/Contents/MacOS/Ritrovo
```

The output folder has a space on purpose: the resume step then covers paths with spaces. The result is in `report.txt` next to the screenshots.

## Security

Reading a raw disk needs root, so PhotoRec runs as root after the macOS administrator prompt. The helper script `ritrovo-run.sh` creates the destination folder itself, refuses an existing folder or a symbolic link, makes PhotoRec write only inside that folder with relative paths, only checks the stop request for existence, and gives the files back to the user with `chown -R -P`. `RITROVO_*` development variables are ignored for anything run as root.

Known limit: the script and the engine binary run as root from the app bundle, which belongs to the user. Malware already running as that user could modify them before the user types the password. The proper fix is a privileged helper installed with `SMAppService` and checked by its code signature, which needs a Developer ID: planned for the signed releases.

## Build

Requirements: Xcode command line tools, Homebrew `autoconf automake libtool pkgconf cmake`, python3.

```sh
macos/build-app.sh
```

The result is `build-macos/app/Ritrovo.app` and a DMG, universal (Apple Silicon and Intel), macOS 13 or later. The app is signed ad-hoc: on another Mac the first launch needs right click, Open (or removing the quarantine attribute), until it is signed with a Developer ID and notarized.


## License

GNU General Public License, version 2 or later, like PhotoRec. See `COPYING`.
