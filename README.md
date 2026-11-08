# thiscord

Discord-like webchat built on a single `index.html` + Supabase (Postgres, Auth, Realtime, Storage).

The public site is a decoy "study portal" (Seneca pages). Enter the secret gate code and you get a Discord-style chat: anonymous join, public channels, direct messages (group + 1:1), images, presence, mention notifications and an admin console.

## Identity model (hybrid tiers)

| Tier | Who | What they can do |
|---|---|---|
| Anonymous | Any visitor — `signInAnonymously()`, no email | Post/read in public channels, upload images, join presence via display name |
| Verified | Same account after adding an email via the identity menu (`updateUser({ email })` — confirmation link; `auth.uid()` is preserved) | Everything above **plus direct messages** |
| Admin | A verified account with `app_metadata.role = 'admin'` in the dashboard | Create/delete channels, delete messages, members console |

Key properties:

- Every visitor gets a **real `auth.uid()`**: joining signs them in anonymously. All writes are RLS-evaluated against that identity.
- **Messages cannot be spoofed.** `chat_messages.sender_id` / `dm_messages.sender_id` are `NOT NULL` FKs to `auth.users`, and a `BEFORE` trigger (`handle_message_identity`) stamps the row server-side: whatever the client sends for `sender_name`, `avatar_color` or `badge` is overwritten to match the auth identity.
- Display identity is server-stamped too: `profiles.is_anonymous` is filled by a trigger from `auth.users.is_anonymous` — the client can't fake a verification tier.
- **DMs require a non-impersonable identity**: an anonymous JWT claim (`is_anonymous`) blocks `create_dm_conversation()`, and conversation membership + reads are on UUIDs (`dm_conversation_members.member_id`), never display names. Two users with the same display name are two different DM identities.
- The "onering" passkey is a **UI-only gate** for the members console; every admin action is enforced by backend RLS (`is_admin()` reads `auth.users.raw_app_meta_data` first, the JWT claim second). A user who knows the passkey still has no backend power without the dashboard-assigned role.
- Emails are never stored in any table the client reads (`chat_profiles` directory table was dropped).

## Storage

- `chat-images` bucket is **private**; images are served through short-lived signed URLs (30 min) and refreshed for active members.
- Path scheme enforced by storage policies: channels `<uid>/<file>`, DMs `dm-<conversation_id>/<uid>/<file>` (RLS checks real DM membership on the conversation id).
- The client re-signs URLs nearing expiry. Server-side retention is flagged as a TODO — use Supabase's built-in storage object lifecycle or a `pg_cron` job to prune old objects.

## Setup

1. Supabase project — run the SQL in `supabase/migrations/` (each file is ordered like `20261107120000_...sql`) in the Supabase SQL editor.
2. **Dashboard → Authentication → Providers → enable "Anonymous sign-ins"** — required before any user can join.
3. Email verification links require Auth config (SMTP / template) in the dashboard.
4. Make yourself admin (in the SQL editor):
   ```sql
   update auth.users
      set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'
    where email = 'you@example.com';
   ```
   Then sign out in the app and sign in again so the JWT picks up the claim (or wait for token refresh).
5. Put your project URL + anon key in the config block at the top of `index.html`'s script.

The site is a static single-file page hosted on GitHub Pages. No package install or build step is needed.

## How sync works

- Every message is its own row in `chat_messages` or `dm_messages`, so concurrent sends cannot overwrite each other.
- Deletes are soft deletes (`deleted_at`), and `updated_at` is maintained by database triggers.
- Reconnects and a 60-second catch-up pass use `updated_at` to recover any missed events.
- Presence/typing ride the Realtime presence channel (ephemeral, display names — not identity).
- "X entered #channel" system notices are local-only echoes, not database rows.
