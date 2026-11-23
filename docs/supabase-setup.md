# BMS Carrom — Supabase setup (v7, accounts + friends + invites)

The game code (v7) talks to Supabase for accounts, friend search and
invites. The Supabase project itself must be created in the browser —
the agent cannot do this step (it needs a Supabase dashboard login).
**No card is needed at any step.** If any step asks for a card, stop.

## 1. Create the project (free tier)

1. Go to https://supabase.com/ and click **Start your project** (or
   Sign in if there is already an account).
2. Sign up / sign in with **bmsirimanna@gmail.com** (Google sign-in
   works, or email + password).
3. **New project** → name it `bms-carrom` → set a database password
   (write it down — it is only for the database, the game never needs
   it) → region **Singapore** (closest; Mumbai is the fallback) →
   **Create new project**. The free plan is the default — do NOT pick
   a paid plan.
4. Wait for the project to finish provisioning (a minute or two).

## 2. Run the schema

1. In the dashboard, open the **SQL Editor** (left sidebar).
2. Open `supabase/schema.sql` from this repo, copy its whole contents,
   paste them into a **New query**, and click **Run**.
3. It must report success (tables `profiles` + `invites`, function
   `search_players`, RLS policies, Realtime on `invites`). If an error
   mentions `auth.users`, the project is still provisioning — wait a
   minute and run it again.

## 3. Turn on the Auth methods the game uses

1. **Authentication → Providers → Email**: make sure Email is
   **enabled** (it is on by default). This is what sends the 6-digit
   login code to the player's Gmail. Leave "Confirm email" at its
   default — the game uses OTP sign-in, which is self-confirming.
   NOTE (v10, 2026-11-23): the default "Magic Link" email template
   contains ONLY a sign-in link and NO 6-digit code — but the game's
   OTP screen asks the player to type a 6-digit code, so players
   never see one. Edit **Authentication → Email Templates → Magic
   Link** and show the code big and clear alongside the link (the
   template variable is `{{.Token}}`; the link is
   `{{.ConfirmationURL}}`). Until then the code path still works —
   the player taps the link instead — but the code itself is
   invisible.
2. **Authentication → Providers → Anonymous sign-ins**: OPTIONAL —
   leave it off. The game signs players in with their Gmail (OTP
   code) or Google, which IS the account; anonymous sign-in is not
   part of registration.
3. **Authentication → URL Configuration → Redirect URLs**: add
   `http://127.0.0.1:8765/callback` (the game's Google sign-in
   loopback address — the game listens on the phone itself for the
   reply, nothing leaves the device) AND
   `com.musehiro.carrom://auth-callback` (the custom-scheme deep
   link the browser returns to after Google sign-in — Android routes
   it back into the game; see `android/build/AndroidManifest.xml`).
   NOTE (v10, 2026-11-23): the LOOPBACK is now the game's primary
   return (it needs no native code, so it works in the CI-built APK);
   the custom scheme is secondary (file poll) until the export
   workflow is fixed to install the Android build template. Both
   must stay listed — the OTP magic link uses the loopback too.
4. (Optional, for one-tap Google sign-in) **Authentication →
   Providers → Google**: enable it with a Google OAuth client — create
   the client in Google Cloud Console (console.cloud.google.com →
   APIs & Services → Credentials → Create Credentials → OAuth client
   ID → **Web application** — NOT Android: an Android client has no
   client secret and Supabase cannot use it; no card needed there
   either). In the Web client, add this Authorized redirect URI:
   `https://<your-project-ref>.supabase.co/auth/v1/callback`
   (for this project:
   `https://hyhlhngybzwnungnshff.supabase.co/auth/v1/callback`).
   Then paste the client ID + client secret into Supabase. Without
   this step the game's "Continue with Google" button falls back to
   the Gmail + code flow, which works fully on its own.
   NOTE (2026-11-22): the Google consent screen starts in Testing
   mode — only Gmail addresses added as test users can sign in with
   Google until the consent screen is published to Production, which
   needs a homepage URL + a privacy-policy URL. That is a later step;
   the Gmail + code flow works for every player meanwhile.

## 4. Copy the keys into the game

1. **Settings → API**: copy the **Project URL**
   (looks like `https://abcdefghijklm.supabase.co`) and the **anon
   `public` key** (a long `eyJ…` token). The anon key is public-safe —
   row-level security protects the data, and the game never ships the
   `service_role` key. **Never copy the service_role key anywhere.**
2. Open `backend_config.json` in the repo and fill in
   `supabase_url` + `supabase_anon_key`. See
   `backend_config.example.json` for the shape. (`google_client_id`
   is NOT needed — the OAuth client lives server-side in Supabase;
   the game never uses a client-side client ID.)
3. Push that one-file change — the next build (v7.1) activates cloud
   accounts, friend search and invites. Nothing else in the code
   changes: the game already contains the full client.

## 5. Check it works

1. Install the new build, register with a name + Gmail, and watch the
   profile appear in the dashboard under **Table Editor → profiles**.
2. On a second phone, register a different name, search for the first
   name in FRIENDS, send an invite — it must arrive in the first
   phone's invite box within seconds (Realtime), and accepting must
   start a match (needs the game server up — AWS — or NEARBY).

## If anything asks for a card

Stop. Supabase's free tier needs no card, Google Cloud's OAuth client
needs no card, and the game needs neither. Report the exact step that
asked, and do not enter card details.

## What the game stores (privacy)

- Profiles: display name, Gmail (login + restore only, never shown to
  other players), coins, XP, match stats, owned boards/strikers.
- Friend search finds players by **display name only** — Gmail is
  never searchable or visible to other players.
- Invites: sender/recipient ids + names, mode (2p/4p), stake, status.
  No chat, no messages, no other personal data.
