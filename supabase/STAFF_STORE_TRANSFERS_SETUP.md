# Staff moves between stores

A staff member may join another store after the former store removes their active membership. Reuse their existing email/account; do not delete their Auth user or create another personal account. Staff roles are limited to one active store at a time. Company ownership/billing/training permissions remain separate and are not removed by deactivating a staff membership.

## Install in the existing project

1. Supabase → SQL Editor → New query: run **migrations/202610270027_staff_store_transfers.sql** once after 026. Expected: Success. No rows returned. It preserves former memberships, original training records, points and trophies; it also credits existing active assignments when matching completed standard content is found on a former membership.
2. Supabase → Edge Functions → **invite-employee → Code**. Replace the entire `index.ts` with **invite-employee-dashboard.ts**, then deploy the update. Keep **Verify JWT with legacy secret OFF**; caller Auth and database permissions are verified in the code. Existing `RESEND_API_KEY`, `COLTRAIN_EMAIL_FROM`, `COLTRAIN_APP_URL` and built-in Supabase secrets are reused; no new key is needed. Never place secret values in the website or chat.
3. Publish the latest **design/coltrain-website.zip** to the existing Netlify site and refresh colTRAIN.
4. On the new store's manager/owner account, use **Resend invitation** / **Resend manager invitation** on the pending invitation. Wait at least one minute between sends. Owners who delegated training now see pending manager invitations under Company settings and can resend or cancel them.

## Expected returning-account experience

- The person receives an invitation naming the destination store and role, sent through Resend. The link contains an invitation identifier, not an Auth token. They are told to use their existing password; no password-reset email is sent for the store move.
- Opening the link asks them to sign in with the invited email, previews the destination store/role, and asks them to **Accept invitation and join store**.
- If signed in as the wrong person, they can sign out and switch accounts while retaining the invitation link. An unmatched account cannot preview the store or claim a seat.
- If they still belong to another active store, acceptance is blocked. It does not silently move them, remove the old membership, or change their old role.
- Once former access is removed and the invitation is accepted, the new store claims its reserved seat and grants the role recorded on the invitation. The old membership remains inactive, and its old seat stays free.
- New users still receive the existing Supabase invitation and set their first password. Ordinary password resets remain available separately.

## Personal training and store privacy

- Original records stay tied to the same Auth user. **Account & team settings → View my training history** shows the person's course/Drill completion metadata, quiz-attempt counts, points and trophy total, including former memberships. A signed-in person without a current store can also see their own history.
- Completed **identical standard course versions** and Daily module versions carry over when that content is assigned/provided by the destination store. Their current assignments show completion credit and lessons already completed; Daily sequence progress uses the carried completions.
- Carrying credit creates no new scored attempt, points, trophy, copied time, or automatic deadline. Existing records and awards are not moved or rewritten. Competition review quizzes remain separate.
- Store-owned onboarding is never copied to a different store. A personal transcript may retain its title/date as history only, but it does not grant access to the former store's private content, documents, feed, photos, messages or raw answers. The new manager sees only their own store's assignments plus the existing aggregate lifetime-point totals.
- Incomplete records remain in the personal history. This update does not copy partial work/quiz answers or manager assistance from the former store into a new store's assignment, nor automatically certify different course versions.
- Future canceled-store deletion/export work must preserve account-owned credit independently before deleting store records. No retention purge is introduced by this update.

## Validation

`npm run test:staff-transfers` covers email delivery with mocked Auth/Resend, actual SQL transfers, prior completion credit, backfill, former-store privacy, account-isolated history, returning to a former store, owner manager-invitation controls, seats and competing acceptance requests. `npm run test:staff-transfers:ui` covers the existing-password acceptance flow, wrong-account switch, active-store conflict, manager dashboard, transcript and mobile layout. Existing account/RLS/training/competition tests retain one-use invitation and single-active-store checks.

No real emails are sent by automated tests. Validate the hosted flow using an account you control after installation.
