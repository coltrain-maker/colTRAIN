# RF-102–104: import three unpublished course drafts

Use the EXISTING coltrain-development Supabase project. Do not rerun SETUP.sql or prior migrations. No Netlify deployment, website rebuild, Auth change, or new project is needed.

## Import

1. Open `RF-102_103_104_IMPORT_DRAFTS.sql` in this folder on GitHub.
2. Click **Raw** and copy ALL the text. If GitHub shows a large-file preview message, use Raw rather than copying the shortened preview.
3. In Supabase, open **SQL Editor → New query**, leave the normal `postgres` role selected, paste the entire script, and click **Run**.
4. Expect three result rows, each with `published = false`, `lessons = 5`, and `quiz_questions = 5`:

| Course | Title |
| --- | --- |
| RF-102 | Retail Terms & Hardware Vocabulary |
| RF-103 | Store Safety Fundamentals |
| RF-104 | Understanding the Hardware Store |

The batch uses one transaction. If any course fails, all three new imports roll back. Share an error message rather than deleting data or disabling protections. An identical rerun validates content and adds nothing; changed existing content aborts instead of overwriting. Individual per-course import files are supplied for future selective use, but you only need the batch file now.

No course is published, released to a store, or assigned by this import. Existing RF-101, customer-service training, progress, awards, accounts, and policies stay intact.

## Review in the existing website

Sign in as the colTRAIN administrator, refresh, open **Course library** from the hamburger menu, and select **Preview course** for each draft. Ordinary managers and employees cannot see these unpublished drafts.

Read all five lessons in each. Unscored practice questions show their answer/explanation below, without collecting a response or consuming attempts. RF-104 intentionally uses short-answer practice; RF-102 and RF-103 have multiple-choice practice. Final quizzes all use four-choice questions and private answer keys.

Do not select **Make available to store** on a draft. The current website has no publish-draft button, and the server rejects releasing an unpublished course. Publishing can be handled in a separate, targeted SQL query after review, followed by the existing administrator store-release control and manager assignment screen. No publication query is bundled into the import.

## Editorial review items

- All three are text-only. Suggested photos in RF-103 and RF-104 have no supplied assets; placeholders are retained in the original documents, omitted from employee lesson bodies.
- All three rely on general introductory knowledge; no external reference documents were supplied. Store-specific vocabulary, procedures, service offerings, and software labels need confirmation. These are general courses; no actual store departments, employee placements, or service promises are created.
- RF-103 needs review of emergency response, evacuation/assembly arrangements, equipment authorization/training, and hazard/incident reporting before publication. It is introductory content, not a claim of verified regulatory compliance or a replacement for required equipment training. No independent safety-source verification has been performed.
- RF-103 Q05 calls a bending bracket a near miss; it can also be described as a hazardous condition. Reporting and protecting the area remain the correct response. Consider refining the terminology during editorial review; supplied wording is preserved.
- RF-104 Q03 tests physical stock verification. Its related lesson also covers merchandise flow; a future revision could test that flow more directly. The provided question is supported by the lesson and is retained.
- Some wrong answers are deliberately obvious. These quizzes suit introductory checks; review their difficulty for experienced staff before using them competitively.
- RF-102 recommends RF-101, but explicitly says it is not a technical prerequisite. No enforced prerequisite or automatic learning path is created.
- Duration estimates, objectives, sources, manager coaching notes, and suggested completion messages are kept in the source archives. Existing screens do not display every editorial field, and completion screens keep their standard wording.
- Courses retain the current 80% pass threshold, 10 points per correct final question once, three attempts before manager help, and one trophy on passing. No scoring changes were imported.

After review, publish/release only the desired courses and assign a test employee before broader rollout. Hosted acceptance is separate from the local automated checks.

## Developer reference

Source files are preserved unchanged under `courses/RF-102/source/`, `courses/RF-103/source/`, and `courses/RF-104/source/`. Each course has generated `prepared-import.json` and an `import-manifest.json` with source hash, version mapping, and pending review items. These include final answers and are not public website assets.

Rebuild with `python scripts/build-retail-foundations-import.py`. Existing RF-101's builder and IDs are unchanged. Each new source version 1.0.0 maps to database revision 1 with distinct deterministic UUIDs. Once assigned, use a new revision rather than rewriting existing content.

Tests reuse the parameterized training/import suite:

```sh
python tests/rf101-import.py RF-102 --batch
python tests/rf101-import.py RF-103
python tests/rf101-import.py RF-104
python tests/rf101-import.py
```

These use isolated PostgreSQL and actual RLS/RPCs. They do not contact hosted Supabase, send invitations, or deploy to Netlify.
