# Step 4b: connected Team Corner

The owner has applied migrations 001–006, published the training/competition updates, verified a repeat competition quiz with separate lifetime totals, and confirmed the direct manager/employee home screens and signed-in header. Do not rerun those migrations. This Team Corner update is prepared locally; hosted activation and photo acceptance are still pending.

## Included behavior

- A **Team Corner** page in the shared hamburger menu for each store. All active members can post text and/or up to four pictures, comment with text and/or pictures, like/unlike a post, and remove their own posts/comments. There is no forwarding, public sharing link, direct messaging, or video upload in this slice.
- Managers can publish announcements, pin/unpin a post, turn comments off/on, and remove inappropriate posts or comments. Closed comments remain readable, but new comments are rejected on the server. Pinning marks the item as an announcement and gives it a bold blue outline. The post composer has its own bold outline.
- Store conversations use saved database records rather than the sample feed. Author display names are captured when posting; personal email addresses are not displayed in the feed. Content is rendered as plain text, so typed HTML does not execute.
- The feed loads pinned announcements separately from twenty regular posts per page. **Load more posts** and **View earlier comments** retain older discussion. **Refresh feed** retrieves other people's new activity; general live subscriptions and email/push notifications remain Step 5 work.
- Post/comment drafts and selected photos survive opening/closing the hamburger and feed refreshes within the same open application session. Failed uploads keep the draft for retry. Request IDs prevent duplicate posts/comments after network retries, and one uploaded photo cannot attach to two records. Closing/signing out/reloading clears unsent drafts; draft text is not stored permanently on shared devices.
- Photos are private, with authenticated downloads rather than public or reusable signed links. The UI accepts JPEG/PNG/WebP files up to 20 MB before preparation, resizes them, strips embedded metadata through re-encoding, and uploads JPEGs no larger than the existing private bucket's 1 MiB per-image limit. SVG/GIF/HEIC and videos are not supported by this uploader. Choose a JPEG/PNG/WebP or a phone photo picker that exports JPEG for the pilot.
- New upload paths must be reserved for the current member and store. Unpublished photos are readable only by their uploader. After publication, photos are immutable and readable only with access to the associated visible post/comment. Pictures are downloaded as they approach the viewport; local blob URLs are cleared on feed refresh, support expiry, or sign-out. Legacy files from the original private bucket retain their original membership-only rules.
- Removing a post/comment hides its content and linked photos from subsequent feed/storage reads. Removed records and objects are retained privately rather than physically purged; automated retention/purge tooling is not included. Removing a post also hides its comments/likes. Leaving a store denies further reads, uploads, posting, commenting, and liking while preserving the store's existing discussion history.

## Administrator privacy and support

Platform administrator status does not automatically grant access to another store's posts, comments, or photos. The training-progress permissions remain separate. An administrator who is also an active member of their own store uses that store's normal membership permissions.

Only an active store manager can use **Request admin support** with a reason. This grants colTRAIN administrators read-only access for up to 24 hours. The request appears in the administrator's **Team support** menu, where **Open store feed** selects the correct store. It does not send an email yet. Administrators cannot authorize their own request, post, comment, like, pin, close comments, or remove content through a support grant.

Managers can **Revoke support access** at any time. Expiry and revocation are checked on every database/storage request; a grant also becomes invalid if the manager who requested it leaves their manager role. Open administrator support views refresh permissions every 30 seconds and clear at the expiry time. Content already seen/downloaded cannot be recalled, as with other web pages. Support requests, reasons, timestamps, and revocation actors are retained in a private audit table. Employees cannot browse customer support requests.

## 1. Apply only migration 007

In the existing Supabase project's **SQL Editor → New query**, paste the complete contents of:

`supabase/migrations/202610170007_team_corner.sql`

Run it once. Expected result: **Success. No rows returned**.

