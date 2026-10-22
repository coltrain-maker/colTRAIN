# New Team Corner post notifications

Prepared for owner deployment. No hosted SQL, emails or real push messages were sent by Codex.

- New Team Corner posts and announcements (text or photos) notify every other active manager/employee in that store. The author, inactive staff, other stores, and admins with only temporary support access are excluded.
- Only posts created after this update create alerts. Existing posts, comments, likes, edits, pinning and photo attachment do not create extra alerts. Retrying the same post does not duplicate notifications or reset read state. Newly enrolled staff do not inherit old-post alerts.
- Notifications appear in the existing in-app inbox and contribute to the existing unread badge and optional personal-device Web Push. Existing web-push function, signing keys and Cron job do not need changes. Generic lock-screen alerts remain count-only; no post content is exposed. No new email alerts are added.
- **View team post** marks that notification read and opens the specific post, even beyond the first feed page. It retains normal feed comments, photos, likes and manager controls. Removed posts leave the notification list; inactive members lose access immediately. A closed phone's badge catches up at the next alert/open, as with the existing push feature.

## Deployment

1. In the existing Supabase project, SQL Editor → New query. Paste all Raw contents of **supabase/migrations/202610220021_team_post_notifications.sql** and Run once after 020. Expect **Success. No rows returned**. Do not rerun SETUP.sql or previous migrations. The private audience table has RLS enabled and no browser read/write grants.
2. Download **design/coltrain-website.zip**, unzip, upload the extracted folder to the existing Netlify site's Deploys page, wait Published, then refresh colTRAIN. Existing home-screen installs may need closing/reopening.
3. Sign in as an employee, create a new Team Corner post. Another active employee and the store manager should see **New Team Corner post** in Notifications within the normal refresh interval. The author should not receive their own alert. Test an announcement as well.
4. On a personal phone that already enabled device notifications, background colTRAIN and create another post from a different account. Allow a minute or two for the existing worker. Confirm generic alert/badge, then tap through Notifications → View team post. Older existing posts should not suddenly notify the team.
5. Mark read; verify unread count decreases. Remove a test post and refresh recipient Notifications to confirm its alert disappears. Comments/likes should not create new alerts. Don't use real sensitive material for testing.

## Local checks

`python tests/team-post-notifications.py` tests all migrations in disposable PostgreSQL: exact store audience, no self/admin/other-store/inactive alerts, no historical/late-join backfill, read receipts and idempotent retries, comment/like/pin behavior, exact-post access, deletion, and integration with the existing Web Push claim/snapshot.

`python tests/training-ui.py` covers real SQL/RLS and browser notifications → specific Team Corner post, including an older post beyond page one, as well as existing training/competitions/feed behavior. Real phone delivery remains a hosted device acceptance check.
