-- Tildi Life – Supabase Schema (Mehrbenutzer, RLS-abgesichert)
-- Ausführen im Supabase Dashboard: SQL Editor -> New query -> einfügen -> Run
-- Sicher erneut ausführbar (idempotent) dank IF NOT EXISTS / CREATE OR REPLACE.
--
-- Wichtig: die Fachdaten-Tabellen (termine, medikamente, ...) nutzen `id text`
-- statt `uuid`, weil der bestehende Client seine IDs selbst erzeugt (uid() in
-- index.html, z.B. "xlm3k2j9abcde") statt echte UUIDs zu verwenden. `ts`
-- (Millisekunden-Timestamp) wird 1:1 aus dem Client übernommen, damit die
-- bestehende Merge-Logik (neuester ts gewinnt) unverändert weiterfunktioniert.

create extension if not exists pgcrypto;

-- ============================================================
-- KINDER (Betreuungsperson) & ZUGRIFF (Mehrbenutzer mit Rollen)
-- ============================================================

create table if not exists public.children (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  diagnose text,
  photo_url text,
  created_by uuid not null references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  invited_email text,
  role text not null check (role in ('elternteil','betreuer_einrichtung','betreuer_privat','arzt')),
  status text not null default 'active' check (status in ('pending','active')),
  created_at timestamptz not null default now(),
  unique (child_id, user_id)
);
create index if not exists memberships_invited_email_idx on public.memberships (lower(invited_email));

-- Helper-Funktionen (SECURITY DEFINER = umgehen RLS bewusst, nur für diese gezielten Checks)
create or replace function public.is_child_member(p_child_id uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (
    select 1 from public.memberships
    where child_id = p_child_id and user_id = auth.uid() and status = 'active'
  );
$$;

create or replace function public.is_child_admin(p_child_id uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (
    select 1 from public.memberships
    where child_id = p_child_id and user_id = auth.uid()
      and role = 'elternteil' and status = 'active'
  );
$$;

-- Neues Kind anlegen -> Ersteller automatisch als Elternteil eintragen
create or replace function public.handle_new_child()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.memberships (child_id, user_id, role, status)
  values (new.id, new.created_by, 'elternteil', 'active');
  return new;
end;
$$;
drop trigger if exists on_child_created on public.children;
create trigger on_child_created after insert on public.children
  for each row execute function public.handle_new_child();

alter table public.children enable row level security;
alter table public.memberships enable row level security;

drop policy if exists children_select on public.children;
create policy children_select on public.children for select
  using (is_child_member(id));
drop policy if exists children_insert on public.children;
create policy children_insert on public.children for insert
  with check (created_by = auth.uid());
drop policy if exists children_update on public.children;
create policy children_update on public.children for update
  using (is_child_member(id));

drop policy if exists memberships_select on public.memberships;
create policy memberships_select on public.memberships for select
  using (
    user_id = auth.uid()
    or lower(invited_email) = lower(auth.jwt()->>'email')
    or is_child_member(child_id)
  );
drop policy if exists memberships_insert on public.memberships;
create policy memberships_insert on public.memberships for insert
  with check (is_child_admin(child_id));
drop policy if exists memberships_claim_update on public.memberships;
create policy memberships_claim_update on public.memberships for update
  using (
    (status = 'pending' and lower(invited_email) = lower(auth.jwt()->>'email'))
    or is_child_admin(child_id)
  )
  with check (
    (status = 'active' and user_id = auth.uid())
    or is_child_admin(child_id)
  );
drop policy if exists memberships_delete on public.memberships;
create policy memberships_delete on public.memberships for delete
  using (is_child_admin(child_id));

-- ============================================================
-- GEMEINSAM GENUTZTE PFLEGE-DATEN
-- Alle Tabellen folgen demselben Muster: id (client-generiert) + ts
-- + child_id + Fachfelder + created_by/by_name (Anzeigename)
-- + optional soft delete (deleted)
-- ============================================================

create table if not exists public.termine (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  titel text not null,
  datum date,
  uhrzeit text,
  ort text,
  kat text,
  erinnerung text,
  notiz text,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.medikamente (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  name text not null,
  dosis text,
  freq text,
  hinweis text,
  exp text,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.medikamenten_log (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  med_id text references public.medikamente(id) on delete set null,
  action text not null,
  datum date,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.anfaelle (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  zeit text,
  dauer text,
  intensitaet text,
  typ text,
  ausloeser text,
  buccolam text,
  notiz text,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tagebuch (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  mood text,
  aktivitaeten text,
  notiz text,
  an text,
  typ text,
  entry_typ text,
  datum date,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.kontakte (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  name text not null,
  rolle text,
  tel text,
  adresse text,
  notiz text,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.hilfsmittel (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  name text not null,
  status text,
  datum date,
  notiz text,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.dokumente (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  name text not null,
  datum date,
  typ text,
  notiz text,
  has_photo boolean not null default false,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.rezepte (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  name text not null,
  typ text,
  datum date,
  ablauf date,
  notiz text,
  has_photo boolean not null default false,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mahlzeiten (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  datum date,
  icon text,
  name text,
  amount text,
  aufnahme text,
  schluck text,
  notiz text,
  created_by uuid references auth.users(id) default auth.uid(),
  by_name text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.wasser (
  child_id uuid not null references public.children(id) on delete cascade,
  datum date not null,
  count int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (child_id, datum)
);

create table if not exists public.todos (
  id text primary key,
  ts bigint not null default 0,
  child_id uuid not null references public.children(id) on delete cascade,
  text text not null,
  prio text,
  kat text,
  by_name text,
  done boolean not null default false,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- RLS für alle Fachdaten-Tabellen: jedes aktive Mitglied darf lesen/schreiben
do $$
declare t text;
begin
  for t in select unnest(array[
    'termine','medikamente','medikamenten_log','anfaelle','tagebuch',
    'kontakte','hilfsmittel','dokumente','rezepte','mahlzeiten','wasser','todos'
  ])
  loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('drop policy if exists %I_all on public.%I;', t, t);
    execute format(
      'create policy %I_all on public.%I for all using (is_child_member(child_id)) with check (is_child_member(child_id));',
      t, t
    );
  end loop;
end $$;

-- updated_at automatisch pflegen
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare t text;
begin
  for t in select unnest(array[
    'termine','medikamente','anfaelle','tagebuch',
    'kontakte','hilfsmittel','dokumente','rezepte','mahlzeiten','todos'
  ])
  loop
    execute format('drop trigger if exists set_updated_at on public.%I;', t);
    execute format(
      'create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at();',
      t
    );
  end loop;
end $$;
