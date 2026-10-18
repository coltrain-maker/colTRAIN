# Import RF-101 as an unpublished draft

Use your existing **coltrain-development** Supabase project. No Netlify deployment, new Supabase project, secret key, or rerun of earlier setup queries is needed.

1. Open `RF-101_IMPORT_DRAFT.sql` in this folder on GitHub. Use **Raw** to view the whole file and copy all of its text. Do not copy only the portion visible in a truncated preview.
2. In Supabase, open **SQL Editor**, then create a **new query**. Keep the normal `postgres` database role.
3. Paste the whole import and click **Run**. This inserts one draft course, five lessons, five questions, and five private answer keys. It creates no tables and removes no existing data.
4. The results should show `Your First Day in Hardware Retail`, `published = false`, `lessons = 5`, and `quiz_questions = 5`.
5. Sign into the current website as the colTRAIN administrator. Open **Course library** from the hamburger menu, refresh if needed, and select **Preview course** for RF-101. Read all five lessons. Employees and ordinary managers cannot see the draft.

The existing admin card may show **Make available to store** even for an unpublished draft. Do not click it yet: the server correctly rejects releasing an unpublished course. There is no draft-publication button in the current website.

The five practice questions are text with their explanations below. They do not collect responses or affect scoring. The final quiz remains scored. Course-specific completion copy and the provisional duration remain in our editorial reference; existing result screens use the platform's standard wording.

## Later, after reviewing the draft

Publishing and releasing are separate from importing. To publish the reviewed course, run this short query in a separate SQL Editor query:

```sql
update public.training_courses
set published = true
where id = '4c7cbaa4-ceb0-5b42-ae9e-692576e98585'
  and slug = 'rf-101-your-first-day-in-hardware-retail'
  and version = 1;

select title, published
from public.training_courses
where id = '4c7cbaa4-ceb0-5b42-ae9e-692576e98585';
```

Then, as administrator in the website, select **Make available to store** while viewing **Coltrain Hardware**. This adds it only to that store's library; it does not assign employees. The manager can then use **Assign training** to select a test employee and deadline.

Test lessons in order, quiz submission, saved points/trophy, and manager progress reporting. Local automated checks do not prove this hosted acceptance. The test account will earn real saved learning records in the pilot project.

## Safe reruns and changes

Running the identical import again validates content and adds nothing. It preserves later publication, assignments, completions, and awards. If the imported content differs, it stops with an error instead of overwriting it. Share the error text if this happens; do not delete existing rows or disable course protections.

Do not use the uploaded package's references to an older SQL script. This prepared import maps to the actual current colTRAIN tables and keeps final answers private. Keep course source files, answer keys, and import scripts out of public website uploads.
