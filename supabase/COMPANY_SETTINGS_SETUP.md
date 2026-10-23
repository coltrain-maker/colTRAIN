# Company settings — database update and website release

Apply after [company foundation update 023](COMPANY_FOUNDATION_SETUP.md). This release adds a company-settings section inside **Account & team settings**. No Stripe connection, charge, or automatic customer signup is enabled yet.

## 1. Apply database update 024

1. Open Supabase → **coltrain-development → SQL Editor → New query**.
2. Copy the entire contents of [202610230024_company_settings.sql](migrations/202610230024_company_settings.sql).
3. Paste and click **Run**. Expected result: **Success. No rows returned**.

Run this update once. Do not rerun foundation 023, the pilot setup, or the combined new-project `SETUP.sql`.

## 2. Publish the website

1. Download [design/coltrain-website.zip](../design/coltrain-website.zip) from GitHub using **Download raw file**.
2. Unzip it on your computer.
3. In your existing Netlify site, open **Deploys** and upload the entire extracted website folder, as for previous releases.
4. Wait for **Published**, then refresh colTRAIN or close and reopen its home-screen shortcut.

## 3. Check Coltrain Hardware

1. Sign in with your current owner/manager account.
2. Open the hamburger menu → **Account & team settings**.
3. Find **Company settings**, then choose **Open company settings**.
4. Confirm Coltrain Hardware appears as a **No-charge pilot**, and that the owner is the account explicitly assigned in the previous SQL step.
5. Save the company phone and optional buying-group affiliation.
6. Select **View training progress** to inspect saved course and Daily Drill completion totals. Course points, Daily Drill points, and lifetime totals are separate columns.

As a platform administrator, you may also see Keith Hardware. It remains a separate pilot with an unassigned owner. No action or testing is required for Keith Hardware until its owner's contact information is available.

## Company permissions

An owner or platform administrator can authorize an **existing, confirmed colTRAIN account** using its email:

- **Billing administrator:** Billing authority for selected stores or all company stores. Stripe billing controls will be connected in a later release.
- **Training administrator:** A read-only progress overview for selected stores or all company stores; no automatic billing authority.

Selecting **All company stores, including future locations** includes future locations linked to that company. Additional-location linking still requires administrator-assisted setup.

Granting company permissions does not send an invitation email, create a training membership, consume a training seat, promote a store manager, or expose private messages or Team Corner posts. If the email does not match a confirmed account, the operation stops and asks for account setup first. Automated role invitations will be built separately.

Authorized people appear by name and email, with their permission and store scope. **Remove access** removes only that grant; any separate store role or other grant remains. A company-wide grant must be removed separately from a grant for one store.

Billing-only or training-only users with no store training membership can open **Company settings** from their standalone account page. Ordinary employees/managers without company authority see an explanation rather than company details or management controls.

## What remains for later releases

- Public package selection, checkout, trial creation, and Stripe billing controls.
- Automated company-role and owner invitations and customer-facing ownership transfer.
- Dedicated colTRAIN support and temporary dashboard grants.
- Signup onboarding, standard-catalog provisioning, and subscription lifecycle automation.

## Validation

- `npm run test:companies`: Real SQL tests for ownership, exact-email authorization, role scoping, contact updates, account isolation, audit, legacy records, and pilots.
- `npm run test:companies:ui`: Bundled browser checks for owner edits/errors, permission grants/removal, read-only progress, role-specific controls, menu persistence, escaped content, mobile layout, and delayed-response isolation on sign-out.
- Existing account, training, and shared-device checks cover the integration with the current application.

The browser tests use mocked Auth/API responses; database permission tests use isolated PostgreSQL. They do not send real email or contact Stripe.
