# Daily shared learning path: automatic enrollment and sequence

**Later update:** [Employee portal update](EMPLOYEE_PORTAL_UPDATE.md) adds 5 Daily Drill points per first correct completion, including past completions, through migration 016. The no-awards statements below describe migration 013 by itself; the final Expertise badge remains future work.


Owner-approved direction, October 19, 2026: every active store member receives Daily training regardless of role, job or department. Everyone progresses through Foundations, Application, then Expertise. A final badge is planned for completing the Expertise stage and all earlier required training. This replaces the earlier manager-selected Daily assignment/date design.

## Apply to the existing pilot

1. If not already done, finish `202610190012_daily.sql` and `daily-imports/PILOT_10_IMPORT_DRAFTS.sql` using `DAILY_SETUP.md`. The import should show 10 unpublished modules, each with one question.
2. In the same Supabase project open **SQL Editor → New query**.
3. Open `supabase/migrations/202610190013_daily_sequence.sql` on GitHub, click **Raw**, copy the entire file and paste it into the new query.
4. Select **Run**. Expected **Success. No rows returned**. Apply migration 013 only once. Do not rerun migration 012 or SETUP.sql. An identical pilot-import rerun remains safe but is not necessary.
5. Leave modules as drafts until the Daily screens are ready. No website upload is required for this database step. Current full-course screens, course assignments and awards are unaffected.

If there is an error, stop and share the exact message. No privileged key, SMTP change or Edge Function deployment is needed.

The supported normal order is 012 → pilot import → 013. Fresh projects can install all schema migrations first and then import the pilot; the importer now adds the same ten sequence slots when 013 is already present.

## Rules

- The shared path contains 88 Foundations positions, followed by 112 Application positions and 60 Expertise positions. These are planned module counts, not 260 existing lesson records. Academy boundaries do not branch or exempt learners from the shared path.
- The ten approved pilot modules occupy Foundations positions 1–10, CD-0001 through CD-0010. Newly authored content is assigned a deliberate position in its level before release. No missing lesson content or placeholder modules are generated.
- Employees can open the next incomplete module only after all earlier planned positions are complete. Missing, unpublished or unreleased prerequisites cannot be skipped. After finishing the current ten-module pilot, the learner waits for Foundations position 11; they cannot advance to Application before all 88 Foundations positions are complete.
- There is no forced calendar day or minimum lesson time. The learner can proceed to the next available module after passing the current one; daily pacing and reminders are later interface choices. Wrong answers still return feedback and permit learning retries.
- Admin still publishes and releases modules to selected stores. Release now automatically enrolls every active member of that store, including managers. Manager job roles and department memberships do not filter Daily training. Publication without store release creates no employee assignments.
- Joining/reactivating a store automatically creates missing Daily assignments for all its released, sequenced modules. A replacement employee starts with their own records. Role/department changes never grant completion or exemptions.
- Existing completions and retries are preserved. Already-completed modules remain available for review. Deactivation removes learner access while retaining historical records for authorized management.
- Sequence slots with assignments cannot be moved, removed or replaced. New content versions do not silently replace assigned versions. A future curriculum/version rollout needs a deliberate migration that preserves completed work.
- A repeated release or automatic enrollment cannot duplicate assignments or reset progress. Removing store availability still preserves existing assignments, matching earlier retention behavior.
- Managers retain store-wide progress visibility and full-course assignment controls. The old `assign_daily_module` RPC now refuses manual department/date assignments; Daily has automatic enrollment instead.

## Badge preparation

The workspace returns `pathway_complete` and `badge_eligible` only when that learner has completed all 88 Foundations, 112 Application and 60 Expertise positions. Finishing the ten pilot modules does not satisfy the final badge. `badge_issued` remains false: no badge artwork, award record, Daily points or trophies are issued by this migration. Those are explicitly later awards work. These flags use server-side completion records, not browser claims.

## Integration contract

`public.daily_sequence` stores module IDs, level and level-specific position, with SELECT-only RLS and unique positions. Module code/version and approved source content stay unchanged.

Admin RPC `set_daily_sequence(module uuid, slot integer)` sets a module's position before store release. Positions are limited to the approved level totals. Browser clients cannot directly edit the sequence. Future imports must set their sequence position deliberately before release. Private helpers perform enrollment and progression checks and are not callable by clients.

Existing `get_daily_module`, `submit_daily_check` and direct learner table policies use the updated prerequisite check, so opening/submitting a later assignment by guessing its ID is refused. `get_daily_workspace` preserves all earlier store/role boundaries and adds sequence fields, per-assignment `can_open`, and a caller-specific `progression` summary with next assignment and level completion totals. Managers can still preview released store content for oversight; their own graded Daily progression remains ordered.

`get_daily_workspace` returns a null next assignment when the learner has caught up but required content is missing. The future UI should show “You’re caught up. More training is on the way,” rather than imply the 260-module path is finished. It should show actual approved/available/completed counts separately from the planned 260 positions.

## Verification

`python tests/daily-sequence.py` passed 47 checks covering automatic enrollment across roles, no-department employees, new hires/reactivation, inactive/other-store exclusion, safe upgrade from 012, direct table/RPC skip prevention, missing-content and level prerequisites, completed review, immutable assigned positions, concurrency and all-260 badge readiness. Large curriculum fixtures exist only inside isolated test PostgreSQL; no production placeholders are created.

`python tests/daily-sequence.py --fresh` passed 3 additional checks for schema-before-import installation. The original migration-012 suite passed 129 checks. The existing database suite passed 346 SQL assertions plus its concurrency checks with migration 013 installed.

`npm run test:daily` also retains the migration-012 foundation regression suite, followed by the current sequence suite. `npm run test:database` verifies the existing account/course/competition/feed behavior with all latest migrations installed. No tests deploy to Supabase or Netlify.
