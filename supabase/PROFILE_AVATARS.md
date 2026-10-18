# Private profile pictures and account avatars

The owner has confirmed phone access/home-screen setup and the reorganized menu: Home/Dashboard; training; Team Corner; competitions/leaderboard; settings; sign out. Migrations 001–009 are already applied. Notification delivery remains pending a new unfinished assignment or changed deadline.

This update lets each signed-in person choose, preview, save, replace, or remove their own profile picture in **Settings → Account & team settings → Your profile → Profile picture**. Initials are used before a photo is added and if a photo cannot be loaded. Managers and administrators use the same controls for their own accounts; they cannot change another person's picture through these RPCs.

The current photo appears in the signed-in header, account settings, manager employee rows, account/team member rows, Team Corner posts and comments, and competition/lifetime standings. Existing posts/comments follow a replacement picture without republishing. Profile full names and optional Team Corner nicknames remain separate and unchanged. Some name-only selectors and system notifications continue to use text rather than portraits.

## Deployment to the existing pilot

1. In Supabase **SQL Editor → New query**, paste only `supabase/migrations/202610180010_profile_avatars.sql`. Run it once. Expected: **Success. No rows returned**. Do not rerun 001–009 or the complete new-project setup.
2. Download the latest `design/coltrain-website.zip` from GitHub branch `codex/coltrain-prototype`, extract it, and upload the whole folder to the existing Netlify site **stalwart-custard-7be489 → Deploys**. Keep the installation assets and `_headers` file together. The ZIP remains the eleven-file public allowlist.
3. Refresh the website or reopen/reload the installed app online. In **Account & team settings**, choose a JPG, PNG, or WebP photo with the face near the center. Review the circular preview and choose **Save photo**. Use **Remove photo** to return to initials. If the account has no saved profile yet, save its Name/Save preferences first.

Apply SQL before publishing the website: the account settings now request the profile's `avatar_path` field. No SMTP, Edge Function, Auth callback, service-role credential, billing, or invitation change is needed.

The migration adds a private avatar bucket, private upload-registration records, a nullable profile-photo pointer, and restricted RPCs. It wraps the existing training report rather than replacing its permissions/scoring, and adds current avatar paths to the existing feed serializers. No courses, seats, points, trophies, posts, or existing pictures are removed. Generic Supabase warnings can appear because the report function moves into a private wrapper; the transaction preserves its behavior and installs explicit permissions.

## Privacy and image handling

- `profile-photos` is a **private** bucket limited to JPEG images of at most 1 MiB. The browser accepts JPG/PNG/WebP input up to 20 MB, center-crops to a 512-pixel square, re-encodes as JPEG, and strips embedded metadata through canvas encoding. The preview is local until saved. Crop adjustment, video, HEIC/GIF/SVG upload, and manager-uploaded staff pictures are not included.
- The server reserves a user/UUID path for the authenticated owner. Unpublished images are readable only by that owner. The owner must finish the upload before selecting it; another user cannot claim the ID or select that photo. A selected path is immutable, and retired paths cannot be reused with different bytes.
- A published avatar follows the app's existing **profile visibility** permissions: the owner, active teammates, their store manager (including historical staff), and the platform administrator who already has cross-store profile/training support access. An unrelated store cannot read it. An inactive staff member loses access to former teammates' photos but retains access to their own profile.
- Avatar access is profile data access, not access to Team Corner discussion or uploaded team photos. The separate manager-requested support rules for store conversations remain intact. Feed serialization emits no avatar path if the caller cannot view that author's profile; a departed author can therefore show initials to employees while remaining visible to their manager.
- Reads use authenticated downloads and in-memory blob URLs, not public buckets or reusable signed links. The avatar loader deduplicates downloads and clears its URLs/in-flight generation on sign-out. The home-screen service worker still caches no account images or API data.
- Replacing/removing immediately changes which file peers can read. Old files are deleted on a best-effort client request after the pointer changes. Failed or cancelled pending uploads and failed cleanup can leave owner-only files/registration metadata privately stored; automated orphan retention/purge is not included. Content someone already viewed cannot be recalled from their device.
- Loading another person's latest photo still requires a page/workspace/feed refresh. There is no new live subscription or notification email for picture changes. Picture changes do not consume paid seats or reset training history.

## Controlled hosted acceptance

1. As a test employee, open Account & team settings, choose a small photo, inspect the preview, and Save photo. Confirm the header uses it after refresh/sign-out/in.
2. Create or revisit an existing Team Corner post/comment. Confirm employee and manager see the same avatar after **Refresh feed**. Check lifetime standings and the manager's employee table.
3. Replace the picture, then remove it. Confirm existing posts update and removal restores initials. Confirm another signed-in test account retains its own picture/initials when switching users.
4. Test on the phone home-screen app, including a real phone photo-picker export. If the picker provides HEIC, export/choose a JPEG/PNG/WebP. External staff access, broader hosted tenant isolation, and notification delivery remain separate pilot acceptance work.

## Local verification

- `npm run test:database`: all migrations in disposable pinned PostgreSQL; avatar reservations, owner/pending/current reads, wrong-store/inactive/anonymous denial, another user's upload-ID rejection, immutable files, set-before-upload rejection, idempotent selection, replacement/removal, retired-path rejection, profile/admin versus feed permissions, roster/lifetime integration, and original training/feed tests. 329 SQL assertions plus existing concurrency checks pass.
- `python tests/training-ui.py`: browser plus actual local SQL/RLS, mocked Auth and storage bytes. It checks local preview, a lost successful upload response and safe retry, header/post/comment/lifetime avatars, replacement, removal/physical cleanup, and then the existing training/competition/notification/feed flows. No hosted writes or email delivery.
- `python tests/account-ui.py`: existing sign-in/profile/nickname/invitation/callback/menu/mobile checks with mocked responses pass. The installation assets and eleven-file packaging are unchanged and verified during the final build.
- Build with `npm run build:accounts`, `python scripts/build-supabase-setup.py` (new-project-only SQL), and `python scripts/build-hosting.py`. The new shared `accounts/avatars.js` is embedded by the normal account build; no dependency installation is added.
