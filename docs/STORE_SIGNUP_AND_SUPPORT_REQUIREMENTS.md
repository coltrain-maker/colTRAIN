# colTRAIN — Store Signup, Billing, and Support Requirements

Version: 1.3

Updated: October 24, 2026

Status: Approved product decisions from the store-signup interview. This document describes required behavior; it does not mean the features have been implemented or deployed.

## Purpose

Allow new customer stores to register, pay, and begin using colTRAIN with minimal administrator involvement. The colTRAIN administrator provides support and handles exceptions rather than routinely creating customer accounts.

These requirements extend the existing training platform. Where earlier pilot arrangements differ, this document governs the new customer signup workflow. Existing accounts, staff memberships, training records, and no-charge pilot access must be preserved during implementation.

## 1. Service responsibilities

| Service | Responsibility |
| --- | --- |
| HubSpot | Public marketing website, landing pages, and prospective customer information |
| Netlify | Hosting the colTRAIN application |
| Supabase | Authentication, company/store accounts, permissions, and training data |
| Stripe | Checkout, subscriptions, payment methods, invoices, and billing portal |

Store access must follow verified Stripe events rather than relying on a browser returning from checkout. Routine signup and subscription updates must happen automatically.

The proposed address layout is `www.coltrainlearning.com` for marketing and `app.coltrainlearning.com` for the application. This is a proposed deployment detail, not a confirmed domain migration. Exact HubSpot synchronization fields and workflows remain to be defined.

## 2. Company and store structure

- A company account can contain multiple store locations.
- Each store has a separate subscription and separate staff access.
- A company owner can oversee billing and training progress across all linked stores.
- The owner can grant billing authority for selected stores and appoint a company-level training administrator without granting billing authority.
- Ordinary managers and employees remain limited to their assigned store.
- Initially, adding a second location requires contacting colTRAIN for setup. Multiple-location onboarding is an assisted exception to self-service signup.
- Multiple-location discounts begin with the second location. The discount amount and application rules are not yet decided.

## 3. Roles and responsibilities

Billing authority and training responsibilities are separate permissions. One person may hold multiple responsibilities.

| Responsibility | Required access |
| --- | --- |
| Company/store owner | Account ownership; company-wide billing and training oversight; authorize billing administrators; transfer ownership |
| Billing administrator / authorized purchaser | Update payment information, approve package upgrades, change plans, and cancel for authorized stores |
| Company-level training administrator | Oversee training across authorized locations without automatic billing authority; contact colTRAIN support and grant temporary dashboard access for those stores |
| Store manager | Manage staff, training, deadlines, competitions, and store communication; contact colTRAIN support and grant temporary dashboard access for their store |
| Employee | Complete training and use permitted store communication features |
| colTRAIN administrator | Platform support, account exceptions, pilot designation, and existing administrative training oversight |

The person registering becomes the initial owner and chooses whether they also need manager access. A billing-authorized person may be different from the person overseeing staff.

Only owners and managers authorized to purchase may register a store. A signup confirmation stating that the registrant owns the business or is authorized to purchase for it is sufficient; routine manual approval is not required.

## 4. Packages and seats

| Training seats | Monthly price | Signup route |
| --- | --- | --- |
| 1–15 | $99 USD | Self-service |
| 16–25 | $159 USD | Self-service |
| 26–35 | $219 USD | Self-service |
| 36+ | Contact colTRAIN for pricing | Assisted setup |

The latest approved packages are $99 for 1–15 seats, $159 for 16–25 seats, and $219 for 26–35 seats. These supersede earlier amounts, including the previous $219.99 amount. The owner confirmed sandbox use on October 24, 2026, and reported hosted Stripe checker amounts matching the current 25- and 35-seat prices. See [Stripe sandbox configuration](../supabase/billing/stripe-sandbox-prices.json) and the [setup guide](../supabase/STRIPE_SANDBOX_SETUP.md). Sandbox prices must not be used for live billing; live configuration will be separate.

