# Pilot preparation: home-screen installation

The owner applied 009 and deployed the notification website. They confirmed the screen appears correct; live notification delivery remains pending a new unfinished assignment or changed deadline. Do not rerun migrations 001–009.

This update adds a colTRAIN icon and standalone web-app launch, an **Add to home screen** button on sign-in, and the same entry in the employee/manager hamburger menu. It does not require a database, Auth callback, SMTP, Edge Function, app-store listing, or secret change.

## Owner deployment

Download the latest `design/coltrain-website.zip` from GitHub branch `codex/coltrain-prototype`, choose **Download raw file**, extract it, then upload the **whole extracted folder** to the existing Netlify site **stalwart-custard-7be489 → Deploys**. Keep the `accounts` subfolders and `_headers` file together. Refresh the hosted `/accounts/` page after deployment.

The ZIP now contains **eleven explicitly allowed public files**, rather than the previous three HTML files: the root redirect, real accounts page, sample preview, Netlify headers, manifest, service worker, four PNG icons, and SVG favicon. No SQL, account sources, test fixtures, invitation function, secret keys, or passwords are packaged. `scripts/build-hosting.py` copies the public assets; `npm run build:accounts` embeds the installation UI.

## Phone acceptance

Use the actual HTTPS website, rather than a downloaded HTML file or an embedded preview.

- **iPhone/iPad:** open the site in Safari; choose **Add to home screen** inside colTRAIN for instructions. In Safari tap **Share** (square with upward arrow), then **Add to Home Screen**. Leave **Open as Web App** enabled if offered, then tap **Add**. The Apple touch icon and app title are declared explicitly. Safari may place Share in different locations depending on the version/layout.
- **Android:** open the site in Chrome. Choose colTRAIN's **Add to home screen**. If **Install colTRAIN** is available, tap it; otherwise use Chrome's three-dot menu → **Add to home screen** or **Install app**, then confirm. Browsers decide whether to offer a native prompt; it is not forced on page load. A dismissed prompt falls back to manual steps and never prevents use of the website.
- **Desktop:** Chrome/Edge can offer installation through their address-bar icon or browser menu. The guidance includes this path.

Confirm the colTRAIN icon and label appear on the home screen. Close the browser view, tap the icon, and verify the website opens as its own app window where supported. Sign in and verify the expected Home/Dashboard, Notifications, and Team Corner. Confirm sign-out works before switching users on a shared device. Sessions remain in the existing session-storage mechanism; reopening may require sign-in.

Use airplane mode, then reopen/reload the icon: expect the public **You're offline** page and reconnect instructions. Restore connectivity and tap **Try again**. Courses, quizzes, and posts still require internet access. Auth callback links should continue to open in the browser from email; installation does not change where invitation or reset links redirect.

The local browser tests cannot prove an icon was installed on a physical phone or bypass Netlify site-access restrictions. External employee access without the owner's Netlify login remains a separate pilot acceptance requirement. Future custom website domains must be added to the existing Auth redirect allowlist separately; the installation assets themselves use same-origin relative URLs and do not hardcode the Netlify host.

## Scope, privacy, and updates

- Manifest `id`, `start_url`, and `scope` are `/accounts/`, with `display: standalone`. Callback query parameters/tokens are never copied into the installation start URL or icon identity. `/preview/` remains separate sample data.
- Icons are committed opaque PNGs at 192, 512, and 180 pixels, plus a safe maskable 512 icon and SVG favicon. The blue C/arrow mark stays inside the maskable safe area. Normal builds need no image dependency. `python scripts/build-pwa-icons.py` regenerates the PNGs using Pillow if the mark changes.
- `accounts/sw.js` controls only `/accounts/`. It uses network-only navigation with `cache: no-store` and a public static offline fallback. It does not write to CacheStorage, cache API responses/photos/courses/tokens, intercept Supabase requests, or introduce push notifications or background sync.
- The fallback has no user-specific data and does not reflect the requested URL/query. Its **Try again** link uses the clean `/accounts/` URL; if an email account-setup link was opened offline, reopen that original email link after reconnecting.
- Netlify `_headers` gives the manifest its correct MIME type, limits service-worker scope, disables worker caching, and revalidates the main app page. The worker claims clients on activation but does not cache old HTML bundles, so a subsequent online navigation fetches the current website. It does not force a reload in the middle of a quiz or post draft.
- The browser's normal open-page memory and session-storage behavior remain; installation does not change seat membership, staff permissions, or the requirement to sign out on shared hardware.

## Local verification

`python tests/pwa-ui.py` serves the real packaged website from an ephemeral local origin using a disposable normal Chromium profile. It verifies manifest/icon paths and sizes, the eleven-file public allowlist, Chromium installability without errors, real service-worker registration/scope, no CacheStorage, public offline/reconnect behavior with no callback-query reflection, simulated native-prompt acceptance/dismissal, standalone detection, and mobile instructions including iPad's desktop user agent. It closes its browser/server/profile afterward. It does not install an app on a physical device or send Supabase requests.

`python tests/account-ui.py` checks existing account/auth/nickname flows with mocked responses. `python tests/training-ui.py` checks the real local SQL/RLS training/competition/feed/notification flows and installation guidance from both employee and manager menus. These mocked-Auth suites block service workers deliberately; real worker behavior is exercised in the dedicated test. Static manifest/icon requests are served locally by the mocks rather than escaping to the network.

No SQL migrations changed, so the existing database suite need not be repeated for this UI/hosting update. New notification and general hosted pilot tests remain as described in `PILOT_NOTIFICATIONS.md`. Optional email delivery, further shared-device safeguards, and rollout are later Step 5 tasks.
