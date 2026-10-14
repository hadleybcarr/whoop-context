# Context

A concept page for the WHOOP app. It lines your Google Calendar up against your heart rate, so every event becomes a "thread": the bar length shows how far your heart rate rose above your daily baseline (stress, 0–3, the same scale as WHOOP's Stress Monitor). A separate ML model then learns which kinds of events stress you and which ones make you happy.

```
web/            the page (plain HTML/CSS/JS, no build step)
  js/scoring.js   event × heart-rate scoring (also used by Node for the dataset)
  js/calendar.js  Google Calendar, read-only
  js/heartrate.js heart-rate CSV import
  js/demo.js      demo calendar and heart rate
ios/            native SwiftUI version (Xcode project)
ml/train.py     stress and mood models → insights.json for both versions
serve.py        server for web/ + WHOOP sign-in, WHOOP data proxy, per-user training
```

## Unscheduled time

Calendar events always come first. Each stretch of free time between them becomes one "Unscheduled" block, scored as an average over the whole stretch. The day runs from when you woke up (rounded down to the hour) to your usual bedtime (rounded up to the hour). Gaps under 15 minutes are skipped.

Tap a block, pick a start and end time inside it, and name what you were doing to turn that time into an event you can rate. Events added this way are stored on the device. If a calendar is connected, they can also be added to it.

Wake times come from sleep data (the demo data includes them). Without it, the day runs from 7am to 11pm.

## iOS app

`ios/FinalThread.xcodeproj` is a native SwiftUI version of the page (iOS 17+). It starts on demo data.

- **Calendar** reads the iPhone's calendars through EventKit, which includes any Google accounts added in Settings, so no Google client ID is needed.
- **Health** reads heart rate and sleep from Apple Health, where WHOOP writes them when its Health sync is turned on.
- **Export** (gear menu) shares the same `events_labeled.csv` as the web page.
- The round **W** button opens Thread Coach, which shows what the ML model learned.

### Run in the Simulator on your Mac

```bash
cd ios
xcodebuild -project FinalThread.xcodeproj -target FinalThread -sdk iphonesimulator -configuration Debug SYMROOT=build build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true   # already booted is fine
open -a Simulator
xcrun simctl install "iPhone 17 Pro" build/Debug-iphonesimulator/FinalThread.app
xcrun simctl launch "iPhone 17 Pro" com.finalthread.app
```

To see your simulators, run `xcrun simctl list devices available`. Use the device's name rather than `booted`: if more than one simulator is running, `booted` can pick a different one (an iPad, say) from the one you're looking at.

### Run on your iPhone

The easiest way is Xcode:
1. Open `ios/FinalThread.xcodeproj`.
2. Under the FinalThread target, go to **Signing & Capabilities** and pick your Team.
3. Change the bundle ID to something unique, like `com.yourname.finalthread`.
4. Plug in your phone, select it as the run destination, and press Run.

On the phone, turn on **Settings → Privacy & Security → Developer Mode**. The first time, also trust the developer certificate under **Settings → General → VPN & Device Management**.

From the command line instead (after choosing a team once in Xcode):

```bash
xcrun devicectl list devices
cd ios
xcodebuild -project FinalThread.xcodeproj -target FinalThread -sdk iphoneos -configuration Debug -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID PRODUCT_BUNDLE_IDENTIFIER=com.yourname.finalthread SYMROOT=build build
xcrun devicectl device install app --device YOUR_DEVICE_ID build/Debug-iphoneos/FinalThread.app
xcrun devicectl device process launch --device YOUR_DEVICE_ID com.yourname.finalthread
```

Your Team ID is under Xcode → Settings → Accounts. Signing may fail on the HealthKit entitlement with a free Apple ID. If it does, clear **Code Signing Entitlements** in Build Settings. The app still runs; only the Health connection is turned off.

## Run the page

```bash
ml/.venv/bin/python serve.py
```

Then open http://localhost:8000. It starts on demo data. (Plain `python3 serve.py` also works, but the "Train my model" button needs the ml venv.)

## Connect real data (web)

**Google Calendar**

Tap **Google Calendar** in the gear menu. There are two ways to connect:
- **Private link (works for anyone, no setup).** Every Google Calendar has a read-only "Secret address in iCal format" (Google Calendar → Settings → your calendar → Integrate calendar). Paste it in the sheet. The server fetches it, since browsers can't load Google's `.ics` files directly, and expands repeating events. The address stays in that visitor's browser and is re-read each time the page opens. The server only fetches `https://calendar.google.com/….ics` addresses. Some work and school accounts hide this option.
- **Sign in with Google.** This appears once the site has a Google OAuth client ID, and it can also add events you name from unscheduled time. To set it up:
  1. In Google Cloud Console, enable the Google Calendar API.
  2. Create an OAuth client ID of type "Web application".
  3. Add `http://localhost:8000` (and your deployed URL) as authorized JavaScript origins.
  4. Put the client ID in `.env` as `GOOGLE_CLIENT_ID` (or set it on your host), or paste it into `web/js/config.js`.

  Sign-in only asks for read access (`calendar.readonly`). It asks for write access only when you add an event to the calendar.

**WHOOP**

Tap **WHOOP** in the gear menu. The sheet that opens offers three paths:
- **Your own WHOOP app (the default).** WHOOP only shares data with apps registered to a WHOOP account, so each person with WHOOP sets up their own. The sheet walks them through it: create an app at https://developer-dashboard.whoop.com, turn on the read scopes for profile, sleep, workouts, recovery and cycles, add the redirect URL it shows (with a copy button), then paste the client ID and secret. The keys stay in that visitor's server session only.
- **The site owner's app.** If the server has `WHOOP_CLIENT_ID` and `WHOOP_CLIENT_SECRET` (copy `.env.example` to `.env`), visitors just see "Sign in with WHOOP".
- **No WHOOP account: Use sample data.** This adds sample recovery, HRV, resting heart rate and strain that match the demo calendar. Recovery dips after stressful days, so training has a real pattern to find. The choice is remembered until you pick "Stop using sample WHOOP data".

Signing in happens on the server, since WHOOP's token exchange needs the client secret. Tokens live in server memory, keyed by an HttpOnly cookie, so restarting the server signs everyone out. Once connected:
- Sleep sets each day's wake time and your usual bedtime.
- Workouts appear as events with their strain and heart rate, and count as physical activity.
- Each day shows that morning's recovery, HRV and resting heart rate, plus the day's strain.
- **Train my model** trains on your own data on the server. It trains the event stress model when there are 15+ events with heart rate, and a **next-morning recovery** model (your calendar on one day → WHOOP recovery the next morning) once there are 10+ days of calendar plus WHOOP (or sample) recovery. The result is stored in your browser and shown on the INSIGHTS screen.

On INSIGHTS, **Drains** are the events with the highest predicted stress and **Lifts** the lowest. Both come from heart rate alone, not from the "How did it feel?" ratings.

WHOOP's API has no minute-by-minute heart rate, so per-event stress still needs a heart-rate import (below).

**Heart rate:** use the gear menu's "Import heart rate" with any CSV that has a time column and a bpm column. An optional `stress` column is read too; otherwise stress is worked out minute by minute from heart rate. WHOOP's public API gives daily summaries (recovery, sleep, strain), not minute-by-minute heart rate. Apple Health is the easiest route: WHOOP writes heart rate there when that sync is on.

## Put it online

The repo includes a `Dockerfile` (page, WHOOP backend and training in one container) and a Render Blueprint (`render.yaml`). Once deployed, anyone with the link can use it: on demo data right away, with sample WHOOP data, or with their own WHOOP and Google Calendar.

**Render (free tier, easiest)**
1. Put this folder in a GitHub repo:
   ```bash
   git init && git add . && git commit -m "Context" && git branch -M main
   git remote add origin https://github.com/YOU/final-thread.git && git push -u origin main
   ```
2. On https://dashboard.render.com choose **New → Blueprint**, pick the repo and apply. Render builds the Dockerfile and gives you a URL like `https://final-thread.onrender.com`. Nothing else is needed for demo and sample data.
3. Optional, in the service's **Environment** tab:
   - `GOOGLE_CLIENT_ID`: lets visitors connect Google Calendar. On the Google OAuth client, add the Render URL as an authorized JavaScript origin.
   - `WHOOP_CLIENT_ID` and `WHOOP_CLIENT_SECRET`: only if you have a WHOOP app to share. Then its redirect URL is `https://whoop-context-web.vercel.app/auth/whoop/callback`. Without them, each visitor sets up their own WHOOP app from the in-page guide, which shows them the redirect URL to use.

The free tier sleeps after 15 minutes without visitors, so the first load after that takes about a minute. A restart also signs everyone out of WHOOP (see below).

**Frontend on Vercel, backend on Render**

Vercel can host the page (project root: `web/`) while Render runs the backend. `web/vercel.json` forwards `/api/*`, `/auth/*` and `/js/config.js` to Render, so the browser only ever talks to your Vercel domain. That keeps the WHOOP sign-in cookie first-party and needs no cross-site (CORS) setup.
1. In `web/vercel.json`, check the three `destination` URLs match your Render URL (they assume `https://final-thread.onrender.com`).
2. On Render, `PUBLIC_URL` must be the Vercel URL, `https://whoop-context-web.vercel.app`. `render.yaml` sets it, so a Blueprint deploy picks it up; on a service made another way, add it under **Environment**. The server uses it for the WHOOP redirect URL and accepts requests from that page.
3. The WHOOP redirect URL (callback URL) is `https://whoop-context-web.vercel.app/auth/whoop/callback`; the in-app guide shows it too. The Google OAuth client's authorized JavaScript origin is `https://whoop-context-web.vercel.app`.

Render's free tier sleeps after 15 idle minutes. The first WHOOP or calendar request after that can time out on Vercel's side while Render wakes up; trying again works.

**Anywhere else that runs Docker** (Railway, Fly.io, a VPS):
```bash
docker build -t final-thread .
docker run -p 8000:8000 -e PUBLIC_URL=https://your-app.example final-thread
```
On Railway and Fly.io, `PUBLIC_URL` is worked out automatically. Serve it over HTTPS: the session cookie is marked Secure when `PUBLIC_URL` is https.

**What the server does for other people's safety**
- Visitors' WHOOP tokens and pasted app keys stay server-side, tied to an HttpOnly cookie. They are never sent back to the browser.
- Sign-in checks a random `state` value, and POSTs from other sites are refused.
- Idle sessions are dropped after 30 days, and at most 5,000 are kept.
- Only two trainings run at once; other requests are told to try again.
- There are no directory listings, and the page can't be framed by other sites.

**Before relying on it with real users:** sessions live in memory in one process, so a restart or redeploy signs everyone out. Move tokens to a database (encrypted) and add a privacy policy. Google also needs to verify the app before more than the 100 test users you list on the OAuth consent screen can connect a calendar.

## Labels

| label | where it comes from |
|---|---|
| `stress` (0–3) | Your average heart rate during the event compared with your awake baseline (the 10th percentile of that day's heart rate from 7am to 11pm). Workouts are excluded, because a higher heart rate there means effort, not stress. |
| `feeling` (−2…+2) | The "How did it feel?" rating on each event. Heart rate measures how worked up you are, not whether it was pleasant, so happiness needs a self-report. |

## Train the model

```bash
python3 -m venv ml/.venv && ml/.venv/bin/pip install -r ml/requirements.txt
ml/.venv/bin/python ml/train.py
```

`train.py` reads `ml/data/events_labeled.csv` (the file the page's "Export labels" button saves). If that file doesn't exist, it uses `ml/data/demo_events.csv`. To regenerate the demo file, run `node web/js/export_demo.mjs 60 > ml/data/demo_events.csv`.

It fits two ridge regressions on event features: title words (TF-IDF), time of day, weekday, duration, attendee count, and whether the event is recurring. Both are cross-validated by day. The results go to `web/insights.json`, which the INSIGHTS tab displays.

To plot training vs validation loss (MAE) and accuracy (share of events within ±0.5):

```bash
ml/.venv/bin/pip install -r ml/requirements-plots.txt
ml/.venv/bin/python ml/plot_curves.py
```

This writes `ml/plots/learning_curves.png` (error vs number of training events) and `ml/plots/alpha_curves.png` (error vs ridge regularization strength). Ridge regression is solved in one step, so there are no epochs; these two curves show the same over/underfitting picture.
