# Stripe sandbox setup

Status: Package prices and sandbox Price IDs confirmed by the owner on October 24, 2026. The owner reports saving the sandbox secret in Supabase. A read-only, administrator-only connection checker is prepared; the actual hosted connection is not verified until the owner runs it successfully. Checkout, webhook provisioning, and billing lifecycle controls are not implemented by this step.

## Approved recurring packages

| Training seats | Monthly USD price | Sandbox Price ID |
| --- | --- | --- |
| 1–15 | $99.00 | `price_1UTrhULKSqENX3EoVuI54JbR` |
| 16–25 | $159.00 | `price_1UTrnrLKSqENX3EoqGe9eX6R` |
| 26–35 | $219.99 | `price_1UTroBLKSqENX3Eo7JUSvRve` |

These replace the previously proposed $179 and $239 prices. The machine-readable configuration is [billing/stripe-sandbox-prices.json](billing/stripe-sandbox-prices.json). Amounts are integer cents; the package is one flat-rate subscription item per store, not a price multiplied by employee count.

Self-service signup will require a card and include a 14-day trial. Stores requiring 36+ seats or an additional location contact colTRAIN. Coltrain Hardware and Keith Hardware retain their no-charge pilot arrangements; no Stripe subscription is created for either by this setup.

## Next owner step: store the sandbox credential securely

1. Open the same Stripe sandbox that contains these products.
2. Search the Stripe dashboard for **API keys** and open that page.
3. Reveal and copy the sandbox **Secret key**. It should begin with `sk_test_`. Do not copy the publishable key (`pk_test_`) or a live key (`sk_live_`).
4. Open Supabase → **coltrain-development → Edge Functions → Secrets**.
5. Add a new secret with the name **`STRIPE_SANDBOX_SECRET_KEY`** and paste the key as its value.
6. Click **Save**. Do not paste the value into chat, SQL, GitHub, website configuration, or a Netlify browser build.

Saving this secret does not deploy a function, create a subscription, send an email, or charge a customer. No Netlify update is required for this step.

## Deploy the read-only connection checker

The checker reads the three configured prices from Stripe and verifies their environment, active status, currency, monthly interval, flat-rate structure, expected amount, and active sandbox product. It cannot create a checkout, subscription, payment, or store. Only a signed-in colTRAIN platform administrator can run it; store owners and billing administrators cannot.

1. In Supabase, open **Edge Functions → Functions → Deploy a new function → Via Editor** (the wording may be **Create function**).
2. Open [stripe-sandbox-function.ts](stripe-sandbox-function.ts) on GitHub, choose **Raw**, and copy the entire file.
3. Replace all the starter code in the editor's **index.ts** file with that code. Do not add it underneath the starter code or create a second source file.
4. Set the function name to **`stripe-sandbox`** before clicking **Deploy function**. The endpoint must end in `/functions/v1/stripe-sandbox`.
5. Open the deployed function's **Settings**. Turn **Verify JWT with legacy secret** off and click **Save changes**. The function itself validates the signed-in user through Supabase Auth and checks the platform-admin table before reading the Stripe credential or making provider calls.
6. Keep the existing `COLTRAIN_APP_URL` setting, which must be the exact HTTPS origin used to open the hosted application. No additional secrets or SQL migrations are needed for this checker.

For CLI deployment, the equivalent source is [functions/stripe-sandbox/index.ts](functions/stripe-sandbox/index.ts). The single-file dashboard version is generated with `node scripts/build-stripe-sandbox-function.mjs`.

## Publish and run the administrator check

1. Download the latest [design/coltrain-website.zip](../design/coltrain-website.zip) from GitHub using **Download raw file**, unzip it, and upload the extracted website folder to the existing Netlify site's **Deploys** page.
2. Wait for **Published**, refresh colTRAIN, and sign in with the platform-administrator account.
3. Open **Hamburger menu → Account & team settings → Company settings → Open company settings**.
4. Find **Stripe sandbox connection** and click **Check Stripe sandbox connection**.
5. Expected result: **All three sandbox packages are verified**, with $99.00, $159.00, and $219.99 monthly packages. No charges or subscriptions are created by the check. Pilot stores remain unchanged.

If the button is missing, confirm the newest website package is published and the account is the colTRAIN administrator. Company ownership alone does not expose this setup tool.

If a package needs attention, the row explains whether its price is missing, archived, incorrectly configured, or temporarily unavailable. A **Price was not found in this sandbox** result usually means the key and products came from different sandboxes. Do not send the secret key in chat; report only the displayed error. A rejected key or function configuration error is shown as a general message without forwarding Stripe's raw response.

The checker result is a current read, held only in the signed-in page's memory. It is cleared on sign-out and does not change the source manifest's verification status automatically. Checkout must revalidate pricing independently when implemented.

## Validation for this release

- `npm run test:stripe-sandbox`: Auth/admin restrictions, CORS, sandbox-only keys, GET-only provider access, plan injection resistance, all pricing checks, sanitized failures, and generated-file consistency. Stripe calls are mocked; no actual provider credential is needed.
- `npm run test:companies:ui`: Administrator-only controls, success and configuration errors, unchanged ordinary-owner/billing/training views, and the existing company-settings flows.
- Both the CLI entry and generated dashboard function are checked with Deno. The website build includes public application files only; neither the server function nor credentials belongs in the Netlify package.

## Integration requirements for the next build

- Keep the sandbox key server-side and reject live credentials in the sandbox integration.
- Verify every configured price against Stripe: active, `livemode=false`, USD, recurring monthly with interval count one, expected integer amount, and flat per-unit package pricing. Do not assume a `price_` ID proves any of those properties.
- Select prices from the server's approved plan mapping. Do not trust a browser-supplied amount, seat limit, Price ID, or pilot flag.
- Create Checkout Sessions only for an authenticated, authorized purchaser with explicit purchase confirmation and accepted terms. Require a card for the trial.
- Separate pending signup from provisioned access. Create the company/store and entitlements from authenticated, verified Stripe events, with idempotent handling and protection against duplicate/reordered delivery.
- Preserve existing pilot stores, company/store isolation, single-store training membership rules, and billing-only accounts that consume no training seat.
- Define the webhook endpoint, then configure a separate sandbox signing secret when that endpoint exists. A Stripe API key is not a webhook signing secret. The owner should not create a guessed webhook destination yet.
- Test the full trial/signup/cancel/payment-failure workflow with Stripe sandbox data before configuring live prices or enabling real charges.
- Implement the approved seven-day and one-day trial reminders, 14-day payment grace period, optional cancellation survey, and paid-through access rules as part of the lifecycle work.

The marketing website's public signup URL, final terms, business-address collection, tax setup, proration/downgrade behavior, additional-location discounts, and HubSpot synchronization still require the corresponding implementation decisions in the [requirements](../docs/STORE_SIGNUP_AND_SUPPORT_REQUIREMENTS.md).
