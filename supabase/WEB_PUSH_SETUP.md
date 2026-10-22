# Optional device notifications and home-screen badges

Prepared for owner deployment. No hosted SQL, schedules, subscriptions or real push messages have been created by Codex.

## Behavior and limits

- Both employees and managers opt in at **hamburger → Notifications → Notifications on this device**. Consent is per personal browser/device and separate from email preferences. No permission prompt appears automatically. Shared-device mode must be off first in Account & team settings; switching it on removes this browser's subscription. Signing out, including inactivity sign-out while the app is running, unsubscribes and clears the badge/delivered alerts best-effort. Never enable push on a shared store computer/tablet.
- Installed icon badges use the existing unread in-app notifications total across the person's active stores. A visible app updates its aggregate badge when its inbox refreshes; on a closed app, new push alerts set the latest count. Reading on another device does not send an invisible push to clear a closed phone's badge: it catches up at the next alert or app refresh. Badges depend on OS/browser support and user notification settings, not every browser tab/icon can show them.
- Push alerts cover the existing in-app notification sources, including private Team support messages, training reminders, first-login manager notices and admin updates. Existing store/role/selected-manager privacy rules apply. A new notification after opt-in triggers a generic count-only alert; existing unread items are baselined without a historical alert burst. Multiple new items may be grouped into one alert per device. Delivered alerts replace the previous colTRAIN alert. Push is an additional channel; email behavior is unchanged, including Emergency manager emails.
- Lock screens show only “You have N unread updates. Sign in to view them.” No employee/customer names, store name, private subjects, message bodies, access tokens or sign-in links are transmitted in the push payload. The link opens the fixed colTRAIN Notifications inbox and requires normal authentication. No auth tokens or message content are cached by the service worker.
- iPhone/iPad: iOS/iPadOS 16.4+; install colTRAIN to the home screen, launch from that icon, use a personal-device setting, then opt in. Android: use an up-to-date supported browser; home-screen installation is recommended for an app icon. Desktop support varies. Browser/OS permission denial is handled with settings guidance. Existing in-app and email channels keep working without push.
- Scheduled scans run each minute, up to 50 devices/scan with a 45-second work budget. Each user can register up to 10 personal browsers/devices. This is sized for the pilot, not a guaranteed immediate/emergency delivery channel. Delivery depends on connectivity, OS settings and push provider. Failed deliveries retry after five minutes; leases recover after five minutes; 404/410 endpoints are removed. Stable notification tags coalesce retry duplicates; Web Push is at-least-once and delivery/receipt cannot be guaranteed. No analytics/open tracking is added.
- Unsubscribing/sign-out should be performed online when possible. Offline sign-out still attempts browser unsubscribe and local clearing; already in-flight notifications cannot be recalled. Closing a personal app without signing out preserves its push subscription intentionally.

## 1. Database update

Open Raw contents of `supabase/migrations/202610220020_web_push.sql`, copy into a new Supabase SQL Editor query and Run once after 019. Expect **Success. No rows returned**. Do not rerun SETUP.sql or older migrations. All subscription/key material stays in private RLS tables; browser RPCs can register/status/remove only the current person's subscription. Privileged scans and completion are service-role only. No store/admin overrides expose subscriptions.

## 2. Generate signing keys securely

Download **`supabase/generate-web-push-keys.html`** using GitHub's Download raw file and open the downloaded HTML on your computer. Click **Generate keys** once. The file runs entirely locally with network connections blocked. Save the two generated values in your password manager; do not put them in chat, SQL, GitHub, Netlify or website configuration.

In Supabase → Edge Functions → Secrets add:

| Name | Value |
| --- | --- |
| `WEB_PUSH_PUBLIC_KEY` | Generated public key |
| `WEB_PUSH_PRIVATE_KEY` | Matching generated private key |
| `WEB_PUSH_SUBJECT` | `mailto:updates@coltrainlearning.com` |

