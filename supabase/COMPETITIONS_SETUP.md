# Step 4a: competitions and review challenges

Prepared on `codex/coltrain-prototype`. Local database and browser verification is separate from applying the SQL and publishing to Netlify. Team Corner remains the next part of Step 4.

## Agreed behavior

A manager starts a competition as needed: name, one released course, start/end dates, reward, team or individual reward rule, and one/some/all active employees or departments. Targets are combined and deduplicated; managers are not automatically participants. The first version allows one running competition per store, with nonoverlapping future schedules. Dates use the store's saved time zone and include the entire end date, including daylight-saving changes. Competitions never repeat automatically.

**Only one set of course lessons and quiz questions needs to be authored.** Every participant takes a separate competition knowledge check using that course's questions. Existing graduates may review lessons and take the challenge immediately. New learners pass the original course first and then take the same challenge. This gives both groups the same scoring opportunity. There is no separate review course to maintain and no second trophy for reviewing.

Challenge points are separate from lifetime points. Each correct answer is worth 10 competition points, and the best single submitted challenge score counts, rather than adding attempts together. The sample has five questions, so the maximum is 50. Every participant starts with three total challenge attempts. Managers can record assistance and unlock one additional challenge attempt after those are used. These limits are separate from the original course's attempts, including previously granted supported retries. Replaying a submitted request does not consume another attempt; simultaneous submissions cannot exceed the limit. There are no speed bonuses.

Course points still follow the original once-per-person/question rule, and course trophies remain once per person/course. The challenge cannot write either. The manager dashboard uses the agreed columns: Employee, Course status, Current course, Competition points, Lifetime points. Standings use only employees from the selected store; tied scores share rank. Individual reward results name all tied top scorers, and zero points do not declare a winner. Managers provide the reward themselves; there is no charge or admin fulfillment workflow.

A team reward requires every remaining participant to pass both the course and challenge by the closing cutoff. Previously earned course credit counts, but previous competitions' challenge scores do not. The challenge uses the course's passing threshold (80% for the sample). Starting a competition explicitly assigns the course to selected employees who lack an assignment, using the competition end date as their deadline. Existing assignments retain their deadlines, attempts, progress, and completion. No assignments or competitions are created by the migration itself.

Employees who leave before the competition ends are marked no longer participating, excluded from rank and the team-goal denominator, and retain visible historical scores. Their replacement does not inherit participation or points. Leaving after the event ends does not change its historical outcome. The selected cohort is fixed on creation. Future competitions can be canceled; running competitions can be ended early with confirmation. The history remains, and closing prevents further submissions. Courses remain accessible independently of the competition.

Employees see the current competition first on Home, with their training below. Everyone has store leaderboard Competition/Lifetime tabs, personal milestone progress, and a Competitions page with current, scheduled, and past events. Managers additionally see completion percentages, per-participant completion/time, and aggregate store learning time. The displayed completion percentage measures the selected cohort's course-plus-challenge completion, not employees outside the competition.

## Learning-time estimates

Visible assigned lesson and quiz/challenge screens send heartbeats every 15 seconds while recently used. Timing pauses outside those screens, when opening the menu, in background tabs, and after 90 seconds without interaction. The server credits at most 20 seconds per interval and discards idle gaps longer than 45 seconds. A per-user server session prevents multiple tabs from counting the same elapsed time twice. There is no historical backfill, and delivery interruptions may undercount time. These are engagement estimates, not payroll records. Time never affects rankings or rewards.

Time is stored privately. Managers/admins receive their authorized store's aggregates; employees do not see colleagues' time. Individual challenge answer reviews are returned only to the submitting learner. Managers can see challenge scores/attempt counts and offer assistance, without reading those selections or explanations. Original training first-attempt question alerts continue to use original course quizzes; review challenges do not inflate those alerts.

## 1. Apply the incremental SQL

The existing project already has migrations through `202610170005_training.sql`. In Supabase **SQL Editor → New query**, paste the complete contents of:

`supabase/migrations/202610170006_competitions.sql`

Run it **once**. Expected result: **Success. No rows returned**. The migration is transactional. It adds competitions, private challenge scoring/time records, access rules, and extends the training workspace report. It preserves accounts, seats, invitations, original training history, points, and trophies. It moves the old report function into the private schema and wraps it, rather than deleting training records.

