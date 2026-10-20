# Website navigation and course selection update

Owner-approved changes:

- Clicking outside the hamburger drawer closes it. Clicking inside keeps it open; Escape also closes it and returns focus to the menu button.
- The logo tagline reads exactly “Knowledge is our power tool” in the connected account site and separate sample preview. Existing lesson text and footer copy are unchanged.
- Course library, Assign training, and Start competition use Academy → Subtopic → Course selectors. The library retains skill-level, learning-path and keyword filters plus Search/Clear controls.

Academies and subtopics come only from courses this account can already access. Manager assignment/competition selectors use released store courses only. Subtopics use existing course topic tags; duplicate academy/category labels are removed and untagged courses use General. No course names, content, classifications or permissions are rewritten, and no new subtopic catalog is invented. Future tags can refine the choices as content grows.

Changing a parent narrows the next choices and clears incompatible child selections. Course filters update within their form, preserving names, dates, rewards, employee/department selections and other entered fields. Changing the competition course refreshes its course-specific participant list using existing competition behavior. Library results still apply when Search is selected.

No Supabase migration or data import is required. Prepared in the cumulative `design/coltrain-website.zip`; not deployed by Codex. Use one whole-folder upload to the existing Netlify site, refresh, then check menu dismissal, tagline, and all three selector flows on desktop and phone.
