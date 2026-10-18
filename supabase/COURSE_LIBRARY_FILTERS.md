# Course library: skill level, topic, learning path, keywords

Prepared for the next website release. No hosted deployment has been performed.

## Approved direction

`courses/THREE_LEVEL_LEARNING_FRAMEWORK.md` preserves the owner's framework. `courses/approved-launch-catalog.json` preserves the approved eight academies, 25 course codes/titles, and six learning paths. All launch courses are **Level 1 — Foundations**. **Level 2 — Application** and **Level 3 — Expertise** are future expansions. These are course classifications, not employee roles or permission groups.

The library now combines four optional filters:

- **Skill level:** all levels, Foundations, Application, Expertise.
- **Topic or academy:** the existing course category/academy plus specific topic tags.
- **Learning path:** paths represented by courses visible in this store's library.
- **Search courses:** words in course names, descriptions, codes/slugs, academy, level, topic tags, keywords, or path names. Multiple words must all match, ignoring case and common accent differences. It does not search video transcripts or every lesson paragraph.

Choose any combination and select **Search**. **Clear filters** restores the whole visible library. Filters survive navigation within the signed-in training session, clear when changing stores or signing out, and display a result count and useful no-match message. Course cards show their skill level. The form stacks on phones.

Topic/path options are derived only from the server-authorized workspace. Employees and managers cannot discover unreleased store courses through tags, options, or results. Admins retain their existing preview access. No browser filter grants course access, assignment, points, prerequisite exemptions, or quiz access.

Learning paths are browsing labels here. A course appearing in several paths retains its one existing course/assignment/credit record. Department Specialist lists eligible department courses; managers still select the relevant 2–4 courses for that specialization. Department Lead/Supervisor currently maps only the three explicitly approved core BL courses; its optional department-course mapping was not specified and is not guessed. No path-level completion badges or automatic path assignments are implemented. Placement assessments and lesson bypass remain future work.

## Existing pilot: when ready to release

You can keep developing courses without uploading to Netlify. The filter interface becomes visible only after the later website deployment.

1. In the EXISTING Supabase project's **SQL Editor → New query**, paste and run ONLY `supabase/migrations/202610180011_course_catalog.sql` once. Do not rerun earlier migrations or `SETUP.sql`. This adds classification metadata and extends the existing workspace response. It does not edit assigned graded content, publish drafts, release courses, assign employees, or reset awards.
2. The migration works with the currently deployed website: older code ignores the extra metadata. It labels existing courses Foundations and tags the supplied RF courses when present.
3. When the Netlify allowance permits a release, download and unzip `design/coltrain-website.zip`, then upload the WHOLE extracted folder to the existing site's Deploys page. This is the normal combined release; no Edge Function or Auth change is needed.
4. Refresh the website, sign in, open **Course library**, choose a level/topic/path and keywords, then select **Search**. Try `RF-102` or `UPC` if that course has been imported and is visible to this account. Test Clear filters, no matches, and a phone-width screen.
5. Repeat as manager and employee. Ordinary staff should see only the store's available/assigned courses. Application/Expertise correctly return no results until real courses at those levels are published and released.

Current RF-101–104 import scripts remain unpublished and keep the same content IDs. They now attach catalog tags/path metadata when migration 011 exists; they also work before 011. If those courses were imported first, migration 011 backfills their metadata. An identical course import rerun still preserves assigned content/progress and existing admin catalog edits. You do not need to reimport already loaded courses just to add this classification.

## Course development handoff

Continue supplying complete Markdown, matching full-content JSON, and README files. Include **skill level**, **academy**, **topics**, **search keywords**, **prior knowledge**, and **related-course progression**, plus approved learning-path membership where defined. Classification changes do not renumber existing courses or silently create prerequisite gates. Prior-knowledge/progression text remains editorial reference until specific display/enforcement features are implemented.

The full approved catalog is a development reference, not 25 fake lesson records. Only courses with prepared content are imported. The existing `customer-trust` sample is retained separately; it is not silently renamed or given an approved CS code.

## Technical notes and validation

`training_course_catalog` holds level/code/topic/keyword/path metadata with RLS based on the existing course visibility function. Browser roles have SELECT only. For now, classification edits are controlled SQL/import operations; no new catalog editor is implied. This separate table leaves assigned-course immutability and answer-key privacy intact.

`get_training_workspace` wraps the existing function through `private.training_workspace_before_catalog` and enriches only the already-authorized course rows. All earlier avatar, competition, reporting, and account boundaries remain in the call chain. Courses imported by an older script without metadata fall back to Foundations for launch compatibility; future Application/Expertise imports must explicitly set their catalog metadata before release.

Checks: `node --test tests/course-library.test.mjs`, `npm run test:database`, `python tests/training-ui.py`, and the course import tests. Browser tests cover combined filters, keywords, course codes, retained selections, Clear filters, no matches, role-specific hidden options, and phone layout against local SQL/RLS. These do not prove hosted acceptance or deploy the website.
