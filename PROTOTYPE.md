# colTRAIN design preview

This prototype restores the agreed screen designs and interactions from our conversation. It uses fictional employees and browser-local storage. It is not connected to Supabase, email, billing, real accounts, or an actual training-time service. Do not enter real employee information.

## Keep a copy on your computer

1. Download `design/coltrain-prototype-restored.html`.
2. Save it in a permanent folder such as Documents/colTRAIN.
3. Open that file with Chrome, Edge, or Safari. No server, Internet connection, or installation is required.
4. Keep the backup ZIP in the same folder. Extract it if you ever need another copy.

Your prototype interactions are stored in the browser. Clearing browser storage, changing browsers, or moving the file may reset that sample activity. The HTML file itself contains the screens and sample content, not your later browser activity. Save future updated prototypes as new downloads; a saved file does not update automatically.

## Screens and interactions

- Employee home: optional current competition, lifetime points, ordered course progress above the Customer Service course, and Team Corner link. No eyebrow headings or at-a-glance card.
- Course library appears directly below My training in both employee and manager menus. My training shows assigned learning; Course library shows the store's available catalog. The sample library has search, category/department/completion filters, clear filters, an empty state, course descriptions, audience requirements, durations, points, and live completion status. Employees start, continue, or review courses; managers can also assign a course through the existing employee/department selector. Only the shared Customer Service course is currently available. Catalog filtering is illustrative; production authorization must be enforced by the backend.
- Three ordered lessons, five quiz questions, 80% passing score, 10 points per newly correct answer, three total attempts, standard trophy, and manager-assisted retry unlock. The correct choices are C, False, A, C, True.
- Manager home is Dashboard, without a duplicate dashboard menu item. Columns: Employee, Course status, Current course, Competition points, Lifetime points.
- Assign training: choose one, several, or all employees or departments and set a due date. Choices save locally and send no notifications.
- Start competition: one form for name, required course, start date, end date, reward, and how to earn it. Only the sample course is available. Events are optional, manager-scheduled, and do not repeat weekly. Dates use Eastern Time in this preview.
- Separate Competitions page: current competition and illustrative history, completion percentages, combined learning time, and expandable employee details. Historical entries and time values are fictional. Scoring is a sample, not a production event-tracking system.
- Store leaderboard: Competition and Lifetime views.
- Team Corner: bold blue outlines for composer and pinned announcement; text/photo posts, likes, and comments with text, pictures, or both. Attach PNG, JPEG, or WebP pictures up to 1 MB and preview/remove before posting.
- Top-right hamburger navigation, manager/employee preview switch, and sample reset.

Production work still includes authentication, store isolation, actual assignments, question shuffling, persistent records, moderation, notifications/preferences, PWA installation, and database/file storage.

Step 2 now has a separate account foundation under `accounts/` and database migrations under `supabase/`. See `SUPABASE_SETUP.md` for project connection, migration, and live-verification steps. The design preview remains sample-only; preparing the account foundation does not mean the hosted database has been migrated or connected.

## Development

Edit `templates/index.html`, `styles.css`, and `app.js`, then run `python scripts/build-preview.py`. This generates a self-contained root `index.html` and the standalone downloads from the same source. Do not edit the generated HTML directly.

The root index includes its styling and JavaScript so the chat's single-file preview can render the cards and interactions without loading sibling files. The root index and downloadable prototype have identical contents.

To serve source files, run `python -m http.server 3000 --bind 0.0.0.0` from the project directory. The standalone file can also be opened directly without running this command.

## Connected training workspace

Step 3 now adds `accounts/training.js` and `accounts/training.css`, bundled with the real-account page. After the incremental training migration and a website redeployment, signing in opens the employee Home or manager Dashboard directly, connecting the course/quiz/results screens to real records. The top-right hamburger also includes account/team settings, and the header identifies the selected store and signed-in person. See `supabase/TRAINING_SETUP.md` for activation and test evidence. The deployed root redirects to `/accounts/`; the unchanged sample prototype is packaged separately at `/preview/`. The sample preview remains separate. Step 4a now connects real competitions; Team Corner remains the next implementation slice.
