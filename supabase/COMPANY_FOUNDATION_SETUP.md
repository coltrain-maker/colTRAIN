# Company accounts and permissions — first database update

This is the database foundation for the approved [store signup requirements](../docs/STORE_SIGNUP_AND_SUPPORT_REQUIREMENTS.md). Signup screens, Stripe checkout, billing enforcement, support grants, automatic catalog release to new stores, and company settings screens are later steps. No real billing is enabled by this update.

The follow-up [company settings release (024)](COMPANY_SETTINGS_SETUP.md) connects company details, delegated permissions, and a read-only progress view to the account interface. Apply 023 first; these instructions describe the original foundation step.

## Apply to the existing project

1. Open Supabase and choose **coltrain-development**.
2. Open **SQL Editor**, then create a **new query**. Do not replace an old query or run the full `SETUP.sql` against this project.
3. Open [202610230023_company_foundation.sql](migrations/202610230023_company_foundation.sql), copy its entire contents, paste into the query, and click **Run**. Run this migration once, after update 022. Expected result: **Success. No rows returned**.
4. Create another new query. Copy all of [PILOT_COMPANY_SETUP.sql](PILOT_COMPANY_SETUP.sql) and run it. This marks Coltrain Hardware and Keith Hardware as no-charge pilots. It creates Keith Hardware with **15 test seats** only if it does not already exist. Existing seats, invitations, accounts, assignments, and points are unchanged. If there are duplicate names, the whole query stops without making changes.
5. The pilot query should return both stores with `access_mode` equal to `pilot`. Ownership is deliberately unassigned until an administrator explicitly confirms the owner. A blank `owner_user_id` is expected at this stage.
6. Sign in with your existing manager account and confirm that your team, training records, and messages still appear. Keith Hardware may have no active members yet; this update does not send an invitation or move your account into it.

If a query fails, save the exact error and stop before the next step. Migration 023 runs in one transaction. The pilot setup query is safe to repeat, but repeating it after deliberately ending a pilot would re-enable that pilot.

**No Netlify upload, Edge Function deployment, card details, or Stripe keys are needed for this step.**

## Permission boundaries

- Existing `organization_memberships` still represents one active training store per person and consumes the existing seat as before.
- Each existing store gets its own company container. Owners are not inferred from manager status, emails, metadata, or matching business names.
- Company ownership, billing authority, and training oversight are stored separately from manager/employee membership. Billing-only and oversight-only accounts consume no training seat.
- An owner can grant billing or training oversight company-wide, or scoped to a linked store. Revoking a store grant does not revoke a separate company-wide grant; the settings response lists both scopes.
- A platform administrator assists with linking an additional location. Only an unowned, standalone store with no company permissions can be linked; owned companies are never silently merged.
- Owner and training-oversight access uses a dedicated read-only training overview. It does not change `can_manage` or `is_member`, permit staff changes, expose individual quiz answers, or grant private-message/feed/photo access.
- Existing store managers still manage their store. Company ownership or billing authority alone does not silently appoint a person as that store's training manager.
- All new tables have RLS enabled and are inaccessible directly to browser roles. Narrow authenticated RPCs enforce permissions and log ownership, permission, linking, and pilot changes. No anonymous setup or metadata-based elevation exists.

## Database interfaces prepared for later screens

| RPC | Purpose and authorization |
| --- | --- |
| `get_my_company_accounts()` | Lists only company stores the caller can bill or oversee; admins can inspect all linked stores |
| `get_company_training_overview(company, store?)` | Read-only active-staff progress and separate course/Daily/lifetime points; company owner, scoped training overseer, or platform admin |
| `get_company_access_settings(company)` | Company contact details, grants, and last 100 audit events; owner or platform admin |
| `admin_initialize_company(store, owner_user, company_name, company_phone?, affiliation?)` | Explicitly confirms a legacy company's verified owner and details; platform admin only |
| `set_company_permission(company, person, capability, enabled, store?)` | Grants/removes `billing` or `training` for a confirmed account; owner or platform admin; null store means all linked stores |
| `transfer_company_ownership(company, new_owner)` | Transfers to a confirmed account; owner or platform admin; removes previous owner's delegated company permissions but preserves any separate store membership |
| `admin_link_company_store(company, store)` | Links an unowned, standalone store during assisted additional-location setup; platform admin only |
| `admin_set_store_pilot(store, enabled, reason)` | Sets/ends pilot status with an audit entry; platform admin only |

These APIs are not yet connected to customer settings screens. Role invitations, user-facing ownership-transfer confirmation, and checkout provisioning will be built separately. A first-time purchaser cannot yet create a company through these APIs.

## Access modes and billing safety

- `legacy_no_charge`: Preserves the existing manually created store arrangement. It is the compatibility default for stores created by the existing admin-only `create_store` function.
- `pilot`: Admin-controlled no-charge pilot; no automatic expiration.
- `awaiting_paid_approval`: A pilot was manually ended. This cannot create a charge or subscription. Explicit customer approval through future Stripe checkout will be required.

These are protected foundation records, not a Stripe subscription state machine. The application does not yet restrict training when a pilot ends. Trial, active payment, grace period, cancellation, and access enforcement will be added with Stripe; existing pilot access remains intact in the meantime. No public signup route can select pilot status.

## Validation

Run `npm run test:companies` for isolated migration, legacy-preservation, role isolation, store scoping, ownership, linking, audit, pilot, and concurrent-permission checks. These tests use disposable PostgreSQL with no network or external email/payment calls.
