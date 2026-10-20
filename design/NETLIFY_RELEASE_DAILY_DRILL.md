# Combined release: academies and The Daily Drill

Prepared for owner publication after Netlify credits became available. This guide does not mean a deployment has occurred.

## Included website changes

- Approved ten-academy mapping, including RF-103 in Customer Service & Retail Readiness. Existing course codes, source content and progress preserved.
- Admin academy plan (260 planned modules, 88/112/60), separate from actual available/completed counts.
- The Daily Drill dashboard card below competition and above regular course progress; personal card also on manager dashboard.
- Text-only lesson reader, safe tables/source links, quick check, server feedback/retries, saved completion, automatic next module and completed review.
- Actual available/completed Daily counts that update as modules are released and completed. Future planned content is not presented as available.
- All prior website changes remain in the cumulative ZIP, including library filters/compact cards, accounts, avatars, Team Corner and device safeguards.

Manager team Daily reports, Daily points/trophies/final badge issuance, media assets, calendar/RSS and future catalog expansion are not implemented by this upload.

## A. Enable the approved Daily pilot in Supabase

Owner already confirmed the sequence migration (013) succeeded. Do not rerun older migrations or SETUP.sql.

1. Open the existing coltrain-development project's SQL Editor → New query.
2. Open `supabase/daily-imports/PILOT_10_RELEASE_COLTRAIN_HARDWARE.sql`, choose Raw, and copy the complete file into that query.
3. Select Run. Expected: 10 rows with `published=true`, `available_to_coltrain_hardware=true`, and `active_members_enrolled` equal to the store's current active membership count, including managers.
4. If an error occurs, stop and send the exact message. The script validates imported versions and sequence first and rolls back all changes on failure. Missing drafts/sequence can be addressed separately; do not rerun the whole project setup.

This publishes the approved text-only Daily pilot and releases it only to the uniquely named Coltrain Hardware store. It automatically enrolls active members; future joiners enroll through migration 013's existing triggers. It sends no invitation or training emails and does not publish the other full-course drafts. A matching rerun is safe and preserves completions/attempts. The administrator UUID is the owner's previously supplied/verified identity; no secret key or password is included.

## B. Upload ONE combined website release

1. Download `design/coltrain-website.zip` from GitHub using Download raw file.
2. Unzip it. The extracted folder must contain `index.html`, `accounts`, `preview` and `_headers`.
3. Open the existing Netlify site `stalwart-custard-7be489` → Deploys.
4. Drag the whole extracted folder into the manual deployment area. Do not create a new site, upload only an HTML file, or upload SQL/source files.
5. Wait for Published. Open the live `/accounts/` page and refresh. If using the installed home-screen shortcut, close and reopen it.

No Auth redirects, Edge Functions, domain settings or browser environment values need changing.

## C. Owner acceptance checks

- Employee dashboard: The Daily Drill below competition, next drill “Paint Sheen: Recognize the Finish,” Foundations “0 completed · 10 available” for an unused test account, and Application/Expertise zero available.
- Open the lesson, inspect the comparison table, answer incorrectly once, read feedback, review the lesson and answer correctly.
- Confirm next drill “Name the Plumbing Connection” unlocks. Return to dashboard and verify completion increased by one.
- Refresh/sign back in and confirm progress remains. Review a completed lesson without a new scored attempt.
- Manager dashboard shows the manager's own Drill progress, independent of the employee's. Existing full-course assignments, points, trophies, Team Corner and avatars continue to work.
- Admin Course library shows new academy labels/filtering and the planned academy table. Draft content has not been automatically published or released by the website ZIP.
- Phone: no horizontal page overflow, readable lesson/table and usable buttons.

Use a test account for acceptance if you do not want real employee records changed. Completion tests save real Daily progress when run on the live site; no automatic cleanup/reset is performed.

## Verification before owner execution

13 library/Daily UI unit checks passed, the production public package/PWA checks passed, and 14 local pilot-release/fresh-import checks passed. The earlier full Chromium training and Daily flows passed against actual isolated PostgreSQL/RLS. The release test verifies ambiguous-store rejection, late-error atomic rollback, publication/enrollment, tenant isolation and progress-preserving reruns. No live Supabase release or Netlify deployment has been executed by Codex.