- Display the packages and prices upfront. Customers choose the package that fits their needs.
- Active managers and employees consume training seats. Billing-only access does not consume a training seat.
- Pending invitations reserve seats. Expired or revoked invitations release those reservations.
- Removing an employee releases the seat for a replacement while retaining the former employee's inactive record under applicable retention rules.
- A store cannot exceed its package limit without an approved upgrade.
- Only an owner or another billing-authorized person can approve an upgrade. An internal manager-to-billing upgrade-request feature is not required.
- Downgrade timing, proration, and handling of existing seat counts during a downgrade remain to be defined.

## 5. Trial and automated signup

- Offer a 14-day trial with a credit card required at signup.
- Clearly disclose the chosen package, recurring amount, trial end, and first charge before checkout completion.
- Automatically begin charging after the trial unless canceled.
- Send trial-ending reminders seven days and one day before the charge, showing the charge date and amount.
- Canceling during the trial prevents the charge; trial access continues until day 14.
- Allow one trial per store. Returning canceled stores reactivate without another trial.
- Additional locations may receive their own trial, with initial setup handled by colTRAIN.
- Successful signup automatically creates the company/store structure, enrolls the initial owner with their chosen manager access, creates starter departments, and makes standard training available.
- Routine account creation requires no colTRAIN administrator approval.

Collect during signup:

- Company name and store name.
- Business address and store time zone.
- Contact name and email.
- Company phone number.
- Optional buying-group affiliation.
- Purchase-authority confirmation and acceptance of signup terms.

After signup, present this short onboarding checklist:

1. Confirm store details.
2. Review starter departments.
3. Invite the manager or team.
4. Select priority onboarding courses and assign deadlines where needed.

## 6. Standard content and onboarding assignments

- Every customer store immediately receives the same published standard course catalog and Daily Drills.
- All employees automatically receive all published standard courses provided to their store, including previously published courses and future additions, regardless of role or department.
- Preserve the existing automatic Daily Drill enrollment and sequential progression through Foundations, Application, and Expertise.
- Onboarding selections identify courses a new hire should complete first; they do not remove the remaining standard courses.
- Additional onboarding courses will cover becoming familiar with hardware retail and department-specific knowledge. Their content will be developed separately.
- Managers can set course deadlines for new hires, competitions, and individual courses outside competitions.
- Do not impose a default 30-day course deadline.
- Future additional courses or catalogs may be optional offerings. Their pricing and entitlement rules are not yet defined.

## 7. Subscription lifecycle

### Failed payments

- Retry payments automatically and notify billing contacts.
- Provide a 14-day grace period.
- After the grace period, restrict training access until payment succeeds.
- Notify the colTRAIN administrator when failed billing needs attention.
- Exact restricted-access screens, retry schedule, and escalation timing still need implementation definitions.

### Cancellation and reactivation

- Billing-authorized users can cancel.
- For a paid subscription, access continues through the paid billing period.
- After access ends, billing-authorized users retain billing and reactivation access.
- Include an optional cancellation survey: price, low usage, missing features, technical problems, business changes, other, and a comment box.
- Skipping the survey must never block cancellation.
- Retain canceled-store training records for 12 months after paid access ends to support reactivation.
- Offer an export before deletion.
- Explain the retention/deletion policy in signup terms. Scheduled deletion reminders are not required.
- Define export format, deletion scope, and treatment of any separately required billing records before implementing permanent deletion.

## 8. No-charge pilot stores

| Store | Arrangement |
| --- | --- |
| Coltrain Hardware | Preserve its existing no-charge pilot arrangement |
| Keith Hardware | Additional no-charge pilot; remains free until the administrator manually ends it |

- Pilot status is controlled by the colTRAIN administrator and is unavailable through public signup.
- Ending a pilot must not automatically charge the store.
- The customer must explicitly approve a paid subscription before charges begin.
- New customer stores use the regular Stripe trial and billing workflow unless the administrator grants pilot status.

## 9. Dedicated colTRAIN support

