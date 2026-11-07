# thiscord

Discord-like webchat

## How sync works

- Every message is its own row in `chat_messages` or `dm_messages`, so concurrent sends cannot overwrite each other.
- Deletes are soft deletes (`deleted_at`), and `updated_at` is maintained by database triggers.
- Reconnects and a 60-second catch-up pass use `updated_at` to recover any missed events.
- Chat images live in Supabase Storage with a 10-day retention cleanup.
