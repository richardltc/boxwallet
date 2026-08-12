BoxWallet for macOS (Apple Silicon)
===================================

To run: unzip this folder somewhere, open Terminal in it, and run

    ./boxwallet-gui

Keep the slint-… folder beside the program — it holds the graphics library, and
BoxWallet will not start without it. Moving boxwallet-gui out on its own breaks
that pairing; move or copy the whole folder instead.

This build is for Apple Silicon (M1 and later). Intel Macs are not supported by
the graphics library we depend on, and Rosetta cannot help — it translates Intel
to Apple Silicon, not the other way around. On an Intel Mac, use the terminal
version instead: boxwallet-macos-x86_64 on the release page.


If macOS refuses to open it
---------------------------

You will probably see "cannot be opened because the developer cannot be
verified", or "is damaged and can't be opened". Neither means the download is
broken. macOS attaches a quarantine flag to anything downloaded through a
browser, and refuses to run it unless Apple has notarized it.

The simplest fix is to unzip from Terminal rather than by double-clicking the
zip in Finder:

    unzip boxwallet-gui-macos-aarch64.zip

Finder's unarchiver copies the quarantine flag onto every file it extracts; the
unzip command does not, so the folder it produces just runs.

If you already unzipped it in Finder, clear the flag on the folder:

    xattr -dr com.apple.quarantine boxwallet-gui-macos-aarch64

Do this on the whole folder, not just the program — the graphics library is
quarantined too, and the app cannot load it while it is.

Why this isn't automatic: notarization means uploading each build to Apple for
scanning, which requires a paid Apple Developer account. BoxWallet is signed,
but only ad-hoc — the kind of signature Apple Silicon requires of any program
before it will run at all. That satisfies "this binary has not been altered
since it was built"; it does not satisfy "Apple has seen this build". Verifying
the checksum below tells you the same thing notarization would, from the
publisher rather than from Apple.


Verifying your download
-----------------------

Every release publishes SHA256SUMS. To check the zip you downloaded:

    shasum -a 256 boxwallet-gui-macos-aarch64.zip

Compare the result against the matching line in SHA256SUMS on the release page.


Updating
--------

BoxWallet updates itself: it checks for new releases, verifies the download
against the release's SHA256SUMS, and confirms the new version actually starts
before switching to it. If anything fails that check, it keeps the version you
have. Updates it installs are not quarantined, so this only ever comes up for a
zip you downloaded yourself. You can also just download a newer zip and unpack
it over this folder.
