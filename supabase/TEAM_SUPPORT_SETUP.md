# Private Team support: employee ↔ selected manager

> This describes the original version. For the current expansion, see [Direct and group messaging](GROUP_MESSAGING_SETUP.md).

Prepared for owner deployment. Codex has not run hosted SQL, installed live jobs, sent real emails, or deployed Netlify for this update.

## Approved behavior

- **Team support** is a private message board for active employees and managers. An employee selects one active manager in their store; a manager can initiate a conversation with an active employee in that store. Only that pair can read/reply. Other managers, coworkers, newly promoted managers, and colTRAIN administrators have no special access. A colTRAIN administrator who is actually the selected manager can use their own conversations normally.
- Categories: **Emergency, Work related, App related, Customer, General, Other**. Subjects and plain-text messages/replies are supported. Photos/attachments are not included in this first version.
- Every new message/reply gives the other participant a persistent in-app notification. Opening the conversation marks only the displayed messages read. Managers can also explicitly mark the whole thread read. Read state synchronizes with the general Notifications page; reading older pages never marks a concurrent newer reply read. A visible app polls its notification badge every 20 seconds without resetting inactivity protection or clearing forms.
- **Every Emergency message requests an email to the selected manager, regardless of optional email preference.** This also applies to manager-authored Emergency messages/replies. Other managers never receive it. Ordinary messages are in-app only. The email identifies the sender and links to the authenticated conversation; it does not include the subject, customer details or message body. Emails already accepted/in flight cannot be recalled by deleting a conversation.
- The selected manager can Archive, Move to inbox, Delete and Restore. Employees can search/read their own archived conversations and reply; a new reply reopens an archived conversation. Archive searches include subjects, original messages and replies. Search/pagination never expose another participant's conversations.
- Delete moves the conversation to **Trash**, hides it from both participants and their Notifications, and blocks replies. Only the selected active manager can restore it for 30 days. After 30 days it is inaccessible; the hourly cleanup physically removes it and dependent messages/read receipts/email jobs. Existing completed read state survives archive/restore.
- When a participant leaves, the employee can still review their own history while active, but replies close. Other managers do not inherit the conversation. Start a new conversation with an active manager when help is needed.
- Existing temporary colTRAIN read-only access to Team Corner remains a separate admin tool, now labeled **Store feed support**. It grants no access to these private conversations. Team Corner posts, training, points, trophies, paid seats and store membership permissions are unchanged.

## 1. Apply the database update

In the existing coltrain-development project, SQL Editor → New query. Copy the entire Raw contents of `supabase/migrations/202610220019_private_team_support.sql`, paste and Run once. Expect **Success. No rows returned**. This creates empty private/RLS tables and guarded functions. It does not create conversations or send email. Do not rerun SETUP.sql or earlier successful migrations.

## 2. Add a private scheduler credential securely

Reuse the existing `RESEND_API_KEY`, `COLTRAIN_EMAIL_FROM` and `COLTRAIN_APP_URL` Edge Function secrets. The app URL must be the actual HTTPS website root and match the browser origin, as with admin updates.

For unattended retries, generate a **new, separate, single-line random value of at least 32 characters** in your password manager. It is a worker password, not a Resend API key. Enter that same value in these two secure Supabase locations:

1. Edge Functions → Secrets: **Name** `SUPPORT_WORKER_SECRET`; **Value** the new random value.
2. Project's **Vault** secrets page: **Name** `coltrain_support_worker_key`; **Secret value** the identical random value.

Keep this value private. Do not put it into chat, SQL text, GitHub, Netlify or website/browser configuration. The prepared schedule looks up the value securely by name. The function verifies it before privileged scheduled work; browser requests instead verify the user's Auth identity and can retry only that user's conversations.

## 3. Deploy the email function

Supabase → Edge Functions → Deploy new function → Via Editor. Replace all sample code in the existing `index.ts` with the full Raw contents of **`supabase/team-support-email-function.ts`**. Do not add a second file. Set the function name to **team-support-email before deploying**, deploy, and verify its real URL ends `/functions/v1/team-support-email`.

In its Settings, turn **Verify JWT with legacy secret OFF** and Save. This function explicitly checks either Auth identity or the private scheduler credential. Leave invite-employee, employee-login and admin-update unchanged. No service-role key belongs in the website.

## 4. Enable scheduled delivery and retention cleanup

