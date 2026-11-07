-- ============================================================
-- THISCORD — DESTRUCTIVE RESET
-- ============================================================
-- WARNING: This drops every chat table and recreates the
-- database from scratch. All existing chat messages, profiles,
-- DM conversations, and DM messages will be lost.
--
-- Run this in the Supabase SQL editor as the project owner.
-- Take a backup first if you care about the old data:
--   pg_dump "$SUPABASE_DB_URL" > thiscord-backup.sql
-- ============================================================

begin;

-- ----------------------------
-- 1. Drop the old schema
-- ----------------------------
drop table if exists public.dm_messages cascade;
drop table if exists public.dm_conversation_members cascade;
drop table if exists public.dm_conversations cascade;
drop table if exists public.chat_comments cascade;
drop table if exists public.chat_meta cascade;
drop table if exists public.chat_messages cascade;
drop table if exists public.chat_channels cascade;
drop table if exists public.chat_profiles cascade;
drop table if exists public.chat_state cascade;

drop function if exists public.create_dm_conversation(text, text, text[]);
drop function if exists public.create_dm_conversation(text, text, text, text[]);
drop function if exists public.increment_counter(bigint);
-- set_updated_at() and touch_dm_conversation() are replaced below with
-- create or replace, so they are intentionally not dropped with CASCADE
-- (that could remove triggers on unrelated tables).

create extension if not exists pgcrypto;

-- ----------------------------
-- 2. Shared trigger function
-- ----------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := clock_timestamp();
    return new;
end;
$$;

-- ----------------------------
-- 3. Channels
-- ----------------------------
create table public.chat_channels (
    id          text primary key
                check (id ~ '^[a-z0-9][a-z0-9_-]{0,49}$'),
    position    integer not null default 0,
    created_by  text not null default 'system',
    created_at  timestamptz not null default now(),
    archived_at timestamptz,
    archived_by text
);

create index chat_channels_active_idx
    on public.chat_channels (position, created_at)
    where archived_at is null;

-- ----------------------------
-- 4. Profiles / directory
-- ----------------------------
create table public.chat_profiles (
    username_key text primary key,             -- normalized email
    email        text not null unique,
    username     text not null default '',
    email_pings  boolean not null default true,
    removed_at   timestamptz,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

create unique index chat_profiles_active_username_idx
    on public.chat_profiles (lower(username))
    where removed_at is null and username <> '';

create trigger chat_profiles_set_updated_at
before update on public.chat_profiles
for each row execute function public.set_updated_at();

-- ----------------------------
-- 5. Channel messages
-- ----------------------------
create table public.chat_messages (
    id                uuid primary key default gen_random_uuid(),
    channel_id        text not null references public.chat_channels(id) on delete cascade,
    sender_name       text not null,
    avatar_color      text not null default 'bg-indigo-600',
    badge             text not null default 'MEMBER',
    content           text not null default '',
    image_url         text,
    image_name        text,
    image_path        text,
    image_host        text,
    image_expires     bigint,
    image_thumb_url   text,
    image_thumb_path  text,
    image_bytes       integer,
    image_width       integer,
    image_height      integer,
    image_thumb_bytes integer,
    reply_to_id       uuid,
    reply_to_user     text,
    reply_to_content  text,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),
    edited_at         timestamptz,
    deleted_at        timestamptz,
    deleted_by        text,
    constraint chat_messages_content_or_image
        check (char_length(content) > 0 or image_url is not null)
);

create index chat_messages_channel_created_idx
    on public.chat_messages (channel_id, created_at desc)
    where deleted_at is null;

create index chat_messages_updated_idx
    on public.chat_messages (updated_at);

create trigger chat_messages_set_updated_at
before update on public.chat_messages
for each row execute function public.set_updated_at();

-- ----------------------------
-- 6. Small singleton metadata + comments
-- ----------------------------
create table public.chat_meta (
    id         smallint primary key default 1 check (id = 1),
    counter    bigint not null default 1337,
    updated_at timestamptz not null default now()
);

create trigger chat_meta_set_updated_at
before update on public.chat_meta
for each row execute function public.set_updated_at();

insert into public.chat_meta (id) values (1)
on conflict (id) do nothing;

create table public.chat_comments (
    id         uuid primary key default gen_random_uuid(),
    author     text not null,
    content    text not null check (char_length(content) between 1 and 2000),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz
);

create trigger chat_comments_set_updated_at
before update on public.chat_comments
for each row execute function public.set_updated_at();

-- ----------------------------
-- 7. Direct messages
-- ----------------------------
create table public.dm_conversations (
    id         uuid primary key default gen_random_uuid(),
    kind       text not null check (kind in ('direct', 'group')),
    name       text not null default '',
    created_by text not null,
    direct_key text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint dm_direct_key_required check (
        (kind = 'direct' and direct_key is not null) or
        (kind = 'group' and direct_key is null)
    )
);

