# Stripe sandbox setup

Status: Package prices and sandbox Price IDs confirmed by the owner on October 24, 2026. They have not yet been checked against Stripe's API. Checkout, webhook provisioning, and billing lifecycle controls are not implemented by this configuration step.

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
