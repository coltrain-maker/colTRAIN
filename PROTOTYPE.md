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
- Three ordered lessons, five quiz questions, 80% passing score, 10 points per newly correct answer, three total attempts, standard trophy, and manager-assisted retry unlock. The correct choices are C, False, A, C, True.
- Manager home is Dashboard, without a duplicate dashboard menu item. Columns: Employee, Course status, Current course, Competition points, Lifetime points.
- Assign training: choose one, several, or all employees or departments and set a due date. Choices save locally and send no notifications.
- Start competition: one form for name, required course, start date, end date, reward, and how to earn it. Only the sample course is available. Events are optional, manager-scheduled, and do not repeat weekly. Dates use Eastern Time in this preview.
- Separate Competitions page: current competition and illustrative history, completion percentages, combined learning time, and expandable employee details. Historical entries and time values are fictional. Scoring is a sample, not a production event-tracking system.
- Store leaderboard: Competition and Lifetime views.
- Team Corner: bold blue outlines for composer and pinned announcement; text/photo posts, likes, and comments with text, pictures, or both. Attach PNG, JPEG, or WebP pictures up to 1 MB and preview/remove before posting.
- Top-right hamburger navigation, manager/employee preview switch, and sample reset.

Production work still includes authentication, store isolation, actual assignments, question shuffling, persistent records, moderation, notifications/preferences, PWA installation, and database/file storage.

## Development

Build the standalone download with `python scripts/build-preview.py`.

To serve source files, run `python -m http.server 3000 --bind 0.0.0.0` from the project directory. The standalone file can also be opened directly without running this command.
