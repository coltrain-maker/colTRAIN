# colTRAIN Daily: existing pilot setup

**Updated requirement:** after the two files below, apply migration 013 using `DAILY_SEQUENCE_SETUP.md`. It replaces manual department/date assignment with automatic enrollment for every active member and a shared Foundations → Application → Expertise sequence. The manual-assignment contract described below is the historical migration-012 foundation, not the final behavior.

Prepared October 19, 2026. This adds Daily tables/functions alongside the existing full-course training flow. It requires account/training migrations 001–011 already installed. Do not rerun older migrations or the combined SETUP.sql against the existing project.

## Owner steps: two SQL queries, in this order

1. Open the existing **coltrain-development** Supabase project.
2. Open **SQL Editor**, then **New query** (the + button).
3. Open `supabase/migrations/202610190012_daily.sql` on GitHub, select **Raw**, and copy the entire SQL file. Paste into the new query. Optionally name it “colTRAIN Daily database setup.”
4. Select **Run**. Expected: **Success. No rows returned**. Run this migration only once. If an error occurs, stop and share the exact error; do not continue to the import.
5. Create another **New query**. Open `supabase/daily-imports/PILOT_10_IMPORT_DRAFTS.sql`, select **Raw**, and copy its entire contents into that query. Optionally name it “colTRAIN Daily 10 pilot modules.”
6. Select **Run**. Expected: **10 result rows**, CD-0001 through CD-0010, each `published=false` and `questions=1`. Module versions are 0.1.0 or 0.2.0; package version 1.0.0 does not replace these source versions.
7. Leave these as drafts. There is no website deployment for this step; the existing website will look the same. Next apply migration 013 using DAILY_SEQUENCE_SETUP.md. Publication and store release will be tested with the Daily screens later.

Use the SQL Editor's default postgres role. Do not paste keys, passwords or personal employee details into either file. Query 2 contains private answer keys for the private database tables; do not put it into a public website or browser application.

The import is one transaction. An identical rerun is safe, even after publication or completion. Changed content under an existing version raises an error rather than overwriting it, and the whole import rolls back. No module is automatically published, released or assigned. Existing accounts, seats, course progress, points and trophies are not edited.

## Initial Daily behavior

- The ten approved modules retain their IDs, versions, academy assignments and text. All are Foundations. No image files were supplied or invented; these text-only drafts have no image placeholders.
- Admin publishes a complete module version, then separately enables it for chosen stores. Publishing alone grants no staff access.
- Managers can assign a released module to individual employees, department groups, or all active employees. Overlapping targets are deduplicated. “All employees” excludes managers; a manager can explicitly select their own membership if they want to participate.
- Availability defaults to today in the store's configured time zone, or a manager supplies a date. Employees can see their scheduled assignment summary, but cannot open its teaching or quiz before that date.
- No forced daily attendance, deadlines, overdue flags or streak penalties. Recurring calendars and automatic distribution are not implemented yet.
- All answers correct completes a module. An incorrect answer returns explanations and allows another attempt without the full-course three-attempt lock.
- No Daily points, trophies or competition scoring yet. Full-course completion and award rules are unchanged.
- Reassigning the same version does not reset completion or attempts. A not-started assignment can have its date changed; a started assignment stays accessible. Withdrawing a store release prevents new assignments but preserves existing ones and their records. Published content is immutable; revisions use a new version.
- Estimated active time uses bounded server-time heartbeats, maximum 60 seconds per accepted interval. The future UI must call these only while the lesson is visible and the learner is active. It is an activity estimate, not attendance, payroll or proof of lesson reading; there is no minimum-time gate.

## Tables and privacy

Public RLS tables: `daily_modules`, `daily_questions`, `daily_releases`, `daily_assignments`. Clients have SELECT only. Module content is readable by admins, store managers for their available/assigned modules, and active assigned learners once available. Release summaries do not expose the complete lesson/quiz early.

Private tables: `daily_answer_keys`, `daily_editorial`, `daily_attempts`. All privileges are revoked from browser roles. Original full Markdown and reviewer material stay in private editorial records; public modules contain teaching sections and public source references only. Questions never include the key. The server returns feedback only after a valid submission. Managers/admins can see completion/attempt-count/time summaries; the answer-review RPC is learner-only, including for users who also hold a manager role.

All public RPCs check the caller. Browser roles cannot write completion, grading, attempts or activity totals directly. Inactive members lose read and submit access while their historical records remain available to authorized store management/admin support.

## RPC contract for the later website work

- `publish_daily_module(module uuid)` — admin, validates one or two four-option questions and complete private keys, idempotent.
- `release_daily_module(store uuid, module uuid, available boolean default true)` — admin, published versions only, no autoassignment.
- `assign_daily_module(module uuid, store uuid, employee_ids uuid[] default '{}', department_ids uuid[] default '{}', all_employees boolean default false, start_date date default null)` — authorized manager/admin, returns affected target count, atomic validation.
- `get_daily_workspace(store uuid)` — authorized store summaries; ordinary staff see only their assignment rows. Admin can review draft summaries.
- `get_daily_module(assignment uuid)` — active learner, starts/resumes their available assignment; returns teaching/source data and question IDs/options, no keys. It remains usable for completed review.
- `submit_daily_check(assignment uuid, answers jsonb, submission_key uuid)` — active learner, previously opened module. `answers` is an array of `{ "question_id": "CD-0001-Q01", "option": 0 }`; option indices are 0–3. The caller generates a UUID once per intended submission and reuses it when retrying a network request. Replays return the original result even if payload changes, without adding attempts. Wrong answers can be retried with a new key. After completion, new graded attempts are refused, while original-key replays still work.
- `get_daily_result(assignment uuid)` — own active learner's latest feedback only, for reload recovery.
- `record_daily_activity(assignment uuid)` — own active opened assignment, bounded elapsed-time estimate; no additional activity after completion.

No service-role key or Edge Function is required in the browser. Existing employee invitation functions and Auth redirect settings do not change. Actual media storage/upload and the Daily reader are later work.

## Local verification

`npm run test:daily`: 129 checks across all ten full-content imports, exact source/key fidelity, private reviewer separation, draft visibility, cross-store roles, department deduplication, date gates, forged/invalid payload rejection, answer feedback, unrestricted learning retries, same-key and competing-key concurrency, completion preservation, deactivation, activity bounds, immutable published content, identical/conflicting import reruns and a late-error rollback leaving no partial drafts. Includes one- and two-question modules and publication refusal when keys are missing.

`npm run test:database`: existing 346 SQL assertions and account/seat/quiz/competition/feed concurrency checks pass with migration 012 installed.

These tests use isolated local PostgreSQL, never hosted employees. Hosted application and website behavior remain unverified until owner execution and the later UI work.
