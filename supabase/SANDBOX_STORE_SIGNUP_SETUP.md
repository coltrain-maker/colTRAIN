# Sandbox store signup and automatic provisioning

This is the next testing milestone after the verified Stripe package connection. It creates **separate sandbox test stores**, with a card-required 14-day Stripe trial and automatic account setup after a signed Stripe confirmation. Coltrain Hardware and Keith Hardware keep their existing no-charge pilot arrangements.

This release is **not a live commercial signup launch**. It rejects live keys/events, labels the public signup page as sandbox testing, and leaves signup disabled until explicitly enabled. Subscription cancellation, grace-period enforcement, reminder emails, admin lifecycle alerts, exports/retention jobs, customer billing portal, HubSpot synchronization, and final commercial terms remain follow-up work. A canceled or expired sandbox subscription does not yet disable its store's training access. Use Stripe's sandbox dashboard to cancel test subscriptions.

## 1. Database update

1. Supabase → **coltrain-development → SQL Editor → New query**.
2. Copy all of [202610260025_sandbox_store_signup.sql](migrations/202610260025_sandbox_store_signup.sql), paste, and click **Run**.
3. Expected: **Success. No rows returned**. Apply once after 024. Do not run the combined new-project `SETUP.sql`.

The update creates private signup/subscription records and constrained RPCs, enables RLS, and makes no Stripe calls. Existing store memberships, seats, training records, and pilot terms are not changed. It also allows a company owner to invite a separate store manager without becoming a staff member or gaining feed/message access.

## 2. Deploy the two functions

For each function below:

1. Supabase → **Edge Functions → Functions → Deploy a new function → Via Editor**.
2. Open the linked file on GitHub, choose **Raw**, and copy everything.
3. Replace all starter code in **index.ts**.
4. Enter the exact function name **before** clicking **Deploy function**.
5. In the deployed function's **Settings**, turn **Verify JWT with legacy secret** off and save. The checkout function verifies the signed-in user with Auth. The webhook independently verifies Stripe's raw-body HMAC signature.

| Function name | Complete dashboard code |
| --- | --- |
| `stripe-checkout` | [stripe-checkout-function.ts](stripe-checkout-function.ts) |
| `stripe-signup-webhook` | [stripe-signup-webhook-function.ts](stripe-signup-webhook-function.ts) |

Keep the existing `STRIPE_SANDBOX_SECRET_KEY` and `COLTRAIN_APP_URL` secrets. Supabase automatically supplies its own URL, anon key, and service-role key; never put service-role or Stripe secret keys into the website or chat.

## 3. Connect Stripe's sandbox webhook

1. Open the **same Stripe sandbox** as the verified products.
2. Open **Workbench → Webhooks** (or search for **Webhooks**).
3. Choose **Create event destination / Add endpoint** for **your account**, using ordinary API v1 **snapshot events** rather than thin events or connected-account events.
4. Select only:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
5. Use this destination URL:

   `https://flhdeftduysnjvqnhhee.supabase.co/functions/v1/stripe-signup-webhook`

6. Create the destination. Reveal its **Signing secret**, beginning with `whsec_`.
7. In Supabase → **Edge Functions → Secrets**, save it as **`STRIPE_SANDBOX_WEBHOOK_SECRET`**. Do not share its value in chat.

The signing secret is different from the Stripe API secret key. Webhook delivery requires no Supabase Authorization header or public API key. Leave legacy JWT verification off for this endpoint so Stripe can reach the signature verifier.

## 4. Enable sandbox signup

After both functions are deployed and the signing secret is saved, run [ENABLE_SANDBOX_STORE_SIGNUP.sql](ENABLE_SANDBOX_STORE_SIGNUP.sql) in a new Supabase query. It checks the expected administrator account and enables the testing route. The result should show `enabled: true`, `environment: sandbox`.

This is a sandbox-only availability switch, not a live-billing switch. To close signup later, change `true` to `false` in that query and run it again. Closing signup does not delete test stores or stop a previously confirmed webhook from finishing its store setup.

## 5. Publish the website

Download [design/coltrain-website.zip](../design/coltrain-website.zip), unzip it, and upload the extracted folder to the existing Netlify site's **Deploys** page. Wait for **Published**.

The normal login page now includes **Register a store (sandbox)**. You can also add `/accounts/?store_signup=start` to the normal hosted site's origin. Use the same HTTPS origin already configured in `COLTRAIN_APP_URL`; the HubSpot marketing website does not need changing for this test.

## 6. Test a separate store

