# Pilot preparation: in-app training notifications

The owner has confirmed Team Corner posts/photos, author names and optional nicknames, photo comments, closing/reopening comments, removal, and the smaller white comment styling. Cross-store hosted support-isolation testing, real staff access outside the owner's Netlify login, and broader pilot acceptance remain separate.

This slice adds **Notifications** inside the existing hamburger menu, with an unread number and a small indicator on the menu button. No extra top navigation or duplicate dashboard is introduced.

## Behavior

- Active members see their own pending course assignments and the current due date. A changed due date creates a fresh assignment notification. Existing incomplete assignments appear on first use; completed courses do not generate historical assignment notices.
- Deadline reminders use the **store's time zone**, starting three days before the deadline, with a new stage the day before, on the date, and once overdue. The two-to-three-day stage shares a single receipt. Refreshing does not create duplicates or daily overdue spam. Overdue training stays available.
- After the available course attempts are exhausted, employees see a request to ask their manager for help. Active managers in the same store see who needs help and a link to the dashboard's existing retry form. No individual answers, explanation keys, or private support notes are included.
- Unlocking one attempt resolves the manager's help notice and notifies the employee. Competition quiz help/unlocks use separate notifications and link to Competitions; they do not alter original course attempts or lifetime points. Passed/closed competition requests stop appearing.
- **View course**, **Go to dashboard**, and **View competition** open the appropriate existing screens and mark the notification read. Users can mark one or all current notifications read, and read state persists across reloads and devices.
- This is a current-task inbox, not a permanent notification archive. Completed courses, resolved help requests, closed competitions, and superseded deadline stages leave the list automatically. Private read receipts remain so a refresh does not reset their state. Returning to the exact same assignment/date/stage retains its previous read status.
- Notifications are always private to the signed-in user's active store membership. Managers cannot open employee inboxes, other stores cannot read or change receipts, inactive members lose access, and platform admin status supplies no access to somebody else's inbox. An administrator viewing training in a store where they are not a member sees an empty personal notification list.

## Delivery boundaries

Notifications are computed from current server records when signing in, navigating, completing training actions that refresh the workspace, or pressing **Refresh notifications**. There is no scheduled server job, live subscription, browser push, or email delivery in this slice. Someone returning after a deadline sees the current overdue reminder rather than every missed stage. A page left open without interaction does not update its badge in the background.

The personal-email checkbox continues to save a preference; it does not activate training email delivery yet. Auth invitation and security emails remain separate and unchanged. Team posts, likes/comments, competitions starting/ending, aggregate question alerts, and admin support requests do not yet create inbox notifications; their existing screens continue to work. Email delivery, installation, and further shared-device safeguards remain subsequent Step 5 work.

## Apply to the existing pilot

1. In Supabase **SQL Editor → New query**, paste only `supabase/migrations/202610180009_training_notifications.sql` and run it once. Expected: **Success. No rows returned**. Do not rerun migrations 001–008 or the combined NEW-project setup.
2. Download the latest `design/coltrain-website.zip` from GitHub branch `codex/coltrain-prototype`, extract it, and upload its folder containing `index.html`, `accounts/`, and `preview/` to the existing Netlify site's **Deploys** page.
3. Refresh the hosted site. Open **hamburger → Notifications**. No SMTP, Edge Function, Auth callback, or secret changes are required.

The migration adds only a private RLS-enabled read-receipt table and restricted RPCs. It does not change assignments, scores, attempts, courses, memberships, photos, invitation delivery, or billing. It does not create messages or send emails during installation. The new website expects 009, so apply SQL before deploying the ZIP. Supabase's generic function/schema warning can appear; this script creates its own access restrictions and removes no existing records.

## Controlled hosted acceptance

Use only the manager and an active test employee you control.

1. Assign the sample course to an employee who has not completed it. Employee: open Notifications; verify **Training assignment**, then **Mark as read** and refresh/sign out/in. Read status should stay saved. If all test users have passed, use a new controlled test invitation rather than deleting course history.
2. Change that employee's due date to three days from the store's current date. Employee: **Refresh notifications**; verify the fresh assignment deadline and **Training due soon**. Test **View course**. Do not expect an email yet.
3. Where a test user still needs an assisted retry, confirm their manager gets the help notice. Manager: open it, review the material, and unlock one attempt using the existing note. Employee: refresh and open **Another quiz attempt is ready**. Completed courses stop showing reminders.
4. Check the screen on a phone, check that signing out clears the signed-in identity/indicator, and confirm the next person's inbox contains only their own notifications. Cross-store and inactive-user boundaries are covered locally but require separate broader hosted acceptance before rollout.

## Local verification

- `npm run test:database`: fresh pinned PostgreSQL, real RPCs/RLS, own-store recipients, other-user mutation denial, admin isolation, denied anonymous/inactive access, store-local deadline stages, duplicate refreshes, changed deadlines, read persistence, resolved/completed work, original and competition help/unlocks, and concurrent first reads. Existing accounts, invitation, training, competition, and Team Corner checks remain enabled.
- `python tests/training-ui.py`: browser plus actual local SQL/RLS, mocked Auth/storage only. Exercises notification menu/indicator, mark all/read persistence after reload, opening a course, manager help links and employee retry notifications alongside existing end-to-end training/competition/feed flows. No hosted writes or emails.
- `python tests/account-ui.py`: mocked account and profile flows, including existing optional nickname and secure sign-in/callback behavior.
- Build with `npm run build:accounts`, `python scripts/build-supabase-setup.py`, `python scripts/build-hosting.py`. The combined setup is for new projects only. Verify the ZIP still includes exactly three public HTML files with no privileged keys or test-only configuration.
