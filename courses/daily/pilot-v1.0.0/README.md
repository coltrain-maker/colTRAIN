# colTRAIN Daily: approved 10-module pilot

The owner confirmed on October 19, 2026 that the text has been reviewed and approved, and that some assets such as images are missing. Approved text is retained unchanged in `source/`. Original source labels saying “Ready for review—not published” are preserved as supplied; the separate `handoff-manifest.json` records the owner's current text approval. This does not publish or assign content.

## Delivery check

Run `python scripts/validate-daily-pilot.py` from the repository root. All ten individual Markdown files match their JSON `complete_markdown` exactly; individual JSON matches the combined JSON; the combined Markdown contains all ten complete originals. All ten modules have one four-choice question with a matching key/explanation, one per approved academy, all Foundations. IDs CD-0001 through CD-0010 are retained. Package version 1.0.0 is distinct from module source versions 0.1.0 and 0.2.0; neither is silently changed.

There are no supplied media assets. The source authors explicitly describe the proposed visuals as optional and retain the necessary comparisons, labels and scenarios in readable text. All ten can therefore be used for a text-only pilot. The plumbing scenario describes a customer's photo; it does not require an image attachment to answer the question. Do not show broken-image placeholders or claim suggested media is included.

## Optional asset checklist

| Module | Approved title | Optional asset to supply later |
| --- | --- | --- |
| CD-0001 | Paint Sheen: Recognize the Finish | Finish comparison illustration or authorized sheen sample; appearance is illustrative, not an exact screen reference |
| CD-0002 | Name the Plumbing Connection | Four connection examples; show both ends and an exploded slip-joint example |
| CD-0003 | Amps, Volts, and Watts on a Label | Fictional label highlighting V, A and W, marked illustrative |
| CD-0004 | Read an HVAC Filter Size | Filter face/depth diagram distinguishing nominal and actual dimensions |
| CD-0005 | Match the Screwdriver to the Screw | Four recess/tip pairs; optional second image of Phillips tip sizes |
| CD-0006 | Drill or Impact Driver? | Independently photographed drill chuck and impact-driver hex holder |
| CD-0007 | Read a Fertilizer’s Three Numbers | Illustrative 10-10-10 label linked to guaranteed-analysis text |
| CD-0008 | Weatherstripping or Door Sweep? | Door diagram showing top/side weatherstripping and bottom sweep |
| CD-0009 | Spot a Trip Hazard in the Aisle | Illustration of packaging projecting into a walking path; do not stage a live hazard |
| CD-0010 | Write a Useful Shift Handoff | Readable five-field handoff card |

Use the full asset descriptions and accessibility text from each module's section 7 when producing assets. Confirm rights, correct technical geometry and final alt text before adding media. No assets were generated or fetched in this handoff. Source citations and their claimed check dates are preserved, not independently reverified here; text approval is accepted, without reopening editorial review.

## Catalog accounting

Ten approved Foundations modules: one per academy. Remaining planned work: 78 Foundations, 112 Application, 60 Expertise, or 250 modules total. Approval is a content-development count, not a published/available/completed count. Existing 25 full-course records and completion credit remain separate. Only CD-0009 explicitly names RF-103 as its related full course; preserve “None specified” elsewhere rather than inventing relationships.

## Next integration work

The existing app has no Daily database tables or Daily learner flow yet. These files are staged source, not an executable Supabase import. Do not run the full-course import scripts against this package or turn these modules into graded full-course records.

Build a separate Daily module/version model, store availability/assignment or scheduling, per-employee answers/completion, and private server-graded answer keys under existing organization permissions. Keep IDs stable, source text intact, and access separated by store. Render the teaching sections as safe Markdown (tables are needed), supply readable sources, and treat the quick check as structured assessment content rather than rendering it twice. Never expose `answer_key`, `complete_markdown`, combined source files or reviewer materials in the pre-answer learner payload. Explanations can be returned after submission.

A Daily reader, home entry, optional refresher/review, completion reporting and media support still need implementation. Scoring, retry and scheduling rules for Daily must be settled independently of full-course policies; earlier recommendations were not implemented by this upload. All Daily completion must remain separate from full-course credit.

No SQL was run against the hosted database. No website rebuild, Netlify deployment or changes to existing lessons, progress, points or trophies were made. Source/private answer files are outside the public hosting allowlist. Batch the eventual Daily feature release to conserve Netlify credits.
