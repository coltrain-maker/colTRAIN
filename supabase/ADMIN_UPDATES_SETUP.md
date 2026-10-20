# Admin updates: in-app and opt-in email

Prepared for owner setup; no hosted announcements, emails, SQL changes or website deployments were performed by Codex.

## What is included

Only colTRAIN administrators can compose/send/archive updates. Audience choices are Managers only, Employees only, or Managers and employees. Store choices use the owner's requested labels: **To all stores** or **Select individual stores**. All stores means current stores and active members at send time; future joiners do not inherit old updates. Roles are rechecked when reading and emailing, so demoted managers cannot retain manager-only inbox access.

Each selected active member receives an in-app notification regardless of their email preference. Only people with `optional_email_notifications=true` are queued for email. Consent, active membership, role, archival and current email are checked again immediately before delivery. Existing private store feeds, training records, points/trophies and account permissions are unchanged.

Admin sees a recipient preview before an explicit Send update action, delivery counts/history, and Archive/Retry controls. Archive removes the in-app update and cancels emails that have not been claimed; it cannot recall email already accepted by a provider. Messages cannot be edited after sending. Read counts refer to in-app acknowledgement, not email opens. Provider acceptance is not proof of inbox delivery.

## 1. Supabase database

1. Open the existing coltrain-development project → SQL Editor → New query.
2. Open `supabase/migrations/202610200014_admin_updates.sql` in GitHub, choose Raw, and copy the entire file.
3. Paste into the new query and select Run. Expect **Success. No rows returned**.
4. Run migration 014 once only. Do not rerun earlier migrations or SETUP.sql. This creates empty message/recipient/email-queue tables; it does not send any update or email.

All new tables are in the private schema with RLS enabled and client privileges revoked. Only validated public RPCs and the worker can use them. Training notification read receipts continue to work.

## 2. Email provider and secure configuration

The prepared worker uses **Resend's sending API**. Existing Supabase Auth SMTP settings do not automatically supply an Edge Function's API key. If another provider is currently used, confirm whether to add Resend or adapt the worker before attempting an actual email send. In-app updates and their queue work independently; missing email configuration is shown explicitly rather than reported as sent.

In Supabase → Edge Functions → Secrets, add these using the secure dashboard fields:

- `RESEND_API_KEY`: a Resend sending API key authorized for the verified sending domain. Obtain it from Resend's API Keys page; do not paste it into chat, the SQL editor, GitHub, Netlify or a browser configuration file.
- `COLTRAIN_EMAIL_FROM`: a sender under your verified domain, for example `colTRAIN <updates@coltrainlearning.com>`. Use a domain verified for sending in Resend. This example does not assert that the mailbox exists or receives replies.
- `COLTRAIN_APP_URL`: reuse the already working invitation function's hosted site URL, such as `https://stalwart-custard-7be489.netlify.app`. It must be the website root over HTTPS with no extra path, query, credentials or fragment. Do not change the working value unnecessarily.

Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to its functions. Do not place the service key in the website. No invitation/password function or Auth template needs replacing.

If Resend has a domain or account restriction, resolve it in Resend before sending to real recipients. Actual deliverability, domain authentication and provider-account access cannot be verified from the local tests.

## 3. Deploy the separate admin-update Edge Function

1. Supabase → Edge Functions → create a new function using the code editor.
2. Open its existing `index.ts`. Select all and replace the example code with the entire contents of `supabase/admin-update-function.ts`. Do not add a second file or paste the SQL migration into this editor.
3. Set the function name to **admin-update** before deploying. Verify its endpoint actually ends in `/functions/v1/admin-update`; changing only a display name does not change an older slug.
4. Deploy the function.
5. Open its Settings. Turn **Verify JWT with legacy secret** OFF and save. This is required for the current signing setup; the handler independently validates the session with Auth and checks platform-admin permission before any service-role queue access.
6. Keep `invite-employee` unchanged. These are separate functions.

CLI alternative for a developer: `supabase functions deploy admin-update --no-verify-jwt`. Canonical source is `supabase/functions/admin-update/`; `node scripts/build-admin-update-function.mjs` regenerates the single-file dashboard version. Neither contains secret values.

## 4. Upload the website once

After the database and email function are ready, download `design/coltrain-website.zip` from GitHub using Download raw file, unzip it and upload the entire extracted folder to the existing Netlify site's Deploys page. Wait for Published and refresh the live `/accounts/` page. The ZIP includes all previous navigation/tagline/course-selection and Daily Drill changes; no separate upload for those is needed.

## 5. Controlled acceptance test

Use accounts/emails you control for the initial messages. Sending from the live admin screen creates real notifications and may email all selected opted-in members; carefully preview role/store counts before selecting Send update.

1. Sign in as administrator → hamburger → Training group → **Admin updates**.
2. Write a short title/message, choose **Managers only**, choose **Select individual stores**, and select only the pilot store. Preview recipients, review the in-app/email counts, then Send update.
3. Check the manager's Notifications and opted-in test email. The employee should not see that managers-only message.
4. Test Employees only, then both roles, using the same controlled scope. A personal-email opt-out must still receive the in-app update and must not receive email.
5. Test To all stores only when you intend to contact all current stores. There is no silent default to all stores.
6. Mark an in-app update read, sign out/back in and confirm the receipt persists. Managers/employees cannot compose updates or inspect other people's receipts.
7. Check delivery history. Accepted email requests are separate from queued, failed, processing, canceled or needs-review states. Archive a test update to remove it from in-app inboxes.

The first implementation sends emails in bounded batches while the admin request/page remains active. Keep the page open until delivery status finishes. Closing the page or losing connectivity can leave emails queued. Use **Refresh delivery status**, then **Retry email delivery** after correcting any configuration/provider error. There is no independently scheduled/background email worker yet; this limitation is shown through delivery status rather than hiding unsent email.

Submission UUIDs and provider idempotency keys prevent duplicate messages/emails during request retries. A delivery whose first attempt is older than 23 hours is held for manual review, because Resend's idempotency retention is 24 hours. Do not create a replacement broadcast merely to retry a questionable email; first check the provider log. No raw email addresses, keys or provider payloads are returned in recipient inboxes or admin summaries.

## Local verification

- `python tests/admin-updates-database.py`: 43 isolated PostgreSQL checks for role/store isolation, preview-only behavior, independent read receipts, direct table restrictions, consent and role/deactivation checks, worker leases, archive, idempotent concurrent sends, current-store snapshots and old-delivery review.
- `node --test tests/admin-update-handler.test.mjs`: Auth/admin/CORS checks, recipient-only delivery, stable provider idempotency keys, provider errors and missing-configuration queuing; all HTTP email calls are mocked.
- `python tests/admin-updates-ui.py`: actual local SQL/RLS and Chromium across admin/manager/employee roles and two stores; preview/edit/send, exact store labels, role-specific inboxes, links, escaped plain text, read persistence, mobile and archive. Edge email delivery is stubbed locally.
- Existing database suite: 346 assertions and concurrency checks passed with migration 014 installed. Existing training and PWA checks cover the combined website package.

No live email or hosted test announcement is sent by these tests.