Do not rerun `SETUP.sql`, the new-project text file, or earlier migrations on this existing project. All new tables explicitly enable RLS and revoke browser writes; private tables have no browser read grants. If Supabase shows its generic query warning, the source contains those access rules. If any unexpected error appears, retain the exact error before retrying; a successful run must not be run a second time.

## 2. Publish the website update

After SQL succeeds:

1. Download `design/coltrain-website.zip` from this development branch using GitHub's **Download raw file**.
2. Extract it. The folder contains `index.html`, `accounts/`, and `preview/`.
3. Open the existing Netlify project **stalwart-custard-7be489 → Deploys** and upload that extracted folder in the manual deployment area. Keep the current project and URL.
4. Refresh `https://stalwart-custard-7be489.netlify.app/accounts/` and sign in normally. Downloaded HTML files do not update themselves.

No Edge Function, SMTP, callback URL, or secret change is needed. The ZIP contains exactly three public HTML files, with the application code embedded; SQL and server credentials are excluded. `/preview/` remains sample data.

## 3. Verify with controlled accounts

1. As manager, **Dashboard → hamburger menu → Competitions → Start competition**. Choose the released sample, today's start, a later end, and a reward. Uncheck **All active employees**, then select one controlled employee who already passed. Submit.
2. Sign in as that employee. Confirm the competition appears above training. Choose **Review lessons** for an optional refresher or **Take competition quiz** to begin directly. The refresher page also links directly to the competition quiz; lesson completion, original attempts, lifetime points, and trophy stay saved. Answer and submit the competition quiz. See standings, switch to Lifetime, refresh, and confirm scores persist separately.
3. Repeat with a lower challenge score; the competition best must stay unchanged. Original course attempts, lifetime points, completion, and trophy must stay saved. Three submissions use all available challenge attempts; further submissions are blocked until manager assistance.
4. As manager, confirm the competition and lifetime dashboard columns, the separate report's completion/time, and a supported challenge retry with an assistance note.
5. End the test competition using **End competition now** and its confirmation. Confirm it moves to Past competitions with saved scores and rejects new submissions. An employee already active in another store must not be able to read it.
6. A subsequent competition may use the same course: graduates receive a fresh challenge allowance with zero new-competition points. Prior history stays saved. Newly hired employees must pass the original course before taking the challenge.

Start with controlled accounts; inviting all nine employees is part of later pilot acceptance. External employee access without the founder's Netlify account, hosted tenant isolation, and full-capacity seat checks remain live pilot checks. No local test sends hosted email or edits the hosted database.

## Local evidence

`npm run test:database` exercises actual PostgreSQL security and scoring, including review challenges for graduates, original-record preservation, best scores, replay, attempt limits, assisted retry, ties/team goals, time bounds/privacy, store separation, date cutoffs, daylight-saving schedules, cancellation, and concurrent challenge submissions.

`python tests/training-ui.py` exercises the browser against actual local SQL/RLS with mocked Auth: complete original training; start a competition for that graduate; submit three challenges; compare competition/lifetime standings; manager unlock/report; close into history; and mobile layout. The test uses no hosted passwords or emails. Existing account UI and invitation-handler tests remain applicable.

## Optional refresher shortcut

The owner verified the live competition quiz flow and matching separate totals. A website-only follow-up adds **Review lessons** beside **Take competition quiz** for graduates on the Home competition card and standings. The refresher shows the existing course lessons with a direct route back to the competition quiz. It does not repeat completion writes or consume attempts. After exhausting challenge attempts, reviewing remains available while the quiz follows the existing manager-assisted unlock rule. Deploy the latest ZIP to the same Netlify site; do not rerun SQL or change the Edge Function.

## Direct home and shared navigation

A website-only update opens active employees directly on Home and managers/admins directly on the Dashboard after login, refresh, or invitation acceptance. **Open training** has been removed. The same top-right hamburger remains available on Account & team settings, including profile preferences, invitations, courses, and Sign out. Employees without an active store membership still receive the join/account setup screen instead of a training dashboard.

The top bar shows the selected store and **Signed in as [name] · [role]** on desktop and phones. Profile updates refresh the name, and signing out clears the previous identity. Administrators retain the selected store when returning from settings. Deploy the current website ZIP to the existing Netlify project; no SQL, Edge Function, or credential changes are needed. Local browser tests cover manager/employee direct entry, returning through settings, profile updates, sign-out/account switching, and visible mobile identity.
