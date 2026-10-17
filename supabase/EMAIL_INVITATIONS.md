# Employee invitations by email

Implementation is prepared and locally tested. It is **not deployed or enabled in the hosted Supabase project yet**. The existing downloaded account file remains a separate older copy. No real invitation emails were sent during development tests.

## Employee experience

1. The manager enters the employee's name and email, then selects **Send invitation**.
2. The database checks the manager's store permissions and reserves an available seat. It generates the single-use code internally; managers do not create a password or type a token.
3. A server-only Supabase Edge Function requests the invitation email. Browser files contain only public configuration, never a service-role key.
4. The new employee follows the email link to the hosted `/accounts/` page, chooses a password of at least 12 characters, and joins the correct store. Their confirmed email must match the pending invitation. Their name is copied to their profile without opting them into optional email notifications.
5. An existing Auth account receives a password recovery email instead of a duplicate account. It uses the same callback to set a password and claim the invitation. If the person already has an active store membership, the seat claim is refused; moving between stores requires removing the previous active membership.

Managers can **Resend invitation** after one minute or **Revoke code** to cancel it. Resending creates a replacement invitation and invalidates the old store invitation. A Supabase Auth link may still allow password setup after cancellation, but cannot grant revoked store access. Seats are reserved for seven days; the Auth email link has its own, potentially shorter, Supabase expiration. A send failure retains the reservation and shows a failed/pending status rather than claiming delivery. "Email requested" means the provider accepted the request, not proof of inbox delivery.

Legacy manually shared codes continue to work. Resending one of those through **Replace code** remains manual; the new form creates named email invitations.

## Required activation steps

Complete these in order. Never rerun the full new-project `SETUP.sql` against the existing project.

### 1. Apply the incremental migration

In the existing project's SQL Editor, run only `supabase/migrations/202610170003_email_invitations.sql`. It adds names, delivery status, permission-checked email preparation, and email-bound seat claims. Existing stores, accounts, seat assignments, and manual invitations remain intact. This is a one-time migration, not an idempotent script.

### 2. Publish the public website over HTTPS

A downloaded file cannot receive working email callbacks. Use a static hosting service such as Netlify. No custom domain is required for a pilot.

Build:

```sh
npm --cache /tmp/coltrain-npm-cache ci --ignore-scripts --no-audit --no-fund
npm run build:accounts
python scripts/build-preview.py
python scripts/build-hosting.py
```

`hosting/` contains only `index.html` (sample training prototype) and `accounts/index.html` (real accounts). `design/coltrain-website.zip` contains the same two public files. Extract the ZIP before using a folder-based drag-and-drop host; upload the folder whose top level contains `index.html` and `accounts/`. Do not upload the repository, `.env` files, database tests, or server credentials. Once published, verify that `https://YOUR_HOST/accounts/` shows **Welcome to colTRAIN**. The training prototype remains sample-only.

The ZIP is also saved on the development branch for download through GitHub's **Download raw file** action, which avoids the chat preview's broken download control. A build alone does not publish anything.

The owner has supplied the pilot origin `https://stalwart-custard-7be489.netlify.app` and reports saving the Site URL and invitation redirect entries. The cloud environment could not independently check Netlify because its egress proxy denied that hostname; that denial does not establish a website failure. Deployment of the migration/function and live email checks are still pending.

### 3. Configure Auth callbacks and email delivery

In Supabase **Authentication → URL Configuration**:

- Site URL: `https://YOUR_HOST/accounts/`
- Redirect URLs: `https://YOUR_HOST/accounts/` and `https://YOUR_HOST/accounts/?invitation_id=*`

Replace `YOUR_HOST` everywhere with the actual hostname. The second entry permits only the invitation-ID query on this exact HTTPS host/path; do not use a wildcard hostname. Ensure invitation and recovery templates keep Supabase's `{{ .ConfirmationURL }}` link so Auth verifies the email and preserves `RedirectTo`. Do not hard-code localhost or link to SiteURL without the verification token. Keep email confirmation enabled and set the minimum password length to 12.

Configure custom SMTP with a verified sender before inviting employees outside your Supabase organization. The default sender is restricted and has development rate limits; it is not a verified staff-email delivery setup. Customize the invitation email to say **You’re invited to colTRAIN** and explain that the employee chooses their own password. Existing-account fallback uses the separate recovery template.

### 4. Deploy the server function

The server needs `COLTRAIN_APP_URL=https://YOUR_HOST` (origin only, without `/accounts/`). Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions; the service-role credential stays on the server. The cloud browser page must never receive it. The function deliberately rejects file/opaque origins, unconfigured hostnames, localhost, and browser origins other than the configured website.

Using an authenticated Supabase CLI on a trusted development machine:

```sh
supabase link --project-ref flhdeftduysnjvqnhhee
supabase secrets set COLTRAIN_APP_URL=https://YOUR_HOST
supabase functions deploy invite-employee
```

The CLI credentials must be supplied through the CLI's secure login/environment mechanism, never chat or browser code. `supabase/config.toml` turns off the legacy gateway JWT check for this function so new publishable keys work. The handler still requires and verifies the caller's actual Auth session with `getUser()`, and calls the seat/role RPC using that person's JWT before constructing the privileged email client. Do not deploy a handler that skips these checks. The function uses the same pinned Supabase JS version as the browser.

For dashboard deployment, first run `node scripts/build-invite-function.mjs`. This creates `supabase/invite-employee-dashboard.ts`, a self-contained entry containing the same tested handler. In Edge Functions, create/deploy a function named **invite-employee** through the editor and replace its default code with that entire generated file. Set `COLTRAIN_APP_URL` to `https://stalwart-custard-7be489.netlify.app` in Edge Function secrets and turn off **Verify JWT with legacy secret** for this function; the handler performs its own user validation. No service-role key is copied into the editor or browser. The alternative CLI deployment above uses the original two source files. A single-file paste of the source `index.ts` alone will not work.

### 5. Verify with controlled accounts before employee rollout

- Sign in as the manager **at the hosted account URL**, not the downloaded file.
- Use a fresh email you control; choose **Send invitation**. Confirm that a single seat is reserved and the email arrives with the correct hosted return URL.
- Open the email in a different browser/private window. Set a password, verify the store membership and saved name, sign out, and sign in again normally.
- Test an existing controlled email, resend after one minute, the old invitation link, revocation, and an expired invitation. An old/revoked store invitation must never grant store membership even if the Auth password setup remains valid.
- Verify a full store cannot invite another employee and another store's manager cannot send or view the invitation.
- Remove the test employee and verify that their seat is reusable and their training history is not transferred.
- Verify standard signup confirmation and password recovery too. Neither sending a test email nor a successful local mock proves live delivery or store isolation.

## Local verification

```sh
npm run test:database
node --test tests/invite-email-handler.test.mjs
python tests/account-ui.py
```

Database tests include email matching, verified-email requirements, roles, store boundaries, single-use claims, resends, and throttling. Server tests use fake clients and send no emails. Browser tests mock the email endpoint and Auth callbacks. No deployment credentials are needed for those tests.