1. Use a private/incognito browser window and a **fresh email you control**. Do not reuse an existing employee, manager, company owner, billing administrator, or either pilot store name.
2. Choose **Register a store (sandbox)** → **Create owner account**.
3. Confirm the account email in that same private window, then sign in. If the email opens another browser window, open its confirmation link in the private window instead. The confirmation redirect must allow the hosted `/accounts/` route including its `store_signup=start` query. Existing employee invitations remain a separate flow.
4. Enter a distinct test company/store, contact name, phone, US business address, optional buying group, time zone, and package.
5. Leave **I will also manage staff and training** checked for the first test. Confirm purchase authority and accept the clearly labeled sandbox terms.
6. Choose **Continue to Stripe test checkout**. Check that the package is correct:
   - 1–15 seats: $99/month.
   - 16–25 seats: $159/month.
   - 26–35 seats: $219/month.
7. Use Stripe's test card **4242 4242 4242 4242**, a future expiry date, and any three-digit CVC. Complete the sandbox checkout.
8. The returned page waits for Stripe confirmation, polling briefly. **Refresh store status** also checks without creating a new checkout. A browser return alone cannot unlock a store.
9. After **Your store is ready**, open the account. Verify the correct store and manager identity, exact package seat count, six starter departments, ready standard courses, and available Daily Drills. Automatically assigned courses have **no default deadline**.
10. In Stripe, confirm a **sandbox** subscription in `trialing` status, with a card collected and a 14-day trial. Check the webhook delivery received a 2xx response. Confirm the two pilot stores remain unchanged.

For an owner who delegates training, repeat with another fresh test email and clear the manager checkbox. This account consumes **no training seat**. Open **Company settings → Open company settings → Invite a store manager** to email the separate manager; this uses the existing `invite-employee` function, whose database authorization is extended narrowly for company owners. The invitation reserves a seat. The owner does not thereby gain a staff membership, feed access, or private employee messages.

## Behavior and recovery

- Store details and accepted sandbox terms are saved only for the confirmed account. Client-supplied owner IDs, capacities, Price IDs, pilot flags, redirect URLs, and trial lengths are ignored or rejected.
- The server maps the saved package to the approved Stripe Price ID, checks current sandbox pricing, and creates exactly one subscription item with quantity one. It requires a card and a 14-day trial.
- The checkout request uses a stable per-signup idempotency key. A lost response can be retried without creating a second session. A short SQL lease prevents concurrent checkout creation. Unknown attempts older than 23 hours and known expired checkouts require support review rather than silently creating another subscription.
- Saved signup details cannot yet be edited through the customer UI. Resume the existing signup or contact support for changes; do not repeatedly register different accounts to bypass a pending checkout.
- The webhook checks signature freshness, rejects live events, retrieves the canonical Checkout Session/subscription from Stripe, validates metadata, quantity, customer, and plan, and calls a service-only transactional provisioner. Duplicate and concurrent deliveries create one store and one seat pool.
- If a user joins another store while checkout is pending, provisioning stops for support review rather than moving that person or overwriting a membership. The existing paid/sandbox Stripe subscription must be reviewed separately in Stripe if setup cannot complete.
- Only ready, published **standard** full courses are released. Draft, incomplete, and store-owned onboarding/faith content is not copied. Daily modules must be published, have sequence slots, and have complete checks/keys. Original course and module content is reused, not copied into separate versions.
- New standard publications and new members auto-enroll within these sandbox stores. Previous completions are preserved; a newer version does not erase completed-course credit. This release does not retroactively change the catalog release policy of existing pilot stores.
- The ready page lists the onboarding tasks; saved onboarding priorities, detailed checklist tracking, commercial terms, and billing lifecycle controls are later steps. Do not advertise the sandbox route as production signup.

## Validation

- `npm run test:store-signup`: Signed/unsigned and stale webhook tests, canonical Stripe checks, sandbox-only keys, server-owned checkout parameters, recovery/idempotency, and actual SQL permission/provisioning tests.
- `npm run test:store-signup:ui`: Owner registration redirects, purchase confirmation, package selection, safe checkout navigation, pending/ready states, training and billing-only accounts, manager invitations, and mobile layout.
- Existing database, company, invitations, shared-device, and PWA checks cover integration regressions. All automated provider calls are mocked; real sandbox checkout/webhook delivery still needs the hosted test above.

Regenerate standalone functions with `node scripts/build-stripe-signup-functions.mjs`. CLI sources are in `functions/stripe-checkout`, `functions/stripe-signup-webhook`, and `functions/_shared/stripe-signup.ts`.
