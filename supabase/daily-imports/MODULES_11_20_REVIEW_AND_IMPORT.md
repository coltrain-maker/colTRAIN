# Daily Drill modules 11–20: review and import

The uploaded package contains ten content-approved Foundations modules, one per academy. Original Markdown, JSON, aggregate files and reviewer notes are preserved under courses/daily/modules-11-20-v1.0.0/source. Nothing has been run in the hosted Supabase project.

| Sequence | ID | Title | Version |
|---|---|---|---|
| 11 | CD-0011 | Read a Paint Coverage Statement | 0.2.0 |
| 12 | CD-0012 | Supply Line or Drain Line? | 0.2.0 |
| 13 | CD-0013 | Lumens or Watts? | 0.1.0 |
| 14 | CD-0014 | Find the Filter’s Airflow Arrow | 0.1.0 |
| 15 | CD-0015 | Screw Length: Where Does Measurement Start? | 0.1.0 |
| 16 | CD-0016 | Match the Bit’s Shank to the Tool | 0.1.0 |
| 17 | CD-0017 | Annual or Perennial? | 0.1.0 |
| 18 | CD-0018 | Caulk or Construction Adhesive? | 0.1.0 |
| 19 | CD-0019 | Ask What the Customer Is Trying to Do | 0.1.0 |
| 20 | CD-0020 | Report a Shelf-Label Mismatch Clearly | 0.1.0 |

## Review findings

- Individual Markdown, individual JSON, combined Markdown/JSON and manifest agree exactly. Each module has one four-option question and a matching answer/explanation. No teaching, question wording, correct option or explanation was rewritten.
- No actual images or videos were supplied. The lessons are complete text-based modules; optional media suggestions and accessibility descriptions remain in private reviewer notes, not empty images in the app.
- Source links are embedded in section 7 of reviewer notes rather than a structured sources array. The importer extracts those supplied publisher/title/URL references for the learner Sources panel. CD-0019 and CD-0020 retain their original colTRAIN authorship statements instead of invented external citations. No source URL was independently rechecked during integration.
- The package records content approval and also retains technical/store review notes. Those notes remain intact in private editorial data. In particular, CD-0020 flags SKU/UPC terminology verification and the need for each store to identify who reviews price discrepancies; its teaching directs employees to involve the responsible person before changing prices or promising adjustments.
- The included catalog lists modules 1–20 for reference. This batch imports only CD-0011 through CD-0020. Existing modules 1–10, full courses, completions, deadlines, points and trophies are not overwritten.
- Foundation sequence positions 11–20 follow the current pilot. Conflicting occupied slots or altered content under an existing ID/version abort the whole import. Identical reruns are safe.

## 1. Import the drafts

In the existing Supabase project → SQL Editor → New query, paste all Raw contents of **MODULES_11_20_IMPORT_DRAFTS.sql** and Run. This requires the existing Daily sequence setup (migration 013), which is already part of the current build. Do not rerun migrations or SETUP.sql.

Expect **10 result rows**, CD-0011 through CD-0020, with **published = false** and **questions = 1**. This step adds drafts and private answer keys; it does not enroll anyone or award points.

## 2. Make the modules available to Coltrain Hardware

When ready to make these ten modules available, paste all Raw contents of **MODULES_11_20_RELEASE_COLTRAIN_HARDWARE.sql** into another new SQL Editor query and Run.

This verifies the configured administrator, exactly one Coltrain Hardware store, the first ten released Foundation slots, the approved versions and exact sequence positions. It publishes the new ten and releases them only to Coltrain Hardware. Active employees and managers are enrolled automatically; future active members also get the released sequence. No other store is enabled.

Expect **10 rows** with **published = true**, **available_to_coltrain_hardware = true**, and **active_members_enrolled** matching the active store-member count. Existing progress and assignment dates are preserved on rerun. Publishing/releasing alone never earns points.

## 3. Verify in colTRAIN

- Refresh the employee dashboard. Available Daily Drill assignments should now total 20. The planned overall pathway stays 260 (88 Foundations, 112 Application, 60 Expertise); available content and completed counts remain distinct.
- An employee who has not completed the first ten keeps their existing next drill. Someone who has finished module 10 should see module 11 next. Later drills stay sequentially locked.
- Open module 11, confirm the full teaching and Sources panel, complete its check, and verify 5 Daily Drill points are added once. Daily completion does not complete a full course or issue another full-course trophy.
- Review completed drills as before. No Netlify upload, website deployment, new secrets or Edge Function changes are needed for this content-only import.

## Local validation

`python scripts/build-daily-next-import.py` validates the uploaded source/metadata/quiz/answer fidelity and regenerates the prepared payload, draft SQL and store release SQL. `python tests/daily-next-import.py` runs the latest migrations in isolated PostgreSQL and verifies the exact import, safe reruns/conflicts, private keys, store-only release, automatic enrollment, retained progress/points, sequence 10→11 and future employees. No hosted data or real email/push is used.
