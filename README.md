# AD Player for iPhone

A small iPhone app for the AD Player in `describealign_ultimate.py`. It can:

- Choose a TV, or this phone (just the audio).
- Show Continue watching, Shows, Movies and Search.
- Play with audio description and resume where she left off.
- Control the TV, or play on the phone with lock-screen controls.
- Go to the next episode, and say where she is ("Where am I?").
- Play audiobooks from Audiobookshelf, through the PC: Continue listening, All books, Series, Authors and Search.
  - On the phone: chapters, speed, a sleep timer and the lock-screen controls. Her place is saved to Audiobookshelf.
  - Or on the TV that's listed as "DLNA with audio description".
  - The audiobook parts only appear once Audiobookshelf is set up in the admin page's Settings.

- Version 1.2:
  - She signs in once with her Emby user name and password (the phone stays signed in).
  - At home it connects straight to the PC; away from home it uses the web address typed in.
  - Play together: a Join button appears when someone starts something to play together (with the Play together
    button beside Play). The buttons, lock screen and headphones work for both phones.
  - The audio is downloaded to the phone in the background while it plays, and when the connection drops it carries
    on by itself from the same place.

- Version 1.4:
  - Play together: Stop stops it for everyone (Leave is there to drop out and let the others carry on). Nobody is
    skipped ahead to catch up any more - a phone that is ahead waits for the others. After a skip, everyone waits
    until every phone has got there. When playing together, the audio is all on the phone before it starts.
  - Audiobooks come onto the phone a piece at a time: the piece it starts in first, then the next ones while it plays.

- Version 1.5: audiobook bookmarks (Audiobookshelf's own, so they also show in its apps). While a book plays: Add a
  bookmark here, and Bookmarks - each one plays from there; Rename and Remove are VoiceOver actions on each bookmark.

It talks to the PC on port 5021, the same as the AD Player web page.

- Version 1.9: made for VoiceOver - each row is one stop with its buttons as actions (swipe up or down), Magic Tap
  (two-finger double tap) plays and pauses, the escape gesture closes Now playing, and Siri can play, resume and say
  where she is ("Play in AD Player", "Resume AD Player", "Where am I in AD Player").

The app is built on GitHub's Macs, so no Mac is needed. It is installed with Sideloadly on the PC using a free Apple ID, and has to be signed again every 7 days (Sideloadly can do that by itself).

---

## 1. Put this folder on GitHub (once)

1. Sign in at https://github.com. A free account is fine.
2. Press **+** (top right), then **New repository**.
   - Name it `ad-player-iphone`.
   - Choose **Public**, so the iPhone can download the app without signing in. Nothing private is in these files; the PC's address is typed into the app, not stored here.
   - Leave everything else as it is, and press **Create repository**.
3. On the empty repository page, click **uploading an existing file**.
4. Open this folder in File Explorer. Select everything in it: the `ADPlayer` folder, the `.github` folder, `project.yml`, `README.md` and `CHANGELOG.md`. Drag them onto the page, then press **Commit changes**.
   - If the `.github` folder doesn't upload, follow the steps under "If the .github folder didn't upload" at the end of this guide.
5. Open the **Actions** tab. If GitHub asks, press the button to enable workflows.
   - "Build the iPhone app" runs by itself every time files change, and takes about 5 minutes.
   - A **green tick** means it worked.
   - A **red cross** means it didn't. Click the run, and the page shows a **Build errors** box. Copy everything in it and send it to Claude.
6. When it's green, go to the **Code** tab. Under **Releases** on the right, open **AD Player (latest)**. `ADPlayer.ipa` is the app.

## 2. Sideloadly on the PC (once)

Sideloadly runs on the Windows PC. It signs the app with an Apple ID and puts it on the iPhone.

1. Install **iTunes** and **iCloud** from Apple's website (not the Microsoft Store versions - Sideloadly's page links to the right ones).
2. Install **Sideloadly** from https://sideloadly.io.
3. Connect the iPhone to the PC with a cable. Unlock it, and tap **Trust**.
4. In iTunes, select the iPhone. Under **Summary**, tick **Sync with this iPhone over Wi-Fi**, then press **Apply**. This lets Sideloadly reach the iPhone over Wi-Fi later.

## 3. Install AD Player on the iPhone

1. On the PC, open the **AD Player (latest)** release page from step 1.6 and download **ADPlayer.ipa**.
2. Open **Sideloadly**. Drag `ADPlayer.ipa` onto it, pick the iPhone, type the Apple ID (yours is fine; it doesn't have to be hers), and press **Start**. Type the Apple ID's password when asked.
3. On the iPhone, the first time:
   - Go to **Settings > General > VPN & Device Management**. Tap the Apple ID, then **Trust**.
   - Go to **Settings > Privacy & Security > Developer Mode**. Turn it **On**, and let the phone restart.
4. Open **AD Player**.
   - Type the PC's address, the same one the AD Player web page uses, for example `192.168.1.20:5021`.
   - Press **Connect**.
   - When iPhone asks to find devices on the local network, choose **Allow**.

## Keeping it working

- **Every 7 days the app has to be signed again** (a free Apple ID allows 7 days). In Sideloadly, turn on automatic refresh for the app (in its advanced options, or by right-clicking the app in Sideloadly's list); then, while the PC is on with Sideloadly running and the iPhone is on the home Wi-Fi, it re-signs by itself.
- **If the app ever won't open,** it has expired. Connect the iPhone to the PC (or have it on the home Wi-Fi) and install `ADPlayer.ipa` again with Sideloadly. Her settings and place are kept.
- **Updates:** upload the changed files to GitHub the same way (they replace the old ones; include `CHANGELOG.md`), and wait for the green tick. Then download the new `ADPlayer.ipa` and install it with Sideloadly the same way. Settings are kept.
  - Each new version needs a new version number in `project.yml` (and a part for it at the top of `CHANGELOG.md`): the build stops if that version was already published from different files.
- **Free Apple ID limit:** 3 sideloaded apps per phone.
- **Siri:** say "Play in AD Player" (Siri asks what to play), "Resume AD Player" or "Where am I in AD Player". They are also in the Shortcuts app.

## If the .github folder didn't upload

1. On GitHub, open the **Actions** tab and choose **set up a workflow yourself**.
2. Name the file `build.yml`.
3. Open `.github/workflows/build.yml` from this folder in Notepad. Paste its whole contents into GitHub, and press **Commit changes**.