It creates Team Corner records, access rules, support auditing, and authenticated RPCs. It reuses the existing private `team-media` bucket and tightens new upload registration/immutability. All new tables enable RLS, browser table writes are revoked, and private support records have no browser read privileges. No staff, posts, invitations, assignments, points, or charges are created by the migration. Earlier training history is preserved.

Do not rerun the complete `SETUP.sql`/new-project text file or migrations 001–006. If the SQL Editor shows its generic operations/RLS warning, the script explicitly installs its own RLS and privilege rules. Report any unexpected error before retrying; never rerun a successful migration.

## 2. Publish the updated website

1. Download `design/coltrain-website.zip` from `codex/coltrain-prototype` through GitHub's **Download raw file**.
2. Extract it. The folder contains `index.html`, `accounts/`, and `preview/`.
3. In the existing Netlify project **stalwart-custard-7be489 → Deploys**, upload that extracted folder.
4. Refresh `https://stalwart-custard-7be489.netlify.app/accounts/` and sign in. Choose **hamburger menu → Team Corner**.

No Edge Function, SMTP, Auth callback, or secret changes are required. The ZIP contains three public HTML files with the application code embedded; SQL and privileged server credentials are excluded. The source `/preview/` feed remains sample data.

## 3. Controlled live acceptance

Start with the manager and one employee email you control; do not post real staff content during acceptance.

1. As employee, create one text post with a small JPEG/PNG photo. Confirm the picture loads. Refresh/sign out/in to confirm persistence.
2. Like/unlike the post. Add a comment with a picture, then confirm both manager and employee see it after **Refresh feed**.
3. As manager, pin the post and check the bold outline. Turn off comments and confirm the employee sees the existing discussion but cannot submit another comment. Turn comments back on.
4. Remove the test comment and then post. Confirm they disappear for the employee and their photos cannot be fetched again through normal application access.
5. As manager, request support and confirm the expiry/revocation controls. A platform admin who is not a member of that store should see it in **Team support**, get read-only access, and lose access after manager revocation. The founder's admin/manager account remains a normal member of Coltrain Hardware; use a separate controlled store/identity when doing broader hosted support-isolation acceptance.
6. Confirm another store cannot view posts or photos, and an inactive employee cannot retrieve them. Local SQL checks cover these boundaries, but hosted Supabase Storage/CORS/permissions and real phone photo handling require the pilot checks above.

A successful local test does not establish that the owner has applied the migration or deployed the ZIP. External staff access without the founder's Netlify account, full-capacity seat checks, hosted tenant isolation, notification delivery, installation/shared-device safeguards, and broader pilot rollout remain outstanding acceptance work. Calendar, industry news, expanded course authoring/catalog, manager-only cross-store discussions, AI, and commercial billing remain later features.

## Development evidence

- `npm run test:database`: disposable pinned PostgreSQL; actual RLS and RPCs; store isolation, pending/published/removed photo privacy, announcements/comments, ownership, likes, duplicate submissions, cursor paging, support requests/expiry/revocation/read-only behavior, inactive memberships, and concurrent post/comment/photo attachment rules. Original account/training/competition checks continue to run.
- `python tests/training-ui.py`: browser flow against real local SQL/RLS with mocked Auth and a test-only storage byte adapter. It uses the actual Supabase SDK's multipart uploads/downloads and tests image preparation, preserved drafts, a lost upload response and retry, photo posts and comments, escaped text, likes, moderation, locked administrator access, support discovery/read-only access/revocation, mobile layout, and unchanged training totals. No hosted emails or database writes occur.
- `python tests/account-ui.py`: existing account, callback, invitation, profile, and shared-navigation wiring. The Team Corner addition should not change these flows.
- `npm run build:accounts`, `python scripts/build-supabase-setup.py`, `python scripts/build-hosting.py`: regenerate the public app, new-project-only SQL downloads, and hosting ZIP. New-project setup generation is not a command to run against the existing hosted database.
