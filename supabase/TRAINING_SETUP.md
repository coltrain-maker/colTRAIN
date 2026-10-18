# Step 3: connected sample training

The owner has applied the Step 3 migration and deployed the initial training website. On October 17, 2026, they confirmed course release and assignment, ordered lesson completion, a live 100% quiz result with 50 points and a trophy, persistence after signing back in, and the matching manager report. A separate controlled employee failed three times and was blocked from a fourth attempt. The owner subsequently verified a manager-assisted fourth attempt, a 100% passing score, saved points/trophy, and the matching manager view. Local automated tests create only isolated test data, never hosted training records.

The owner deployed the completed-lesson review navigation fix below. The owner also deployed and applied the approved starter-department template, verified multi-department placement, and confirmed that a department-targeted deadline update changed only the selected employee while preserving completion, points, and trophy. Neither change needs another SQL migration. The original migration instructions remain reference material; do not rerun the already-applied training migration on this project.

## What is included

- The agreed **Customer Service: Building Customer Trust** sample: three ordered lessons, five questions, and an 80% passing score. Content comes from the existing approved prototype. No Toolbox Tuesday branding, attendance rules, or faith-based onboarding text is included in this shared course.
- Explicit administrator release of a course to a store, separate from assigning it to employees. No store is automatically enrolled or assigned by the migration.
- Department creation and placement in multiple departments. Managers assign a course to one/some/all employees, one/some/all populated departments, or their union. Matching people are deduplicated. A manager can explicitly select their own account for training as well.
- A default deadline of 30 calendar days in the store's configured time zone (currently America/New_York). Managers can give new hires separate deadlines or revise selected employees' deadlines. An overdue assignment remains accessible.
- Saved, sequential lesson completion. Lessons award checkmarks, not points. Available courses can be previewed without enrollment; taking a scored quiz requires an active assignment.
- Three total scored quiz submissions, not three retries. Questions are shuffled in the browser; answer options retain their server-defined order. Incomplete/invalid submissions do not consume an attempt. Unsaved answers remain in memory and are cleared by refreshing.
- Server-side scoring with private answer keys. Each newly correct answer earns 10 points once per person and question, across retries and rehiring. An idempotency key makes network retries return the original result. Concurrent submissions cannot exceed the attempt limit.
- Standard trophy on passing. Previously earned points are retained after failure; passing at 80% may earn 40 of the available 50 points. Passed courses are reviewable, with no further scored attempts. Rejoining through another seat does not duplicate points/trophies or inherit another employee's history.
- Learner-only missed-answer explanations after a submitted quiz. Managers and administrators see progress/scores but cannot retrieve another person's selections, answer review, or question-level point records.
- Manager-assisted retry unlock after all available attempts are used. A short assistance note is saved; each unlock allows one additional attempt and does not reset prior scores or points.
- Manager dashboard with the agreed employee/status/course/competition-points/lifetime-points column order. Step 4 adds competition values separately; see COMPETITIONS_SETUP.md. Progress, due dates, overdue status, latest scores, and lifetime points come from the database. Departed employee histories stay available to the store's manager/admin while active employees cannot access former memberships' training.
- Store question alerts for three distinct employees missing the same question on their first attempt; administrator alerts aggregate across stores. No individual answer names are disclosed. These are in-app summaries; email notification delivery is still Step 5.
- Frozen course versions once assigned. Future authoring should create a new version rather than changing existing learners' lesson/quiz content. Removing a course from a store library prevents new assignments but preserves existing assignments to that version.

## 1. Apply only the training migration

In the existing Supabase project's SQL Editor, create a new query and run the complete contents of:

`supabase/migrations/202610170005_training.sql`

Run it once. The migration is transactional and preserves existing accounts, invitations, stores, and seats. Expected result: **Success. No rows returned**. It creates the training tables, access rules, private scoring functions, and sample course. It does not release that course to any organization, send emails, create employees, or charge anything. Do not rerun `SETUP.sql` or earlier migrations against this existing project.

## 2. Update the existing Netlify website

The prepared download is `design/coltrain-website.zip` on the development branch. Download it through GitHub's **Download raw file**, extract it, and confirm the folder contains `index.html`, `accounts/`, and `preview/`.

In the **existing** Netlify project `stalwart-custard-7be489`, open **Deploys** and upload that extracted folder as a new manual deployment. Do not create another Netlify project: the current Auth redirect settings and invitation function use this exact hostname. No Supabase Edge Function update or new secrets are required for Step 3.

The published root now sends visitors to `/accounts/`. The separate `/preview/` page is clearly a sample-only design preview. The source repository's root `index.html` remains the prototype for design development. Only three public HTML files are in the ZIP; SQL, tests, server functions, and privileged credentials are excluded.

Existing Supabase callback URLs under `/accounts/` continue to work. Open the hosted URL, refresh the page, and sign in normally. Downloaded HTML files do not update automatically and are not the supported live training entry.

## 3. Release and assign the course

1. Sign in with the existing administrator/manager account at `https://stalwart-custard-7be489.netlify.app/accounts/`.
2. Signing in opens the manager Dashboard or employee Home directly. The top-right hamburger contains courses, competitions, account & team settings, and Sign out. Account & team settings retains that same menu for returning to the Dashboard/Home.
3. Open **Course library**. As administrator, select **Make available to store** on the sample course. If overseeing multiple stores, select the intended store first. Only administrators can release global courses.
4. Choose **Assign training**, select the course, a deadline, and one controlled test employee. Select **Assign course**. Assigning one test employee first avoids distributing an untested course to the whole team.
5. Optionally create **Departments** and place people in one or more departments. Assignment targets select the union of departments and individually checked employees. Check **All active employees** to assign to the entire active employee team; managers are included only when explicitly checked.

