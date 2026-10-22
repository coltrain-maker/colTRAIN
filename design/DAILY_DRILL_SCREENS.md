# The Daily Drill: employee screens

**Points update:** The current employee portal adds a Daily Drill points total to this card, 5-point completion feedback, and separate course/Daily/lifetime totals. See [deployment instructions](../supabase/EMPLOYEE_PORTAL_UPDATE.md) for migrations 015–016 and first-login alerts.


The owner named the feature **The Daily Drill** and asked for it on the employee dashboard. The interface uses the approved text-only pilot; no source text, module IDs, versions, SQL or scoring rules were changed for this screen work.

## Prepared behavior

- Dashboard card sits below current competition and before normal full-course progress. Shows the next available drill, academy, level, estimated time, and completed counts alongside actual published, sequenced drills released to the store. Managers also have their own card because the shared path includes every active member; team Daily reporting is not introduced here.
- Start/Continue opens a readable lesson with safe Markdown tables, emphasis and lists, plus a collapsible Sources section. No missing-image placeholders. Full approved teaching sections are displayed; reviewer material and keys are not downloaded with the lesson.
- Quick check uses the server-provided question/options with required radio groups. It submits no score, completion flag or client-provided correctness. The server enforces sequence and grades the answer.
- Wrong-answer feedback explains the answer and links back to the lesson or a fresh retry. Feedback persists on the server: after a page reload, the dashboard Continue button recovers it.
- Successful completion is saved separately from full courses and unlocks the next drill. A lost response can be retried with the same submission UUID, recovering the original result without creating an extra attempt. Retaking an incorrect check intentionally creates a new key.
- Completed drills can be reviewed without new graded attempts or extra awards. The final pilot drill returns to a caught-up dashboard; it does not imply all 260 modules are finished or issue a badge.
- Correct level order is Foundations, Application, Expertise. Employee cards show available counts that update as content is released; the 88/112/60 planning totals remain in the admin library plan. The employee screen does not provide a menu to bypass locked modules.
- Activity heartbeat runs only in the open reader/check, while visible and recently active. Hidden, idle, history and feedback screens pause it; resuming resets the server baseline before counting more time. Leaving the training controller/signing out clears intervals, listeners, lesson/answer data and pending-state references. Stale responses from another store are ignored.
- A Daily backend error shows an isolated retry card; it does not prevent the normal course dashboard from rendering. Client errors do not disclose raw SQL in the card.

## Local checks

`node --test tests/daily-drill.test.mjs`: safe Markdown rendering/escaping, rejected executable/image links, stale-store response cleanup, empty-state handling and visible/idle activity lifecycle.

`python tests/daily-ui.py`: real local PostgreSQL migrations/imports/RLS plus Chromium, with Auth HTTP mocked. Covers dashboard placement/title, complete text/tables/source links, required answers, wrong feedback, lesson review, reload recovery, committed-success/lost-response replay, next-module unlock, completed review, phone overflow/layout, caught-up state, personal manager progress and sign-out/account switching. Source pilot drafts are published/released only in disposable local PostgreSQL fixtures.

`python tests/training-ui.py`: existing full-course, competition, Team Corner, avatar, account/menu and mobile regressions.

`python tests/pwa-ui.py`: public package allowlist, manifest, icons, service worker and offline behavior. The package must exclude SQL/source/private answer files.

## Review screenshots

- `daily-drill-dashboard.png`
- `daily-drill-dashboard-mobile.png`
- `daily-drill-lesson.png`
- `daily-drill-lesson-mobile.png`
- `daily-drill-result.png`

Screenshots use sample test identities and isolated test records. They are review artifacts, not screenshots of the live store.

## Publication state

Prepared for a later combined `coltrain-website.zip` upload. No Netlify deployment, hosted database writes, module publication/release or real employee notifications were performed. The live website remains unchanged.

The owner confirmed migration 013 succeeded. No additional Supabase migration is needed for these screens. The ten hosted modules remain drafts unless the owner has separately published/released them; the future website shows the empty card until ready content is released. Draft review/release controls and manager team Daily reporting remain separate next steps. Existing points/trophies and future final-badge issuance are unchanged.

The owner approved showing actual available/completed counts during the pilot, retaining the 260-item plan in the admin view. Adding/releasing real sequenced modules updates available counts automatically; it does not change the approved sequence limits or final-badge requirements. Available means released to the store, not unlocked out of sequence.