create unique index dm_conversations_direct_key_idx
    on public.dm_conversations (direct_key)
    where direct_key is not null;

create trigger dm_conversations_set_updated_at
before update on public.dm_conversations
for each row execute function public.set_updated_at();

create table public.dm_conversation_members (
    conversation_id uuid not null references public.dm_conversations(id) on delete cascade,
    member_name     text not null,
    -- Case/space-insensitive identity for lookups, so a user can log in
    -- with different capitalization and still find their conversations.
    member_key      text generated always as (lower(btrim(member_name))) stored,
    joined_at       timestamptz not null default now(),
    last_read_at    timestamptz,
    primary key (conversation_id, member_key)
);

create index dm_conversation_members_key_idx
    on public.dm_conversation_members (member_key);

create table public.dm_messages (
    id                uuid primary key default gen_random_uuid(),
    conversation_id   uuid not null references public.dm_conversations(id) on delete cascade,
    sender_name       text not null,
    avatar_color      text not null default 'bg-indigo-600',
    badge             text not null default 'MEMBER',
    content           text not null default '',
    image_url         text,
    image_name        text,
    image_path        text,
    image_host        text,
    image_expires     bigint,
    image_thumb_url   text,
    image_thumb_path  text,
    image_bytes       integer,
    image_width       integer,
    image_height      integer,
    image_thumb_bytes integer,
    reply_to_id       uuid,
    reply_to_user     text,
    reply_to_content  text,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),
    edited_at         timestamptz,
    deleted_at        timestamptz,
    deleted_by        text,
    constraint dm_messages_content_or_image
        check (char_length(content) > 0 or image_url is not null)
);

create index dm_messages_conversation_created_idx
    on public.dm_messages (conversation_id, created_at desc)
    where deleted_at is null;

create index dm_messages_updated_idx
    on public.dm_messages (updated_at);

create trigger dm_messages_set_updated_at
before update on public.dm_messages
for each row execute function public.set_updated_at();

-- Keep the conversation's updated_at fresh when a message arrives.
create or replace function public.touch_dm_conversation()
returns trigger
language plpgsql
as $$
begin
    update public.dm_conversations
       set updated_at = clock_timestamp()
     where id = new.conversation_id;
    return new;
end;
$$;

create trigger dm_messages_touch_conversation
after insert on public.dm_messages
for each row execute function public.touch_dm_conversation();

