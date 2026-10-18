# Import the remaining 21 launch courses

These are the CS, IM, HT, HB, PD, LG, and BL courses supplied by the owner. Together with RF-101–104, they complete the approved 25-course launch catalog. The original customer-trust sample stays separate and unchanged.

## Step 1: import drafts into the existing Supabase project

1. Open `REMAINING_21_IMPORT_DRAFTS.sql` in this folder on GitHub.
2. Select **Raw** and copy ALL the text. The file is about 452 KB; use Raw rather than a shortened preview.
3. Open your EXISTING **coltrain-development** project in Supabase. Select **SQL Editor → New query**, keep the normal `postgres` database role, and paste the complete script.
4. Click **Run**.
5. Expect **21 result rows**, each showing `published = false`, `lessons = 5`, and `quiz_questions = 5`.

No new schema update is required: the owner already applied migration 011 for catalog levels/topics/paths. Do not rerun SETUP.sql or earlier migrations. The script inserts course data and metadata, not accounts or departments. It publishes/releases/assigns nothing, and changes no existing training progress.

All 21 inserts share one transaction. If any fails, none are partially imported. An identical rerun validates and adds nothing. A changed existing course aborts instead of overwriting it. Copy the error text if this happens; do not delete existing rows or disable protections. Per-course import files are also supplied, but the combined file is sufficient for this upload.

## Step 2: preview and review

As colTRAIN administrator, refresh the current website, open **Course library**, and use the existing academy/level/path/code filters to find the drafts. You can preview them on the current deployment; importing course data does not require a Netlify deployment.

The drafts are all **Foundations** and map to the approved academy and learning-path memberships. Paths remain browsing labels; they create no duplicate courses, automatic assignments, or prerequisite bypasses. Ordinary managers and employees cannot read unpublished drafts.

Read [the course review notes](../../courses/REMAINING_LAUNCH_REVIEW.md) before publishing. Important items:

- HB-101–104 often include the recommended action in the final question's scenario. These should be strengthened before use as assessments.
- BL-102's five correct answers are all B. Several other courses also have obvious distractors or repetitive positions.
- Product-specific and store-specific references still need review where the source flags them. Database tests validate software behavior, not manufacturer facts or policy accuracy.
- No media files were included. Suggested images stay in the source archives and are omitted from lesson display. These imports are text only.
- HT-101–103 use short-answer reflection practice within lessons. That practice remains unscored; all final quizzes use four-choice questions.

Publishing/releasing/assigning remain separate steps after review. Do not click **Make available to store** while a draft is unpublished; the server correctly rejects that action. The existing website does not have a publish-draft editor. No automatic bulk publication script is included.

## Step 3: deploy the smaller library cards when ready

The updated `design/coltrain-website.zip` contains compact cards: three columns on larger screens, two on tablets, and one on phones, with no large repeated illustration. Titles, levels, status, progress, and course actions remain accessible. Other training/home cards keep their existing layout.

For the UI update, download the ZIP from GitHub using **Download raw file**, unzip it, open the EXISTING Netlify site's **Deploys**, and upload the WHOLE extracted folder. Wait for **Published**, then refresh colTRAIN. Only this UI change needs a Netlify deployment; all 21 draft courses can be imported first without it. Netlify determines deployment/traffic charges from the account's plan and current usage.

Check desktop and phone library layouts, Search/Clear filters, and Preview course. Verify the first draft's full lessons are readable. Keep drafts unpublished until editorial approval and a pilot training check are complete.

## Developer validation

Run `python scripts/build-launch-course-imports.py` to rebuild sources into the current schema. Each course has a full-text source archive, structured import, and source-hash/review manifest. Final quiz keys, source documents, and SQL imports are excluded from the public hosting ZIP.

`python tests/launch-course-imports.py` checks every new course with actual local SQL/RLS: full imported content, draft visibility, cross-store isolation, lesson gating, 60% failure, an 80% passing boundary, three-attempt blocking, manager unlock, one-time points/trophies, learner-only feedback, review competition scoring, and immutable-content reruns. It also checks atomic batch rollback, preservation of existing RF completions, and rejection of conflicting structured answers. Local fixtures are published only inside the disposable test database.

`python tests/training-ui.py` previews all 25 real course imports in a mocked-Auth/local-SQL browser, checks compact card layout at desktop/phone widths, and exercises filters and the full five-lesson CS-101 preview. These tests do not write to hosted Supabase or Netlify.