- Create a dedicated support page inside the platform, separate from private store employee messaging.
- Make it available to store owners, managers, billing-authorized users, and company-level training administrators.
- Support conversations are private and support replies and email notifications.
- Remove the current colTRAIN support entry from Team Corner and route support through the dedicated page.
- Preserve employee-to-employee and employee-to-manager private messaging as a separate feature.

### Temporary dashboard access

- Owners, store managers, and company-level training administrators can grant access for stores they oversee.
- A grant provides the colTRAIN administrator read-only dashboard access for 24 hours.
- Include dashboard information, assignments, training progress, departments, and competitions within the permitted support view.
- Clearly show that support access is active; allow immediate revocation and automatic expiration.
- Record access and activity in an audit log visible to the customer.
- Private employee messages and payment details remain restricted.
- Team Corner access requires separate explicit permission; dashboard access does not automatically include it.
- Making changes on behalf of a customer is outside the initial support-access scope and requires separate permission if added later.
- Preserve existing platform-admin training progress access; temporary support access extends the customer dashboard view without granting blanket private-data access.

## 10. Administrator notifications

Notify the colTRAIN administrator when:

- A store signs up.
- A store converts to a paid account.
- Failed billing requires attention.

Routine setup, trial conversion, and normal subscription updates should proceed without administrator intervention. Notification channels and detailed escalation rules remain to be specified.

## 11. Acceptance criteria

1. An authorized single-store customer can choose a package, provide a card, and start a trial without manual account creation.
2. Repeated checkout callbacks or billing events do not create duplicate stores, subscriptions, or access grants.
3. Billing-only users do not consume training seats or gain training-management permissions merely through billing authority.
4. Active staff plus reserved pending invitations cannot exceed the approved package capacity.
5. A new store receives starter departments, standard courses, and Daily Drills; existing employees receive newly published standard courses automatically.
6. Trial reminders identify the correct charge amount/date; canceling before trial end prevents a charge and preserves remaining trial access.
7. Owners see their linked locations; ordinary staff cannot access another store's staff, training records, or communication.
8. Failed payments follow the grace-period policy, and successful payment restores the correct access.
9. Coltrain Hardware and Keith Hardware remain free; ending pilot status cannot trigger an unapproved charge.
10. Support access is read-only, store-scoped, logged, revocable, and expires after 24 hours. It does not expose private messages or payment details.
11. Cancellation works without survey participation; paid access ends at the correct date and records follow the 12-month retention policy.

## 12. Open decisions and proposed delivery order

Resolve before the relevant implementation:

- Multiple-location discount amount and eligibility/application details.
- Stripe product configuration, taxes, proration, downgrade rules, and payment retry schedule.
- Exact HubSpot integration and final domain configuration.
- Ownership transfer and billing/training-administrator invitation details.
- Duplicate-store detection and handling of abandoned checkout or setup.
- Starter department defaults, onboarding course content, and priority-training presentation.
- Support email preferences, administrator notification channels, and escalation handling.
- Export format, deletion implementation, and final customer terms.

Proposed delivery sequence:

1. Company/store structure, permissions, and protected pilot status.
2. Self-service signup, Stripe subscriptions, trials, and billing synchronization.
3. Store onboarding, staff invitations, and priority training.
4. Dedicated colTRAIN support and temporary read-only dashboard access.
5. Upgrades, failed payments, cancellation, reactivation, and retention.

The sequence is planning guidance. Saving these requirements does not authorize production billing changes, charges, emails, or deployment.


### Owner setup after signup (October 27, 2026)

After verified Stripe confirmation automatically creates the store, guide its purchaser through assigning responsibilities. The creator remains company owner and may also be its manager. If someone else will manage staff, the owner can invite that person by name and email. Offer an optional additional administrator with training access, billing access, or both; keep company permissions separate from store manager permissions and colTRAIN platform administration. Company administrators do not consume training seats. Owners without a staff role should land on their company/store setup, without an employee invitation-code screen. Pending signups resume existing checkout/status instead of creating another store.