In the Supabase project's extension/integration settings, enable **Cron (pg_cron)** and **pg_net**, and ensure Vault is available. Then copy the entire Raw contents of **`supabase/PRIVATE_SUPPORT_SCHEDULE.sql`** into a new SQL Editor query and Run.

This query checks required extensions and the named Vault secret, then creates/updates two named jobs:

- `coltrain-emergency-support-email`: every minute, invoke the authenticated private worker to retry queued Emergency emails, up to 20 queue records per request.
- `coltrain-expired-support-trash`: hourly at minute 15, erase expired Trash and dependent data. Access is already blocked at the 30-day boundary even before hourly physical cleanup.

Expect returned job ID numbers, not necessarily “No rows returned.” Rerunning this schedule query updates the named jobs; it does not create duplicate jobs. The endpoint in this script is prepared for project **flhdeftduysnjvqnhhee**.

Check Cron job history, the team-support-email function's invocations, and actual delivery status for a controlled test. A successful SQL/network enqueue alone does not prove the function authenticated or Resend accepted mail. A 401 worker response means the Vault and Edge secret values need to match. Missing provider configuration leaves mail queued and visible as pending.

## 5. Upload the website once

Download `design/coltrain-website.zip` using GitHub's Download raw file, unzip, and upload the entire extracted folder to the existing Netlify site's Deploys page. Wait for Published; refresh colTRAIN. Keep the website public so staff can reach colTRAIN's own authentication.

Both roles now see **hamburger → Team Corner group → Team support**. Admins additionally see **Store feed support** for the existing Team Corner support tool.

## 6. Controlled acceptance test

Use accounts/emails you control. These actions send real notifications and may send a real Emergency email only to the selected manager.

1. Employee → Team support → New message. Select a manager, category Customer, subject and message. Send. The selected manager should get a notification. Another manager and another employee should not see the conversation. An admin who is not the selected participant must not see it either.
2. Selected manager → Notifications → Open conversation → reply. Confirm the employee receives the reply notification. Mark read in either view and confirm thread and global unread counts agree.
3. Manager archives the thread. In Archive, search a keyword used only in a reply; the conversation should be found. The employee can review their own archived thread. A new reply returns it to Inbox.
4. With optional manager email off, send an Emergency message/reply. Confirm the selected manager receives the email, other managers do not, and its link opens only after signing in as the correct participant. Thread delivery status distinguishes accepted, pending, failed, canceled and needs-review jobs.
5. Close colTRAIN, then check that the next minute job invokes the email function successfully without reopening the website. It may process zero jobs if the immediate send already emptied the queue; that is normal. Delayed delivery/retry is covered by isolated local tests. Do not create duplicate production messages or change real staff records merely to force a retry. Provider acceptance is separate from inbox delivery.
6. Manager deletes a test thread; it should move to Trash and disappear from employee access. Restore within 30 days and verify history remains. The 30-day expiry/physical purge is covered locally; do not change real customer timestamps merely to speed up a production test.
7. Test on a phone and shared browser. Drafts survive menu toggles/refresh within the open page, but disappear on sign-out, account switch, store change or page close. No message bodies are placed in persistent browser storage or offline caches.

Email delivery is attempted immediately after sending and retried by the minute job. Leases and stable Resend idempotency keys prevent duplicates across browsers and jobs. Ambiguous attempts older than 23 hours are held for delivery review before Resend's 24-hour idempotency window expires; the UI shows this state. The app is not a monitored emergency-response service: for immediate help, contact the manager directly.

## Local verification

- `python tests/private-support-database.py`: isolated PostgreSQL privacy, selected-manager/admin isolation, manager initiation, notifications/read synchronization, search, concurrent idempotency, unread cutoffs/paging, Emergency opt-out override, delivery leases/review, deletion/restore/expiry and physical cleanup. Prepared scheduler commands are exercised with stub Cron/network interfaces, not real HTTP.
- `node --test tests/support-email-handler.test.mjs`: verified identity, selected-recipient mail, stable idempotency, private scheduler authentication, origin rejection, configuration/provider failures. Resend HTTP is mocked.
- `python tests/private-support-ui.py`: Chromium against actual local SQL/RLS; selected-pair privacy, text escaping, lost-response recovery, inbox/replies, Archive search, Emergency acceptance with opt-out, private deep links, phone layout and Trash recovery. Email transport is stubbed.
- Existing database/training/admin-update browser checks cover the combined package and unchanged features. No local test establishes that hosted jobs or real provider settings are active; those require the owner setup and controlled checks above.
