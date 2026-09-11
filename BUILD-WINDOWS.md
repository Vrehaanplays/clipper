# Windows → IPA → AltStore

You have a Windows laptop, an iPhone 17, and AltStore. No Mac. Here is exactly what that
means and exactly what to do.

---

## 0. The honest part first

**One stage genuinely cannot happen on Windows: compiling the app.**

Building an iOS app requires the iOS SDK, and Apple ships the iOS SDK only inside Xcode,
only on macOS, under a licence that forbids redistributing it. There is no Windows iOS
toolchain. Anything claiming otherwise is either a cross-platform framework (React Native,
Flutter — which you explicitly ruled out) or does not exist. Swift itself is open source
and runs on Windows, but the iOS SDK, the `iphoneos` platform, `xcodebuild`, the asset
catalog compiler and the Info.plist compiler are not.

**The workaround is a rented macOS machine that you never touch: GitHub Actions.** You
push the source from Windows, a macOS runner compiles it, and you download a finished
`.ipa`. It is free for this, takes about four minutes, and you never open Xcode.

**Signing is not a problem at all**, which is the nice surprise. AltStore signs apps
itself, on your behalf, with your own Apple ID. So CI produces an **unsigned** IPA and
AltStore does the rest. No certificates, no provisioning profiles, no `$99`, no secrets in
CI, no Mac.

So: the build is remote, the signing is local, and nothing needs Xcode.

---

## 1. Required project files

Everything is already in this repo:

| File | Purpose |
|---|---|
| `project.yml` | the project definition (XcodeGen). CI turns this into `Clipper.xcodeproj`. |
| `Clipper/Info.plist` | bundle metadata, background mode, microphone permission string |
| `Clipper/*.swift` | the app |
| `Clipper/Assets.xcassets` | app icon (1024×1024) and accent colour |
| `.github/workflows/build-ipa.yml` | the macOS build job |

There is deliberately **no `.xcodeproj`** and **no `.entitlements`** file. See §2 and §5.

## 2. Required entitlements

**None.** This is worth stating clearly because it is the thing that makes the whole plan
work:

- Background audio recording is **not** an entitlement. It is the `UIBackgroundModes` →
  `audio` key in `Info.plist`. No provisioning profile capability, no Apple approval.
- Microphone access is a **privacy prompt**, driven by `NSMicrophoneUsageDescription`.
  Also not an entitlement.

So Clipper needs no paid developer account, and nothing in it blocks free-Apple-ID
signing. Adding an entitlements file (app groups, iCloud, push, keychain sharing) is
exactly what *would* break AltStore signing with a free account — so the project has none.

## 3. Info.plist configuration

The keys that matter, all already set in `Clipper/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>

<key>NSMicrophoneUsageDescription</key>
<string>Clipper records audio from the microphone to build a rolling buffer of
short clips stored only on this iPhone.</string>

<key>UIRequiredDeviceCapabilities</key>
<array><string>arm64</string><string>microphone</string></array>

<key>UIFileSharingEnabled</key>          <false/>
<key>LSSupportsOpeningDocumentsInPlace</key> <false/>
<key>ITSAppUsesNonExemptEncryption</key> <false/>
```

`UIBackgroundModes: audio` plus an active `AVAudioSession` is the entire mechanism that
keeps recording alive with the screen off. Omit either one and iOS suspends the app within
seconds of backgrounding.

## 4. Bundle identifier

Currently `com.clipper.recorder`, set in `project.yml`.

**Change it before you sideload.** Pick something personal — `com.yourname.clipper`. Two
reasons:

1. A free Apple ID can register only **10 App IDs per 7-day period**, and they are
   registered globally against the identifier. A generic one risks a collision.
2. If you ever reinstall, keeping the same identifier preserves the recordings (a
   different one installs a second, empty app).

Edit one line in `project.yml`:

```yaml
PRODUCT_BUNDLE_IDENTIFIER: com.yourname.clipper
```

## 5. Signing requirements

| | Free Apple ID | Paid ($99/yr) |
|---|---|---|
| Works with AltStore | yes | yes |
| App expires after | **7 days** | 1 year |
| Apps sideloaded at once | 3 | unlimited |
| New App IDs per week | 10 | unlimited |
| Needs a Mac | no | no |

AltStore refreshes the 7-day signature automatically while AltServer is running on your
laptop and the iPhone is on the same Wi-Fi network. If Clipper stops opening, it needs a
refresh, not a rebuild.

Your iPhone also needs **Developer Mode** on, because AltStore signs with a development
certificate: *Settings → Privacy & Security → Developer Mode → on*, then reboot. (The
toggle only appears after a development-signed app has been installed once, or after the
device has been connected to a signing tool.)

## 6. Windows-compatible build options

Ranked by what I would actually do:

**A. GitHub Actions (recommended, free, already configured)**
macOS runners, 2000–3000 free minutes/month on a private repo and unlimited on a public
one. The workflow in this repo is ready. ~4 minutes per build.

**B. Codemagic free tier**
500 macOS build minutes/month, no Apple account needed for an unsigned build. Useful as a
fallback if you hit Actions limits.

**C. Rent a cloud Mac** — MacinCloud / MacStadium, ~$20–30/month. Only worth it if you
want an interactive Xcode for debugging.

**D. Borrow a Mac for ten minutes.** `xcodebuild` once, keep the IPA.

**Not options:** any "compile iOS on Windows" toolchain, WSL, or Swift-for-Windows. WSL
gets you the Swift compiler, not the iOS SDK.

