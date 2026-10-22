# Direct and group private messaging

Owner deployment required. Codex has not changed the hosted database, sent real messages/emails/pushes or deployed Netlify.

## Approved behavior

- **Team support** remains the menu entry for private messaging. Every active employee or manager can select any other active teammates in their own store: one for a direct conversation, or up to 50 for a group. Employees can message employees; managers can message managers. The creator is automatically included. Self-only, inactive and cross-store selections are rejected by the database.
- Everyone selected sees all messages/replies and the complete participant list. The participant list is fixed at creation; start a new conversation to select a different group. No automatic readers are added through promotion, admin status or temporary Team Corner support access. Existing pair conversations, message history, read receipts and pending email job IDs are preserved without adding readers.
- Each new message/reply notifies all other active, non-deleted participants through the existing in-app inbox and their optional personal-device Web Push. No self in-app alerts. Existing badge, device consent, shared-device protection and sign-out cleanup continue to apply. Lock-screen push remains count-only. Ordinary messages do not send new emails.
- **Every Emergency conversation/message must include at least one active manager who has not deleted their personal copy.** A manager author counts. An employee-only conversation cannot be marked Emergency; start a new conversation including a manager. If its last manager becomes inactive, is demoted or deletes their copy, further Emergency replies are blocked until a new conversation is started with an available manager. Normal conversations among remaining active people can continue.
- Each included active manager gets a separate Emergency email request, regardless of optional email preference. No managers outside the selected group receive it. Manager-authored Emergency messages can email that author as in the previous feature. Email delivery rechecks membership, current role and personal deletion; stale jobs are canceled. Stable per-manager job IDs, leases and provider idempotency keys preserve retries without intentionally duplicating requests. Email/push delivery is not guaranteed immediate; contact a manager directly for immediate help.
- Every participant has personal Mark as read, Archive, Move to inbox, Delete, Restore and searchable Archive/Trash. Read status affects only that person. Replies reopen archived personal inboxes. Delete hides only that person's copy and its in-app alerts; other participants retain access and can keep replying. New messages do not move a deleted copy back into Inbox. Restore within 30 days returns its history, including replies sent while hidden. It does not reset previous read receipts.
- After 30 days, the deleted personal copy is inaccessible and cannot be restored. Other participants' copies and shared message history remain. The existing hourly cleanup physically removes the thread/messages/jobs only when **all** personal copies have expired. This differs from deleting a shared conversation for everyone. Old shared Archive/Trash state is copied onto each original participant during migration; already-expired legacy shared Trash is cleaned under the previously approved retention rule first.
- Inactive participants lose read/reply access immediately. Remaining active participants can continue when another active participant remains. Their names remain in the fixed roster with an inactive label; unrelated replacements inherit nothing. No group membership editing, attachments, read-by rosters or moderator/admin access is added in this update.

## 1. Database update

After migration 021, copy all Raw contents of **supabase/migrations/202610220022_group_private_messages.sql** into a new Supabase SQL Editor query and Run once. Expect **Success. No rows returned**. Do not rerun SETUP.sql or previous migrations.

This adds private participant/inbox state, migrates existing conversations, expands Emergency jobs to one per included manager, and replaces guarded RPCs. Supabase may show its routine-change/destructive-operation warning: existing non-expired conversations and learning records are preserved; the only content cleanup is legacy Trash already past the approved 30-day expiry. The private participant table has RLS enabled, no browser direct table grants, and store-consistent foreign keys. Only authenticated participant RPCs expose it.

## 2. Update the existing email function

In Supabase → Edge Functions → **team-support-email → Code**, replace all of **index.ts** with the Raw contents of **supabase/team-support-email-function.ts**. Save/deploy the existing function; do not create a new name. Keep **Verify JWT with legacy secret OFF**. This updates the email wording to describe included managers; the function's per-job transport and worker identity stay the same.

No new signing keys, Resend keys, worker credentials, Vault entries or Cron jobs are needed. Existing Emergency email, Web Push and retention schedules remain in place.

## 3. Publish the website once

Download **design/coltrain-website.zip**, unzip, and upload the entire extracted folder to the existing Netlify site's Deploys page. Wait for Published, refresh colTRAIN, and close/reopen home-screen installs. Apply the database first, then update the website promptly so everyone gets the participant selector and personal-inbox labels.

## 4. Controlled acceptance checks

Use test accounts you control; these actions create real notifications and Emergency emails only for explicitly selected participants.

1. Employee → Team support → New message. Search for an employee, select them, enter subject/body and send. Confirm the recipient can read/reply and an unselected teammate cannot see the conversation. Try manager-to-manager messaging too.
2. Select two or more teammates to create a group. Confirm everyone selected sees the roster and all replies. Check an unselected employee, unselected manager and nonparticipant admin do not gain access. No other store should appear in the contact selector.
3. Archive as one participant. Confirm the others' inboxes stay unchanged. Search Archive with a keyword found only in a reply. A later reply reopens the archived copy.
4. Delete as one participant. Confirm the other participants can still read/reply. The deleted copy stays in that person's Trash without new alerts. Restore within 30 days and check history is intact. Do not change real timestamps to simulate expiry; local database tests cover expiry/physical cleanup.
5. Start an employee-only Emergency conversation: it must be blocked with instructions to include a manager. Select an active manager and send. With optional manager email off, confirm only included managers receive Emergency email; selected non-manager recipients receive in-app/optional push alerts, not Emergency email. Test a group with two managers to verify separate deliveries.
6. On supported personal phones, background colTRAIN and send a group reply from a different account. Allow a minute or two; generic push and unread badge should follow the existing device opt-in. Clicking the alert opens the authenticated Notifications inbox, then Open conversation. Signing out must still clear/unsubscribe that device.
7. Check one existing conversation after migration. Same original readers/history; personal Archive/Delete now affect only the person using them. New participant roster/search controls should fit phone screens.

## Local verification

- `python tests/group-support-database.py`: migration from existing pair/archive data; same-role contacts/direct messages; group roster and per-recipient privacy/read state; idempotent retries; personal Archive/Trash/restore/expiry; included-manager Emergency requirement and separate opted-out manager mail jobs; replacement/promotion privacy and physical purge only after the last personal copy expires.
- `python tests/private-support-ui.py`: real SQL/RLS + Chromium for peer/group selection/search, Emergency validation, multiple-manager acceptance, shared replies, independent employee Trash/restore, draft/retry handling, private links and phone layout. All email HTTP is stubbed.
- `python tests/private-support-database.py`: historical selected-pair behavior through migration 021, retained as a baseline regression; migration 022/current policy are tested separately above.
- Existing Web Push, notification, training and database regressions run against the new migration. Real hosted phone/email acceptance still requires the owner checks above.
