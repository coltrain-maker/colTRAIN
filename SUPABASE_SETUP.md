# colTRAIN: connect the development project

Project URL: `https://flhdeftduysnjvqnhhee.supabase.co`

The screen prototype remains at the root `index.html`. A separate account foundation has been prepared in `accounts/`. The owner reports that `supabase/SETUP.sql` completed successfully. On October 17, 2026, live read-only checks confirmed that the project's Auth API accepts the supplied publishable key, email sign-in is enabled with email confirmation, and all six account tables reject anonymous reads. Local SQL and mocked browser checks passed. The owner has since verified manager setup and an existing-account email invitation through password setup and an employee membership. First-time invitation delivery hit an Auth rate limit, and a separate status-recording permission repair is prepared; see supabase/EMAIL_INVITATIONS.md. Broad hosted permission isolation, standard signup/recovery flows, and real file uploads still need verification.

## Connected training update

Step 3 is now prepared: a real-account training workspace, private server-side quiz scoring, assignments/departments/deadlines, points/trophies, supported retries, and manager progress. See [Step 3 activation and checks](supabase/TRAINING_SETUP.md). The new migration has **not** been applied to the hosted project by the agent. Apply only `202610170005_training.sql`, then deploy the updated website ZIP to the existing Netlify project.

## Email invitation update

The owner has successfully created the pilot store and joined as its manager. A named email invitation flow is now prepared: managers enter the employee’s name and email; colTRAIN generates the token and reserves a seat; the employee follows the email to choose a password and join. This update still requires the incremental migration, HTTPS hosting, Auth callback configuration, email delivery configuration, and deployment of the server function. See [Email invitation activation](supabase/EMAIL_INVITATIONS.md). Do not rerun full SETUP.sql on the existing project.

## 1. Create the database and access rules

Use the new, empty development project. Do not manually create tables first.

1. Open `supabase/SETUP.sql` from this repository or the file link in chat.
2. Copy all of its contents.
3. In your Supabase project, select **SQL Editor**, then create a **New query**.
4. Paste the script and select **Run**.
5. A successful run normally ends with **Success. No rows returned**. If there is an error, share the error message, not passwords or keys.

If the SQL file is difficult to copy from the chat viewer, use `supabase/coltrain-database-setup.txt`; it has identical contents. The error `query: Too small: expected string to have >=1 characters` usually means the editor submitted empty query text. Check that the SQL is visible, clear any blank selection, and try `select 1;` in a separate query to verify the editor can execute text.

Run this setup once. It intentionally fails rather than overwriting existing tables if run again. The ordered migrations are transactions. If a later migration fails, report the error before rerunning the combined script; earlier successful migrations may already be present.

The setup creates:

- Store organizations, public-name profiles, active/historical memberships, seats, and email-bound invitations.
- A separate administrator registry that ordinary accounts cannot modify.
- Database-enforced role and store isolation; roles do not come from editable signup metadata.
- Single-use, hashed invitation codes with 7-day expiration, revocation, and atomic replacement.
- Seat reservations that prevent simultaneous invitations from claiming the same available seat.
- Store-access removal that releases the seat without deleting the former membership record.
- A private `team-media` bucket for PNG, JPEG, and WebP pictures up to 1 MB. File paths are `organization-id/user-id/filename`.
- Team-picture access for active members of that store, employee control over their own pictures, and manager moderation within their own store. Being a colTRAIN administrator does not automatically grant access to other stores' team pictures.

This step does not create fake employees, issue invitations, charge anyone, or send emails. It does not create the training tables from Step 3 or the shared feed from Step 4.

## 2. Supply the public browser configuration

The owner has now supplied the publishable key, and it is saved in `accounts/public-config.json` alongside the project URL. This is intentionally public website configuration, not a privileged credential. The builder uses it automatically; no manual environment-settings entry is needed for the development page. Environment variables still override these values for other deployments. Never place a secret/service-role key in this file.

`npm run build:accounts` also creates the self-contained `design/coltrain-accounts.html` for viewing the account interface. This page connects to the real development Supabase project; use only your own pilot/test accounts. The original screen prototype continues to use sample data. The environment draft has also been prefilled with the public values, so review/save/publish can be handled when publishing the environment rather than requiring manual key entry now.

In Supabase **Project Settings → API Keys**, locate the **publishable key** (normally begins `sb_publishable_`). Do not use a secret key, service-role key, database password, or personal access token.

In this cloud environment's settings, review the saved configuration fields:

| Variable | Value |
| --- | --- |
| `SUPABASE_URL` | `https://flhdeftduysnjvqnhhee.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | The project's publishable key |

The draft also adds `flhdeftduysnjvqnhhee.supabase.co` to network access. Existing package-manager presets remain intact. Save the settings and publish the environment so the saved configuration and prepared files can be retained. A draft save alone does not update the running process or publish the environment.

Only these public values are needed by the browser. Never enter privileged credentials into the browser build. The build rejects Supabase secret keys and service-role JWTs, including values read from public-config.json.

For a separate local development checkout, copy `.env.example` to `.env.local`, fill in the public URL/key there, then run:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build:accounts
python -m http.server 3000 --bind 0.0.0.0
```

The real account page is the served `/accounts/` path. It must be opened through a working application URL for real callback testing. Chat file previews are suitable for the design prototype, not a substitute for configuring and testing hosted authentication callbacks.

## 3. Configure email confirmation and callbacks

Before real account testing:

1. Keep email confirmation enabled in Supabase Authentication's email-provider settings.
2. Set the password minimum to at least 12 characters to match the account interface.
3. Once the application's served development or deployed URL is known, add its exact `/accounts/` callback URL under Authentication's URL Configuration. Set an appropriate Site URL. Do not add arbitrary wildcard callback origins.
4. Test signup confirmation and password recovery using your own email first. Supabase's default email service has development limits; employee invitations should wait until delivery has been verified. A custom email provider can be configured before the store pilot.

The original downloaded account file uses manually shared codes. The updated account interface has **Employee name**, **Employee email**, and **Send invitation**; this requires the server/email activation steps linked above. Legacy **Replace code** remains manual. Once activated, **Resend invitation** requests a fresh email and invalidates the previous store invitation. Account setup and password-reset emails are essential account messages, separate from optional training/team email preferences.

## 4. Appoint the first administrator

The first administrator is deliberately not assigned automatically to whoever signs up first.

For the initial development owner, before a hosted email callback URL is ready, you can create your own login directly in **Supabase Authentication → Users → Add user → Create new user**, enter your own email and private password, and enable **Auto Confirm User** if offered. This creates a confirmed development owner without depending on an unfinished email redirect. Never share the password in chat. Keep normal signup email confirmation enabled for subsequent employee accounts. This initial owner setup does not test confirmation email delivery.

1. Create your own account in the configured account page.
2. Confirm the email and sign in.
3. In the Supabase SQL Editor, run the following after replacing `YOUR_CONFIRMED_EMAIL` with the email used for your own account:

```sql
insert into public.platform_admins(user_id)
select id from auth.users
where lower(email) = lower('YOUR_CONFIRMED_EMAIL')
  and email_confirmed_at is not null
on conflict (user_id) do nothing;

select user_id from public.platform_admins
where user_id in (
  select id from auth.users where lower(email) = lower('YOUR_CONFIRMED_EMAIL')
);
```

The final query should return your account ID. Refresh the account page. You can now create **Coltrain Hardware** with **10 total pilot seats** (one manager and nine employees), without a billing subscription. This pilot capacity does not finalize commercial pricing or manager-seat billing.

Use the store's invitation form to invite its manager. An administrator may also join a store using an invitation to their own confirmed email; the platform administrator role remains separate. Store managers can invite employees but cannot create manager or administrator roles themselves.

## 5. Verify the live account workflow

After connection, migration, callbacks, and email are configured, verify:

- Your administrator account creates the pilot store and a manager invitation.
- The manager joins with the matching confirmed email, creates an employee invitation, and the employee joins.
- Reusing a code, using a revoked/expired code, or joining with the wrong email is rejected.
- Employee and manager sessions see only permitted records. Test a second store with separate test identities to verify hosted isolation.
- Removing an employee immediately denies store-data/file access; their record remains and their seat can be reassigned.
- Password recovery succeeds without exposing anyone's password.
- Signing out on a shared device clears the active session, and the next person must authenticate.

Local SQL tests exercise the database rules and concurrent seat reservations. Browser tests use mocked Supabase responses and send no real emails. Neither test establishes that the hosted project is ready until the live checks above pass.

## Current limits

- Courses, points, assignments, trophies, and the feed in the original design prototype still use sample browser data. They will be connected in Steps 3 and 4.
- Removing a member revokes access to the store; it does not ban their Supabase Auth identity globally. Historical membership records remain. Global account deletion/ban workflows are not implemented here.
- Owner/regional-manager permissions and temporary administrator support access to store feeds remain future work. Administrator status alone cannot bypass team-file privacy.
- Training emails are not wired yet; the optional-email preference is stored for Step 5.
- File-access tests cover database storage policies. Real uploads, email delivery, callback behavior, and hosted sessions must still be tested against Supabase.

## Development checks

```sh
npm run test:database   # Docker required; isolated PostgreSQL, no exposed ports
python tests/account-ui.py  # Playwright and Chromium required; mocked API only
npm run build:accounts
python scripts/build-supabase-setup.py
```

Migrations are the source of truth. `scripts/build-supabase-setup.py` combines them into the SQL Editor download. Test containers are disposable and do not connect to the hosted project.
