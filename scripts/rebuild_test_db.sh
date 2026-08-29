#!/usr/bin/env bash
# Reconstruye una base local (magui_test) desde cero aplicando todas las
# migraciones en orden, con un stub mínimo del esquema auth de Supabase.
# Uso interno de desarrollo/CI local — NO se usa en producción.
set -euo pipefail

DB=${1:-magui_test}

sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null
sudo -u postgres psql -c "CREATE DATABASE ${DB};" >/dev/null
sudo -u postgres psql -d "${DB}" -v ON_ERROR_STOP=1 <<'EOSQL'
create schema if not exists auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

-- Stub mínimo de storage.buckets/storage.objects (lo justo para que las
-- migraciones de fotos de producto corran acá) — la implementación real de
-- Supabase Storage es mucho más completa, esto es solo para no romper
-- rebuild_test_db.sh con las políticas de storage.objects.
create schema if not exists storage;
create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  owner uuid,
  created_at timestamptz not null default now()
);
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated, anon;
grant select, insert, update, delete on storage.objects to authenticated, anon;
grant select on storage.buckets to authenticated, anon;
do $$
begin
  if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end
$$;
EOSQL

cd "$(dirname "$0")/../supabase/migrations"
for f in $(ls *.sql | sort); do
  sudo -u postgres psql -d "${DB}" -v ON_ERROR_STOP=1 -f "$f" > /tmp/rebuild_mig.log 2>&1
  if [ $? -ne 0 ]; then
    echo "FAILED at $f"
    tail -50 /tmp/rebuild_mig.log
    exit 1
  fi
done
echo "OK: ${DB} rebuilt from $(ls *.sql | wc -l) migrations"
