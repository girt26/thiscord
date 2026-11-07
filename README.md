# thiscord

Discord-like single-page webchat backed by Supabase.

## Supabase setup

1. Open the Supabase SQL editor for the project.
2. Run [`supabase/reset.sql`](supabase/reset.sql).
   - **Destructive:** it drops and recreates every chat table, so existing messages, profiles, and DMs are lost.
   - It creates the normalized tables, update triggers, indexes, RLS policies, Realtime publication, the `chat-images` storage bucket, and seed data.
3. Reload the app.

## How sync works

- Every message is its own row in `chat_messages` or `dm_messages`, so concurrent sends cannot overwrite each other.
- Supabase Realtime is the only live transport. The old ntfy/MQTT snapshot fallback was removed.
- Deletes are soft deletes (`deleted_at`), and `updated_at` is maintained by database triggers.
- Reconnects and a 60-second catch-up pass use `updated_at` to recover any missed events.
- Chat images live in Supabase Storage with a 10-day retention cleanup.