## 7. IPA creation

An `.ipa` is just a zip containing `Payload/YourApp.app/`. That is all. The workflow does:

```bash
xcodebuild -project Clipper.xcodeproj -scheme Clipper \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

mkdir Payload && cp -R build/Build/Products/Release-iphoneos/Clipper.app Payload/
zip -qry Clipper.ipa Payload
```

Note it uses `build`, not `archive` + `exportArchive` — export insists on a signing
identity, and we deliberately have none.

### Running it from Windows

```bash
cd "D:\ssh or api\Clipper"
git init
git add .
git commit -m "Clipper: rolling-buffer background audio recorder"
gh repo create clipper --private --source=. --push
```

(Or create the repo on github.com and `git remote add origin … && git push -u origin main`.)

The build starts on push. Then:

```bash
gh run watch
gh run download --name Clipper-unsigned-ipa
```

You now have `Clipper.ipa` on your laptop. Without the `gh` CLI, download it from the
run's **Artifacts** section in the browser — note GitHub wraps artifacts in a `.zip`, so
unzip it to get the `.ipa`.

## 8. AltStore sideloading

AltStore needs **AltServer** on Windows, and AltServer needs two Apple components that
must be the **direct downloads from apple.com, not the Microsoft Store versions** (the
Store builds are sandboxed and AltServer cannot talk to them):

1. **iTunes for Windows** — the standalone installer from apple.com/itunes.
2. **iCloud for Windows** — the direct download, not the Store app.

Then:

1. Install AltServer from `altstore.io`. It lives in the system tray.
2. Connect the iPhone by USB (Lightning/USB-C cable), unlock it, tap **Trust**.
3. In iTunes, enable **Sync with this iPhone over Wi-Fi** — this is what lets AltStore
   refresh the signature later without a cable.
4. Tray icon → **Install AltStore** → your iPhone. Enter your Apple ID. (Use an
   app-specific password if you have 2FA and the normal one is rejected.)
5. On the iPhone: *Settings → General → VPN & Device Management* → trust your developer
   certificate.
6. Enable Developer Mode (§5) and reboot.

## 9. Device installation

1. Copy `Clipper.ipa` to the iPhone — AirDrop won't work from Windows, so use iCloud
   Drive, the Files app over a USB connection, or just email it to yourself and save it to
   Files.
2. Open **AltStore** on the iPhone → **My Apps** → **+** (top left) → pick `Clipper.ipa`.
3. AltStore signs it with your Apple ID and installs it. First launch will ask for
   microphone permission — allow it.
4. Tap **Start**, lock the phone, and check that the orange mic dot stays lit.

### A realistic warning about iOS 26

AltStore Classic + AltServer on Windows is a long-standing but fragile chain, and it has
historically needed an update after each major iOS release. Your iPhone 17 ships with
iOS 26. **Check the AltStore release notes for current iOS 26 support before you spend an
evening on the iTunes/iCloud setup.** If AltServer is behind:

- **SideStore** (`sidestore.io`) is the better bet. It is an AltStore fork that, after a
  one-time pairing-file setup, refreshes apps **on-device** with no computer on the network
  — which removes the whole iTunes-on-Windows dependency and the "must be on the same
  Wi-Fi" constraint. The unsigned IPA from CI is the same file; only the installer changes.
- In the EU, **AltStore PAL** is Apple-notarized and installs without any of this, but it
  distributes only apps its developers publish — you cannot load your own IPA into it.

The IPA this project produces is installer-agnostic. Any sideloading tool that signs with
your Apple ID will take it.

## 10. Troubleshooting

**CI build fails on an iOS 26 API** — `Views/GlassStyle.swift` is guarded with
`#if compiler(>=6.2)`, so it compiles against older SDKs too and simply falls back to
system materials. If it still fails, the runner has an Xcode older than 16; pin a newer
image with `runs-on: macos-26`.

**`No .app produced`** — read the `xcodebuild` step's log; the real Swift error is above
the packaging step.

**AltStore: "Could not find AltServer"** — the iPhone and laptop are on different Wi-Fi
networks, AltServer isn't running, or Wi-Fi sync was never enabled in iTunes. Plug the
cable in and retry.

**AltStore: "Maximum number of apps installed"** — a free Apple ID allows 3. Remove one.

**AltStore: "This app cannot be installed because its integrity could not be verified"** —
Developer Mode is off (§5), or the certificate isn't trusted yet (§8 step 5).

**Clipper won't open after a week** — the 7-day free signature expired. Open AltStore →
My Apps → **Refresh All**. Your recordings are untouched.

**Recording stops when the screen locks** — means `UIBackgroundModes: audio` didn't make it
into the built bundle. The CI job prints it in the *Sanity-check the bundle* step; confirm
it's there.

**Recording stops after a phone call** — it shouldn't; the recorder re-activates the
session and restarts the engine, and a 15-second watchdog retries if the system never
sends interruption-ended. If it genuinely stays stuck, the UI will honestly show
`Interrupted` rather than pretending to record.

**No clips appear** — clips only appear when a segment *finishes*. With the 5-minute
default, the first clip lands at 5:00. Set clip length to 1 minute in Settings to test the
rotation quickly.

---

## What I could not verify from Windows

I wrote and reviewed this code, but **I could not compile it** — there is no Swift
compiler or iOS SDK on this machine, which is the same constraint the rest of this
document is about. The first CI run is the compile check. If it reports an error, paste the
log and I'll fix it; expect the odd type-inference or availability nit rather than an
architectural problem.