Reuse your existing `COLTRAIN_APP_URL` (actual HTTPS website root), `SUPPORT_WORKER_SECRET` and matching Vault `coltrain_support_worker_key`. Do not change them. Public key is deliberately delivered to authenticated browsers by the configuration action; private key never goes to a browser.

Keep the same signing keys across deployments. If you intentionally rotate keys, disable/re-enable each device's notifications to enroll with the new key pair. The library creates encrypted Web Push and VAPID signatures using pinned `npm:web-push@3.6.7`; no paid push service or Resend credits are used for push. Supabase function/database usage and hosting still apply.

## 3. Deploy the function

Supabase → Edge Functions → Deploy new function → Via Editor. Replace the sample **index.ts** contents with all Raw contents of **`supabase/web-push-function.ts`**. Set the function name to exactly **web-push** before deploying. Verify the actual URL ends `/functions/v1/web-push`.

Settings → **Verify JWT with legacy secret OFF** → Save. The configuration action verifies the signed-in user; scheduled delivery verifies the private worker credential before service operations. Keep all other functions unchanged.

## 4. Schedule background delivery

Cron, pg_net and Vault were enabled for Team support. Copy Raw contents of **`supabase/WEB_PUSH_SCHEDULE.sql`** into a new SQL Editor query and Run. Expect a job ID. In Integrations → Cron, confirm **coltrain-web-push** is enabled. Rerunning this query updates that named job without duplicating it. The endpoint is prepared for project flhdeftduysnjvqnhhee.

Check job run history and web-push function invocations: a SQL job/network enqueue alone does not prove authentication or provider acceptance. A 401 worker response means Edge/Vault worker credentials do not match. A 503 means signing/app configuration is missing. Do not paste private keys in logs or chat.

## 5. Upload the website once

Download `design/coltrain-website.zip` → unzip → existing Netlify site → Deploys → upload the extracted folder → wait for Published → refresh colTRAIN. Existing home-screen installs may need closing/reopening to pick up the updated service worker. Keep the site public and continue using colTRAIN authentication.

## 6. Controlled phone test

1. On a personal phone, open the installed colTRAIN app. In Account & team settings turn off **This is a shared store device** and save. Notifications → Enable device notifications → Allow the OS prompt. No email preference changes are necessary.
2. Close/background the app. From a different account/browser, send that user a new ordinary Team support message. Allow a minute or two for the scheduler/phone. Expect a generic colTRAIN alert and, where supported, the unread icon badge. The text should contain no private message details. Existing unread notifications at opt-in do not send a historical burst.
3. Tap the alert. Confirm it opens colTRAIN Notifications and requires sign-in if needed. A different signed-in user must never see the intended recipient's content.
4. Read the notification and check badge refresh while the app is open. Count may change if training reminders resolve. A closed second device catches up on next alert/open, not silently in real time.
5. Turn device notifications off; send another test message and confirm only in-app notifications arrive. Re-enable and then sign out: badge/alerts should clear and future pushes to this browser stop. Confirm shared mode blocks opt-in. Other personal devices and email preferences are unaffected.
6. Check an employee and manager on real supported phones. Local browser mocks cannot establish Apple/Google push delivery, iOS home-screen behavior or physical badge rendering. Report only the error text/status, never signing/worker secrets.

## Local verification

`python tests/web-push-database.py` runs all migrations and verifies owner-only registration/status/removal, selected-recipient notification snapshots, SSRF endpoint rejection, opt-in baseline, leases/retries, read-state totals, revoked memberships, expired endpoints and restoration of impersonated identity. No hosted database is used.

`node --test tests/web-push-handler.test.mjs tests/web-push-worker.test.mjs` tests verified configuration, worker authentication, encrypted request generation using the real library (no outbound HTTP), privacy-safe payload, retry/expiry and fixed same-origin links. `python tests/web-push-ui.py` checks personal-device consent, denial/shared-device blocks, badge calls, cleanup and iPhone guidance with mocked browser push. Full PWA/training regressions verify package/auth/in-app compatibility.
