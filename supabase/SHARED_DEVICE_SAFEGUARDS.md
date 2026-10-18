# Shared-device safeguards

This website update needs no SQL migration, Auth configuration, or Edge Function change. Upload the whole extracted `design/coltrain-website.zip` folder to the existing Netlify site's Deploys page, then refresh `/accounts/`.

## Behavior

- Shared-device protection is on by default. The sign-in form and **Account & team settings → This device** let someone change it for this browser. Personal-phone users may turn it off.
- After 14 minutes without clicks, typing, scrolling, or touches, a warning offers **Stay signed in** or **Sign out now**. At 15 minutes the account signs out. Watching video alone does not count as interaction.
- Saved training progress remains. Unsent posts/comments, selected photos, and unsubmitted quiz answers are cleared. The warning explains this before sign-out.
- **Sign out and switch accounts** is in the hamburger menu and on the standalone account page. It immediately removes private content, clears this tab's credentials and in-memory photo URLs, and opens a clean sign-in document. The next person uses their own email and password.
- Signing out also clears other open colTRAIN tabs in the same browser/origin. A sign-out stamp is checked when a suspended tab resumes. Different tabs' Supabase Auth broadcasts must not replace their individual signed-in identities.
- Reloading does not restart the inactivity allowance. Returning after device sleep or a hidden tab checks elapsed wall time before revealing shared-device content.

Only the device preference and a nonsecret sign-out stamp use localStorage. Auth tokens and activity timing remain in sessionStorage. No employee identity or password is stored in the sign-out stamp. Browser password managers are independent: do not save passwords on shared hardware. Disabling browser storage can prevent cross-tab signaling and persistence; each tab still clears its own screen when signed out.

This is browser inactivity protection, not a server-enforced idle-session policy. Server logout is best effort and cannot block local clearing when offline. An already-issued access token remains subject to its normal server expiry. Personal-device mode disables the inactivity timer, while manual account switching still clears the tab and signals other tabs.

## Pilot check after deployment

1. Sign in on a shared computer with the checkbox selected. Open the hamburger menu and verify **Sign out and switch accounts** returns to a blank sign-in form.
2. Sign in as a different test employee. Confirm the header, courses, profile, and Team Corner reflect that employee and no unsent draft remains from the previous person.
3. Leave a test account untouched for 14 minutes. Confirm the warning appears. Choose **Stay signed in**, then verify the account remains available.
4. Leave it untouched again and let the 15-minute limit expire. Confirm the sign-in screen appears and saved course progress returns after signing in again.
5. Open a second colTRAIN tab. Sign out in one tab and verify both return to sign-in.
6. On a personal phone, turn off shared-device protection under **This device**, save, and verify the checkbox remains off after refresh. Keep protection on for store computers and tablets.

Automated checks: `python tests/shared-device-ui.py` uses mocked Auth and simulated browser time to exercise warning/stay/expiry, draft and credential clearing, reload, sleep, personal settings, failed server logout, cross-tab identity and sign-out, and pending-request account switching. Existing account, training, and PWA suites cover integration separately. These checks do not replace the hosted pilot steps above.
