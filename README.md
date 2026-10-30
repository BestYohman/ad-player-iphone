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
  - Play together: a Join button appears when someone starts something with Play together on; with Play together on
    here, what she starts also plays on the other phone. The buttons, lock screen and headphones work for both phones.
  - The audio is downloaded to the phone in the background while it plays, and when the connection drops it carries
    on by itself from the same place.

- Version 1.4:
  - Play together: Stop stops it for everyone (Leave is there to drop out and let the others carry on). Nobody is
    skipped ahead to catch up any more - a phone that is ahead waits for the others. After a skip, everyone waits
    until every phone has got there. When playing together, the audio is all on the phone before it starts.
  - Audiobooks come onto the phone a piece at a time: the piece it starts in first, then the next ones while it plays.

It talks to the PC on port 5021, the same as the AD Player web page.

The app is built on GitHub's Macs, so no Mac is needed. It is installed with AltStore using a free Apple ID, and AltStore re-signs it every 7 days.

---

## 1. Put this folder on GitHub (once)

1. Sign in at https://github.com. A free account is fine.
2. Press **+** (top right), then **New repository**.
   - Name it `ad-player-iphone`.
   - Choose **Public**, so the iPhone can download the app without signing in. Nothing private is in these files; the PC's address is typed into the app, not stored here.
   - Leave everything else as it is, and press **Create repository**.
3. On the empty repository page, click **uploading an existing file**.
4. Open this folder in File Explorer. Select everything in it: the `ADPlayer` folder, the `.github` folder, `project.yml` and `README.md`. Drag them onto the page, then press **Commit changes**.
   - If the `.github` folder doesn't upload, follow the steps under "If the .github folder didn't upload" at the end of this guide.
5. Open the **Actions** tab. If GitHub asks, press the button to enable workflows.
   - "Build the iPhone app" runs by itself every time files change, and takes about 5 minutes.
   - A **green tick** means it worked.
   - A **red cross** means it didn't. Click the run, and the page shows a **Build errors** box. Copy everything in it and send it to Claude.
6. When it's green, go to the **Code** tab. Under **Releases** on the right, open **AD Player (latest)**. `ADPlayer.ipa` is the app.

## 2. AltServer on the media PC (once)

AltServer runs on the PC that is always on, which is the one running describealign. It keeps the app signed.

1. Install **iTunes** and **iCloud** from Apple's website. The Microsoft Store versions don't work with AltServer; https://altstore.io links to the right ones.
2. Install **AltServer for Windows** from https://altstore.io, and start it. It sits in the system tray by the clock.
3. To make it start with Windows, press Windows key + R, type `shell:startup`, and put a shortcut to AltServer in that folder.
4. Connect the iPhone to the PC with a cable. Unlock it, and tap **Trust**.
5. In iTunes, select the iPhone. Under **Summary**, tick **Sync with this iPhone over Wi-Fi**, then press **Apply**. This lets AltStore refresh the app over Wi-Fi later.
6. Click the AltServer tray icon, choose **Install AltStore**, pick the iPhone, and sign in with an Apple ID. Yours is fine; it doesn't have to be hers.
7. On the iPhone:
   - Go to **Settings > General > VPN & Device Management**. Tap your Apple ID, then **Trust**.
   - Go to **Settings > Privacy & Security > Developer Mode**. Turn it **On**, and let the phone restart.

## 3. Install AD Player on the iPhone

1. On the iPhone, open Safari and go to the **AD Player (latest)** release page from step 1.6. Tap **ADPlayer.ipa**, then **Download**. It goes to Files, in the Downloads folder.
2. Open **AltStore**. Go to **My Apps**, press **+** (top left), and choose **ADPlayer.ipa**.
3. Open **AD Player**.
   - Type the PC's address, the same one the AD Player web page uses, for example `192.168.1.20:5021`.
   - Press **Connect**.
   - When iPhone asks to find devices on the local network, choose **Allow**.

## Keeping it working

- **The 7-day refresh is automatic** while three things are true: the iPhone and the PC are on the home Wi-Fi, AltServer is running, and iTunes Wi-Fi sync is on. AltStore's **My Apps** shows how many days are left, and **Refresh All** does it right away.
- **If the app ever won't open,** it has expired. Open AltStore and press **Refresh All** while she's at home. Her settings and place are kept.
- **Updates:** upload the changed files to GitHub the same way (they replace the old ones), and wait for the green tick. Then install the new `ADPlayer.ipa` with AltStore's **+**. Settings are kept.
  - For the audiobooks update (version 1.1): upload the whole `ADPlayer` folder (it has a new file, `BookPlayer.swift`), `project.yml` and `README.md`.
- **Free Apple ID limit:** 3 sideloaded apps per phone, and AltStore counts as one.

## If the .github folder didn't upload

1. On GitHub, open the **Actions** tab and choose **set up a workflow yourself**.
2. Name the file `build.yml`.
3. Open `.github/workflows/build.yml` from this folder in Notepad. Paste its whole contents into GitHub, and press **Commit changes**.