## 4. Verify the hosted flow with controlled accounts

Before inviting all nine employees:

- Employee signs in directly to Home, sees the assignment and due date, completes the lessons in order, submits a quiz, and receives the appropriate points/result and trophy only on passing.
- Sign out/in or refresh to confirm progress is saved in Supabase. A lesson should never award points, and retrying the same previously correct questions should not award them again.
- Manager signs in and sees that employee's progress, score, completion, and lifetime points, without their missed-answer details.
- A separate controlled account deliberately fails three times; a fourth submission is blocked. Manager supplies help and a note and unlocks one retry. All prior attempts/points stay saved.
- Another store and separate identities verify hosted data separation. Full-capacity seat checks, live storage upload checks, and removal of access during an already-open training session remain part of pilot acceptance.
- Confirm that the login/acceptance page can be opened by intended pilot employees without requiring the founder's Netlify account. The cloud's last independent request returned HTTP 401 from Netlify, so public staff access has not been verified.

Do not use tests to manually pass an employee, bulk reset attempts, or edit private scores. The production UI has no such bypass.

## Local development and evidence

```sh
npm run build:accounts
npm run test:database
python tests/account-ui.py
python tests/training-ui.py
python scripts/build-supabase-setup.py
python scripts/build-hosting.py
```

The SQL tests use an isolated, disposable PostgreSQL 17 container. They cover store/role access, explicit release, department assignments, lesson order, private answers, scoring, attempts, duplicate requests, points/trophies, first-attempt alerts, course immutability, departures, replacements, rehires, and concurrent submissions.

The training browser test uses the actual local SQL functions and RLS behind a small test-only HTTP adapter. Supabase Auth responses are mocked; no passwords or emails are sent to the hosted project. It exercises administrator release, department setup/assignment, learner lesson completion, a failed quiz and explanations, a passing retry, persistence after reload, manager reporting, mobile layout, and returning to account settings. This does not replace a hosted Supabase/PostgREST acceptance test.

The existing account browser test and email handler tests remain applicable. A successful local build or test does not establish that the owner has deployed the migration/website or that hosted tenant boundaries have been independently tested.

## Remaining stages

Step 4a now prepares competitions, review challenges for previous graduates, and active-learning estimates; see COMPETITIONS_SETUP.md for its incremental migration, deployment, and tests. Step 4b prepares the connected Team Corner; see TEAM_CORNER_SETUP.md for its incremental migration, photo/privacy checks, and pilot deployment. Step 5 adds assignment/reminder notification delivery and preferences, home-screen installation, and broader pilot checks. The calendar, news feed, AI assistant, expanded catalog, commercial billing, and full course authoring remain outside this Step 3 slice. Lesson media/upload tools and authoring for manager-created onboarding need their own implementation; the first connected course uses the existing text lessons.

## Completed-lesson review navigation update

The owner reported that marking an already-completed lesson again during review appeared to do nothing, requiring use of the Knowledge Check sidebar link. The cause was the completion handler reopening the first unfinished lesson; when all lessons were complete, it returned to lesson one.

Completed lessons now show **Next lesson** and an explicit already-completed note instead of requiring another completion write. The last lesson shows **Try knowledge check again**, **Get manager help** after the limit, or **View course result** after passing. These same actions are reflected in the sidebar. Opening a course or starting the quiz refreshes the saved assignment so a new manager unlock is recognized. Lesson review itself does not consume attempts or earn points.

Deploy the updated `design/coltrain-website.zip` to the existing Netlify project's Deploys upload area. No SQL or Edge Function changes are required. The real-SQL browser regression now covers reviewing all lessons after failure, three failed attempts and the block, manager-assisted unlock, successful fourth attempt, and completed-course review without an extra submission.

## Approved starter department template

The owner approved these initial department names for Coltrain Hardware:

- Front Counter & Customer Service
- Paint
- Hardware & Fasteners
- Plumbing
- Electrical
- Lawn & Garden

The Departments page now offers **Add starter departments** with a visible list of all six names. Applying it uses the existing manager-authorized `create_training_department` RPC for the selected store only. It refreshes current department names, skips names already present (case-insensitively), keeps custom departments and existing employee placements, and becomes disabled once all six names are available. If a partial request fails, created departments stay saved and retrying adds only missing names. Employees are not placed into departments or assigned courses automatically.

This template needs only the updated website ZIP deployed to the existing Netlify project. No SQL or Edge Function update is needed. After deployment, sign in as manager, use the hamburger menu to open Departments, then select Add starter departments. In Employee departments, choose a person, check one or more departments, and Save departments.

The real-SQL browser test starts with an existing Paint department and employee placement plus a custom Receiving department. Applying the template adds only five names, preserves both existing department IDs/placements and Receiving, and does not duplicate names on a subsequent visit. Department assignment remains covered by the existing SQL and browser flow. The owner confirmed applying the template, placing a controlled employee in Paint and Front Counter & Customer Service, and verifying department-targeted assignment results.