-- ----------------------------
-- 8. Atomic DM creation
-- ----------------------------
create or replace function public.create_dm_conversation(
    p_kind       text,
    p_name       text,
    p_created_by text,
    p_members    text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id      uuid;
    v_key     text;
    v_members text[];
begin
    if p_kind not in ('direct', 'group') then
        raise exception 'invalid conversation kind';
    end if;

    -- Deduplicate case-insensitively while keeping the first spelling.
    select array_agg(trim(m) order by trim(m))
      into v_members
      from (
          select distinct on (lower(btrim(m))) btrim(m) as m
            from unnest(coalesce(p_members, array[]::text[])) as u(m)
           where btrim(m) <> ''
           order by lower(btrim(m)), btrim(m)
      ) deduped;

    if v_members is null or array_length(v_members, 1) < 2 then
        raise exception 'at least two members are required';
    end if;

    if p_kind = 'direct' and array_length(v_members, 1) <> 2 then
        raise exception 'direct conversations require exactly two members';
    end if;

    if p_kind = 'direct' then
        select string_agg(lower(m), '|' order by lower(m))
          into v_key
          from unnest(v_members) as u(m);

        -- Serialize creation of the same 1:1 conversation so two
        -- clients opening it at once cannot race the unique index.
        perform pg_advisory_xact_lock(hashtextextended(v_key, 0));

        select id into v_id
          from public.dm_conversations
         where direct_key = v_key
         limit 1;

        if v_id is not null then
            insert into public.dm_conversation_members (conversation_id, member_name)
            select v_id, m from unnest(v_members) as u(m)
            on conflict do nothing;
            return v_id;
        end if;
    end if;

    insert into public.dm_conversations (kind, name, created_by, direct_key)
    values (
        p_kind,
        coalesce(nullif(trim(p_name), ''), ''),
        coalesce(nullif(trim(p_created_by), ''), v_members[1]),
        v_key
    )
    returning id into v_id;

    insert into public.dm_conversation_members (conversation_id, member_name)
    select v_id, m from unnest(v_members) as u(m);

    return v_id;
end;
$$;

-- ----------------------------
-- 9. Counter helper (atomic)
-- ----------------------------
create or replace function public.increment_counter(p_delta bigint default 1)
returns bigint
language sql
security definer
set search_path = public
as $$
    update public.chat_meta
       set counter = counter + greatest(0, p_delta)
     where id = 1
    returning counter;
$$;

-- ----------------------------
-- 10. RLS
-- ----------------------------
-- The current app has no Supabase Auth identity. These policies
-- therefore keep the same open access the app had before. When
-- you add Supabase Auth, replace them with policies based on
-- auth.uid() and a profiles table.
alter table public.chat_channels           enable row level security;
alter table public.chat_profiles           enable row level security;
alter table public.chat_messages           enable row level security;
alter table public.chat_meta               enable row level security;
alter table public.chat_comments           enable row level security;
alter table public.dm_conversations        enable row level security;
alter table public.dm_conversation_members enable row level security;
alter table public.dm_messages             enable row level security;

do $$
declare
    t text;
begin
    foreach t in array array[
        'chat_channels',
        'chat_profiles',
        'chat_messages',
        'chat_meta',
        'chat_comments',
        'dm_conversations',
        'dm_conversation_members',
        'dm_messages'
    ] loop
        execute format('drop policy if exists "public read" on public.%I', t);
        execute format('drop policy if exists "public insert" on public.%I', t);
        execute format('drop policy if exists "public update" on public.%I', t);
        execute format('drop policy if exists "public delete" on public.%I', t);

        execute format(
            'create policy "public read" on public.%I for select to anon, authenticated using (true)', t
        );
        execute format(
            'create policy "public insert" on public.%I for insert to anon, authenticated with check (true)', t
        );
        execute format(
            'create policy "public update" on public.%I for update to anon, authenticated using (true) with check (true)', t
        );
        execute format(
            'create policy "public delete" on public.%I for delete to anon, authenticated using (true)', t
        );

        execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
    end loop;
end;
$$;

grant execute on function public.create_dm_conversation(text, text, text, text[]) to anon, authenticated;
grant execute on function public.increment_counter(bigint) to anon, authenticated;

-- ----------------------------
-- 11. Realtime publication
-- ----------------------------
do $$
declare
    t text;
begin
    if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        execute 'create publication supabase_realtime';
    end if;

    foreach t in array array[
        'chat_channels',
        'chat_profiles',
        'chat_messages',
        'chat_meta',
        'chat_comments',
        'dm_conversations',
        'dm_conversation_members',
        'dm_messages'
    ] loop
        if not exists (
            select 1
              from pg_publication_tables
             where pubname = 'supabase_realtime'
               and schemaname = 'public'
               and tablename = t
        ) then
            execute format('alter publication supabase_realtime add table public.%I', t);
        end if;
    end loop;
end;
$$;

-- ----------------------------
-- 12. Storage bucket for chat images
-- ----------------------------
-- Wrapped so a storage-permission hiccup cannot abort the whole reset.
do $$
begin
    insert into storage.buckets (id, name, public)
    values ('chat-images', 'chat-images', true)
    on conflict (id) do update set public = true;

    execute 'drop policy if exists "chat images public read"   on storage.objects';
    execute 'drop policy if exists "chat images public insert" on storage.objects';
    execute 'drop policy if exists "chat images public update" on storage.objects';
    execute 'drop policy if exists "chat images public delete" on storage.objects';

    execute $p$create policy "chat images public read"
        on storage.objects for select
        to anon, authenticated
        using (bucket_id = 'chat-images')$p$;

    execute $p$create policy "chat images public insert"
        on storage.objects for insert
        to anon, authenticated
        with check (bucket_id = 'chat-images')$p$;

    execute $p$create policy "chat images public update"
        on storage.objects for update
        to anon, authenticated
        using (bucket_id = 'chat-images')
        with check (bucket_id = 'chat-images')$p$;

    execute $p$create policy "chat images public delete"
        on storage.objects for delete
        to anon, authenticated
        using (bucket_id = 'chat-images')$p$;
exception
    when insufficient_privilege or undefined_table or undefined_object then
        raise notice 'Skipped storage bucket setup: %', sqlerrm;
end;
$$;

-- ----------------------------
-- 13. Seed
-- ----------------------------
insert into public.chat_channels (id, position, created_by)
values ('secret-lounge', 0, 'system')
on conflict (id) do nothing;

insert into public.chat_messages (
    id, channel_id, sender_name, avatar_color, badge, content, created_at
)
values (
    '00000000-0000-0000-0000-000000000001',
    'secret-lounge',
    'System',
    'bg-indigo-600',
    'BOT',
    'Welcome to the Secret Webchat! Chat is live and synced across visitors.',
    now()
)
on conflict (id) do nothing;

commit;
