# Employee portal update: enrollment, first-login alerts and Daily points

Prepared for owner deployment. Local tests never contact hosted Supabase, Resend or employees. Applying SQL does not send mail.

## Behavior

- A new active **employee** membership automatically receives all ready, published courses already provided to that store. Academy, role, department and leadership topics do not filter enrollment. The newest published/released version per course slug is used. Drafts, unreleased courses, other stores' private courses and incomplete content are excluded. Existing employees are not bulk assigned by this update. Re-activating an employee fills missing assignments; it preserves existing deadlines, completion, quiz attempts and awards. New deadlines are 30 days in the store's time zone. Managers can continue adjusting deadlines. Later course releases do not silently assign everyone; managers still control existing employees' assignments.
- The first time a newly enrolled employee reaches their authenticated store account, each current active store manager receives a persistent in-app notification. Only managers who enabled optional email receive the email. One event per employee membership and one recipient record per manager prevent duplicate alerts on refresh, two tabs or later logins. Existing memberships are baselined when migration 015 runs so upgrades do not announce historical accounts as newly signed in. The first-login event starts with memberships enrolled **after** 015; an old invitation not yet accepted still creates a new membership on acceptance.
- Login confirmation first saves the event using the signed-in user's identity. The new **employee-login** Edge Function then sends queued messages with Resend. It verifies identity with Auth and ignores caller-supplied identities/addresses. It can process only that employee's event or the signed-in manager's own queued alerts. It sends individual recipient messages, rechecks consent/active manager membership before sending, uses leases and stable provider idempotency keys, and never exposes privileged keys or addresses to the browser.
- Delivery is attempted automatically during entry to the app, up to 20 queue records per request. Outages leave messages queued/failed, and later employee/manager entry retries them. There is **no independent scheduled worker**; a closed page, failed network request or extended outage can delay email until a later entry. In-app delivery does not depend on Resend. Ambiguous delivery attempts older than 23 hours are held for review to avoid duplicates beyond Resend's idempotency window. These are optional operational messages, not security emails.
- Completing a Daily Drill correctly awards **5 points once per person and stable module code**, including previous completions. A revised module version, review, reload, retry or re-hire cannot create another award for the same drill code. Incorrect answers earn zero; a later correct completion earns the full 5 points. There is no speed/streak bonus or penalty. Existing correct completion records get credit using their original completion dates.
- **Lifetime points = course points + Daily Drill points.** The employee dashboard shows all three. Manager progress and the lifetime leaderboard include a separate Daily Drill column; the lifetime leaderboard also shows course points. Existing competition challenge points remain separate. Full-course trophies and the planned final Expertise badge are unchanged.

## Apply to the existing project, in order

1. Supabase → existing **coltrain-development** project → SQL Editor → New query.
2. Open `supabase/migrations/202610220015_employee_onboarding.sql` in GitHub → Raw → copy the entire file. Paste into the new query and Run. Expect **Success. No rows returned**.
3. Use another new query for `supabase/migrations/202610220016_daily_points.sql`, copy all via Raw, and Run. Expect the same success result. Run each migration once; do not rerun SETUP.sql or earlier migrations.
4. Supabase → Edge Functions → Deploy a new function → Via Editor. Replace all sample code in the existing **index.ts** with all contents of `supabase/employee-login-function.ts` (Raw). Do not create an extra file. Name the function **employee-login before deploying** and deploy it. Verify the actual endpoint ends `/functions/v1/employee-login`.
5. In that function's Settings, turn **Verify JWT with legacy secret OFF** and save. Its code independently validates the caller with Auth. Keep invite-employee and admin-update unchanged.
6. Reuse the existing secure Supabase function secrets `RESEND_API_KEY`, `COLTRAIN_EMAIL_FROM` and `COLTRAIN_APP_URL`. No new secret, Resend account, SQL key or Netlify variable is needed. The app URL must match the hosted root and actual browser origin.
7. Download `design/coltrain-website.zip` using GitHub's Download raw file, unzip, upload the entire extracted website folder to your existing Netlify site → Deploys. Wait for Published and refresh colTRAIN. Leave the website public so employees reach colTRAIN's own login; store data still requires authenticated permissions.

## Owner-controlled acceptance test

Use an email/account you control before more staff invitations. Inviting creates a real email; do not use all-store broadcasts for this test.

1. Make sure the pilot manager has optional email enabled. Note the count of ready published courses provided to Coltrain Hardware.
2. Invite a **new employee**, accept on their own device/private browser and create a password. Their My training page should already show those courses with 30-day deadlines. They should have fresh progress and their own points. No unreleased or draft courses should appear as assigned.
3. Sign in as manager. Notifications should include one first-sign-in alert for that employee, and their opted-in email should arrive. Sign the employee out/back in and confirm no duplicate alert/email. Another store's manager must not receive it. Managers who opt out of email still get the in-app alert.
4. Verify prior Daily completions credited 5 each. Complete another Daily Drill: the success screen should show **+5 Daily Drill points earned**, the Daily Drill contribution should increase by 5, and lifetime points should increase by 5. Review it/reload: totals remain the same.
5. Compare employee totals, the manager's Daily Drill column, and the lifetime leaderboard. Course points + Daily Drill points must equal lifetime points. Existing competition scores and course trophies stay as before.
6. A first-login in-app alert without email can mean opt-out, provider limits/configuration, or an interrupted request. Check the employee-login function logs and Resend delivery history. A later app entry retries unsent messages; do not repeatedly invite the employee to retry a manager alert. Provider acceptance is not proof of inbox delivery.

## Local verification

- `python tests/employee-portal-database.py`: 36 real isolated PostgreSQL checks of enrollment/versions/deadlines/reactivation, baseline and concurrent first logins, store/role/consent isolation, delivery leases, retroactive points, failed/correct checks, replay/concurrency, stable code across versions, combined totals and direct access restrictions.
- `node --test tests/employee-login-handler.test.mjs`: Auth/origin isolation, verified-user scoping, provider idempotency, private responses and configuration/provider failures. All email HTTP calls mocked.
- `python tests/daily-ui.py`: real local SQL/RLS + browser, including earned-point feedback, dashboard points, manager column, mobile, review and committed-submission retry.
- Existing database and training/browser suites exercise accounts, seat replacement, permissions, courses, quizzes, competitions, Team Corner, read receipts and account switching with the new migrations installed.

No hosted SQL, website deployment or real test email is performed by these checks. All local database containers are disposable and expose no ports.
