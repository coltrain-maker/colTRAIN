# Keep me signed in on this personal device

Prepared for owner publication. No Supabase configuration or database update is required.

## User experience

- Sign-in and **Account & team settings → This device** include **Keep me signed in on this personal device**. It is off by default for existing users and is separate from email/push permissions.
- Selecting it unchecks **This is a shared store device**. A successful sign-in can then be restored when this same browser/home-screen app is reopened. Existing signed-in users can enable it in settings without signing out.
- Checking shared-device mode unchecks the personal option. Saving removes persistent credentials, keeps the current session active, restores the existing 14-minute warning/15-minute inactivity sign-out, and turns off that browser's push subscription.
- Unchecking only Keep me signed in removes persistent credentials but keeps the current tab session and personal-device mode. Future reopening requires sign-in. Optional device notifications remain independent.
- Explicit Sign out and switch accounts clears session and matching persistent credentials, consent, profile-photo URLs and drafts, triggers device notification cleanup, and signs other open colTRAIN tabs out as before. Late Auth responses cannot write credentials after local sign-out.
- Supabase still controls session validity and refresh. Rejected/revoked refresh sessions return to sign-in and clear persistence. Active membership and server RLS are rechecked through existing workspace/learning APIs; saved authentication never restores removed store permissions.
- If persistent browser storage is unavailable, sign-in falls back to the current session and tells the user it could not save the login. Different tab accounts do not adopt or overwrite each other's identity during credential refresh.

## Storage and limits

Only the Supabase authentication session (access/refresh credentials and its user data) and callback verifier/user-cache keys can persist under the app's existing project-specific Auth storage key after explicit consent. Password form values are never saved by this feature. Auth credentials are also mirrored in tab sessionStorage for the existing session-only/mode-change behavior. Activity metadata remains tab-scoped. No course content, messages, answers, photos or drafts are added to persistent storage or CacheStorage.

The user chooses a personal browser/device; the app does not guess from phone detection. A home-screen install and Safari/Chrome can have different storage, so enable this from the colTRAIN icon/browser actually used. Clearing website data, private browsing, OS storage cleanup, Supabase expiry, password/security changes or revoked refresh credentials can still require signing in. This is remembered sign-in, not an indefinite-session guarantee or permission bypass.

## Publish and test

1. Download `design/coltrain-website.zip` from GitHub with Download raw file, unzip, and upload the whole extracted folder to the existing Netlify site's Deploys page. Wait for Published, refresh, and close/reopen home-screen installs. No SQL, keys, functions, schedules or Supabase Auth setting changes are needed.
2. On a personal phone, sign in with **Keep me signed in on this personal device** selected. If already signed in, enable it in Account & team settings and Save device setting.
3. Close colTRAIN completely, then reopen its home-screen icon. Confirm the same account and store return without a password prompt. Test after restarting the phone when convenient.
4. Sign out explicitly. Reopen and confirm a blank sign-in screen, with no restored login or private drafts. Confirm that device's notification subscription/badge is cleared as before.
5. On a shared test browser, leave shared-device mode on. The new personal checkbox should be off; confirm inactivity sign-out still works. Switching a remembered personal device to shared must remove its saved login.
6. Test with accounts you control. The existing removed-member test verifies remembered Auth cannot open a training dashboard after membership is removed; do not remove real staff merely to repeat this.

## Verification

- `node --test tests/personal-session.test.mjs`: explicit opt-in, reopening/refresh credential rotation, mode changes, sign-out clearing, blocked storage fallback, tab-identity isolation and remembered callback verifier support.
- `python tests/shared-device-ui.py`: actual bundled Supabase client with mocked Auth/backend HTTP, full browser-context restart from localStorage only, settings migration, switching shared mode, explicit sign-out/restart, successful/rejected refresh, removed-member workspace checks, original inactivity/warning/reload/sleep/cross-tab/draft/pending-response safeguards. No live credentials, account edits or emails.
- Existing PWA/notification checks preserve zero offline CacheStorage and separate notification permission/cleanup behavior. Physical phone restoration remains an owner acceptance check after publishing.
