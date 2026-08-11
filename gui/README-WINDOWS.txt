BoxWallet for Windows
=====================

To run: unzip this folder somewhere and double-click boxwallet-gui.exe.
Keep slint_cpp.dll beside it — the app will not start without it.


If nothing happens when you launch it
-------------------------------------

You almost certainly need the Microsoft Visual C++ Redistributable (x64):

    https://aka.ms/vs/17/release/vc_redist.x64.exe

Install that, then try again.

Why this isn't automatic: the graphics library BoxWallet uses is built with
Microsoft's compiler and links Microsoft's C++ runtime, which is not part of
Windows itself. Most machines already have it, because a great many programs
install it — but a clean Windows install does not. When it is missing, Windows
refuses to start the program before any of BoxWallet's own code runs, so there
is no error message we can show you. A silent non-start is what that looks like.

We don't include those files here because Microsoft publishes them only as an
installer that always serves the newest build, with no fixed version to check
against — and BoxWallet verifies everything it ships against a known checksum.
Downloading it from Microsoft directly, as above, is both safer and simpler.


Verifying your download
-----------------------

Every release publishes SHA256SUMS. To check the zip you downloaded:

    certutil -hashfile boxwallet-gui-windows-x86_64.zip SHA256

Compare the result against the matching line in SHA256SUMS on the release page.


Updating
--------

BoxWallet updates itself: it checks for new releases, verifies the download
against the release's SHA256SUMS, and confirms the new version actually starts
before switching to it. If anything fails that check, it keeps the version you
have. You can also just download a newer zip and unpack it over this folder.
