# RF-101 — Your First Day in Hardware Retail

Prepared from the owner's ChatGPT package `colTRAIN_RF-101_Codex_Package_v1.1.zip`.
This is course data for the existing schema, not a new database migration or a website release.

## Contents and editorial decisions

- `source/`: the three uploaded files, retained unchanged, including source/permission notes, objectives, manager guidance, proposed completion message, and timing estimates.
- `approved-assessment.json`: the final quiz, with Q05 revised to assess **Acknowledge, Ask, Assist, and Close** directly. Correct option remains C; the explanation was revised to match. All other final questions are unchanged.
- `prepared-import.json`: generated database content with five full lessons and five final questions. Includes private quiz keys: do not upload this file or the source package as an employee download or public website asset.
- `../../supabase/course-imports/RF-101_IMPORT_DRAFT.sql`: generated, transactional import. Creates an unpublished global course with no store releases or assignments. It does not change tables, security policies, account records, scoring functions, or the original customer-service course.
- `../../supabase/course-imports/RF-101_REVIEW_AND_IMPORT.md`: owner instructions.

The lesson import uses the full Markdown document as its editorial source, including why-this-matters sections, store examples, suggested actions, mistakes, when to ask for help, and key takeaways. It does not silently drop those sections in favor of the shorter uploaded JSON. Existing heading/paragraph/bullet/callout blocks need no new browser functionality.

Each lesson's unscored check becomes a readable practice question followed by its answer and explanation. No response is collected, completion is not gated on a practice answer, and no points or attempts are consumed. Answers are visible by scrolling; there is no interactive reveal. Final-quiz answers remain exclusively in the private answer-key table. Interactive practice checks are deferred.

Optional photo/video placeholders and the repeated “no workplace activity required” sections are omitted from the employee lesson body. They remain in the original source. No media assets were supplied; this import is text only. Real media requires supported rendering/storage work before adding it. No attendance reactions or faith-based store content are included.

The four-part customer-interaction sequence is assessed by revised final Q05. The current final questions have some obviously incorrect distractors; they are suitable for introductory checks but can be made more challenging in a future reviewed version.

## Metadata and versioning

Database UUID: `4c7cbaa4-ceb0-5b42-ae9e-692576e98585`.
Slug: `rf-101-your-first-day-in-hardware-retail`. Category: Retail Foundations.
Source version: **1.1.0**. Database revision: **1** (the existing schema uses a positive integer, not a semantic version string). Deterministic UUID mappings in the builder keep retries stable. Future changed content needs a new database revision and IDs, particularly after assignments exist.

Level, learning path, language, provisional duration, source references, per-question objective links, proposed course completion message, and manager coaching guidance stay in the editorial archive. The current schema/screens have no dedicated fields for all of these. Do not claim those features are displayed or enforced. General audience and department suggestions do not create departments, placements, prerequisites, or automatic assignments.

The 25-minute estimate has not been employee-tested. No independent comparison with the cited NHPA guide was possible because that source was not included in the package; the source's reproduction/permission note remains an editorial review item.

## Rebuild and checks

Run `python scripts/build-rf101-import.py`, then `python tests/rf101-import.py` from `/workspace/colTRAIN`. The latter uses disposable pinned PostgreSQL, existing migrations, real RLS/RPCs, and no hosted credentials. It tests draft visibility, safe reruns/conflicts, no automatic release/assignment, existing-course preservation, cross-store isolation, private answers, lesson gating, one-time points, attempt limits, manager-assisted retry, passing boundaries, and trophy replay.

Do not put this import into `supabase/migrations` or the combined new-project setup: course catalog publication should remain an explicit administrator decision. No Netlify build or deployment is needed for the text-only lessons and final quiz.
