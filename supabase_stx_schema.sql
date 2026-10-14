-- =====================================================================
-- STX (StudyTrack X) — RANCANGAN SUPABASE TAHAP A
-- Cakupan: akun + profil, verifikasi sekolah (untuk Peta SMKN 1 Ciamis),
--          cadangan data per akun, dan penyimpanan foto catatan.
--
-- STATUS: BELUM DIJALANKAN / BELUM DIUJI di Supabase.
-- CARA PAKAI YANG AMAN:
--   1. Buat proyek Supabase PERCOBAAN dulu, jalankan file ini di SQL Editor.
--   2. Uji dengan 2 akun (A dan B) sebelum dipakai di proyek sebenarnya.
--   3. JANGAN taruh service_role key di HTML/GitHub. Di HTML hanya boleh
--      URL proyek + anon/publishable key.
-- Semua tabel di bawah memakai Row Level Security (RLS).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. SEKOLAH
-- ---------------------------------------------------------------------
create table if not exists public.schools (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,               -- contoh: 'smkn1-ciamis'
  name        text not null,                      -- contoh: 'SMKN 1 Ciamis'
  jenjang     text not null check (jenjang in ('SD','SMP','SMK')),
  created_at  timestamptz not null default now()
);
alter table public.schools enable row level security;

drop policy if exists "schools_read_authenticated" on public.schools;
create policy "schools_read_authenticated" on public.schools
  for select to authenticated using (true);
-- Tidak ada policy insert/update/delete: sekolah hanya diubah lewat SQL Editor oleh pemilik proyek.

insert into public.schools (slug, name, jenjang)
values ('smkn1-ciamis', 'SMKN 1 Ciamis', 'SMK')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- 2. PROFIL (data yang diisi pengguna sendiri; BUKAN bukti verifikasi)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id                   uuid primary key references auth.users(id) on delete cascade,
  nama                 text not null default '',
  nama_samaran         text not null default '',
  jenjang              text check (jenjang in ('SD','SMP','SMK')),
  kelas                text not null default '',
  jurusan              text not null default '',
  sekolah_nama         text not null default '',   -- klaim pengguna, tidak otomatis terverifikasi
  organisasi           text not null default '',
  bio                  text not null default '' check (char_length(bio) <= 200),
  tempat_lahir         text not null default '',
  tanggal_lahir        date,
  jenis_kelamin        text not null default '',
  onboarding_complete  boolean not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select to authenticated using (id = auth.uid());

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Profil dibuat otomatis saat akun baru terdaftar.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, nama, nama_samaran)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nama', ''),
    coalesce(new.raw_user_meta_data->>'nama', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 3. VERIFIKASI SEKOLAH (inilah dasar pembatasan fitur Peta)
--    Pengguna TIDAK bisa menulis tabel ini langsung. Satu-satunya jalan
--    adalah fungsi redeem_school_code() dengan kode rahasia dari sekolah.
-- ---------------------------------------------------------------------
create table if not exists public.school_members (
  user_id      uuid not null references auth.users(id) on delete cascade,
  school_id    uuid not null references public.schools(id) on delete cascade,
  role         text not null default 'siswa' check (role in ('siswa','guru','admin')),
  verified_at  timestamptz not null default now(),
  primary key (user_id, school_id)
);
alter table public.school_members enable row level security;

drop policy if exists "members_select_own" on public.school_members;
create policy "members_select_own" on public.school_members
  for select to authenticated using (user_id = auth.uid());
-- Sengaja TIDAK ada policy insert/update/delete untuk pengguna.

create table if not exists public.school_codes (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  code_hash   text not null,                       -- sha256 dari kode (jangan simpan kode asli)
  role        text not null default 'siswa' check (role in ('siswa','guru','admin')),
  active      boolean not null default true,
  expires_at  timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.school_codes enable row level security;
-- Tanpa policy sama sekali: tabel ini tidak bisa dibaca/diubah dari aplikasi.

create table if not exists public.code_attempts (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
alter table public.code_attempts enable row level security;
-- Tanpa policy: hanya fungsi di bawah yang menulis/membaca.

-- Menukar kode sekolah. Dibatasi 10 percobaan per jam per akun.
create or replace function public.redeem_school_code(p_code text)
returns table (school_slug text, school_name text, member_role text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid   uuid := auth.uid();
  v_hash  text;
  v_code  public.school_codes%rowtype;
  v_school public.schools%rowtype;
begin
  if v_uid is null then
    raise exception 'Harus login terlebih dahulu' using errcode = '28000';
  end if;

  if (select count(*) from public.code_attempts
      where user_id = v_uid and attempted_at > now() - interval '1 hour') >= 10 then
    raise exception 'Terlalu banyak percobaan. Coba lagi satu jam lagi.' using errcode = '54000';
  end if;
  insert into public.code_attempts (user_id) values (v_uid);

  v_hash := encode(extensions.digest(convert_to(trim(coalesce(p_code,'')), 'UTF8'), 'sha256'), 'hex');

  select * into v_code from public.school_codes c
   where c.code_hash = v_hash and c.active
     and (c.expires_at is null or c.expires_at > now())
   limit 1;

  if not found then
    raise exception 'Kode sekolah tidak valid atau sudah kedaluwarsa' using errcode = 'P0001';
  end if;

  select * into v_school from public.schools s where s.id = v_code.school_id;

  insert into public.school_members (user_id, school_id, role)
  values (v_uid, v_code.school_id, v_code.role)
  on conflict (user_id, school_id) do nothing;

  return query select v_school.slug, v_school.name, v_code.role;
end;
$$;

revoke all on function public.redeem_school_code(text) from public, anon;
grant execute on function public.redeem_school_code(text) to authenticated;

-- Pemeriksaan keanggotaan, dipakai aplikasi dan (nanti) policy tabel Peta.
create or replace function public.is_verified_member(p_school_slug text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.school_members m
    join public.schools s on s.id = m.school_id
    where m.user_id = auth.uid() and s.slug = p_school_slug
  );
$$;

revoke all on function public.is_verified_member(text) from public, anon;
grant execute on function public.is_verified_member(text) to authenticated;

-- Contoh cara membuat kode sekolah (jalankan SENDIRI di SQL Editor, JANGAN simpan kodenya di GitHub):
--   insert into public.school_codes (school_id, code_hash, role, expires_at)
--   select id, encode(extensions.digest('GANTI-DENGAN-KODE-PANJANG-ACAK', 'sha256'), 'hex'), 'siswa',
--          now() + interval '1 year'
--   from public.schools where slug = 'smkn1-ciamis';
-- Gunakan kode acak minimal 12 karakter.

-- ---------------------------------------------------------------------
-- 4. CADANGAN DATA PER AKUN (menggantikan isi localStorage per jenjang)
--    Satu baris = satu snapshot data pribadi pengguna untuk satu jenjang.
-- ---------------------------------------------------------------------
create table if not exists public.user_state (
  user_id     uuid not null references auth.users(id) on delete cascade,
  scope       text not null check (scope in ('SD','SMP','SMK')),
  data        jsonb not null default '{}'::jsonb,
  version     integer not null default 1,
  updated_at  timestamptz not null default now(),
  primary key (user_id, scope),
  constraint user_state_size check (octet_length(data::text) < 4000000)
);
alter table public.user_state enable row level security;

drop policy if exists "state_select_own" on public.user_state;
create policy "state_select_own" on public.user_state
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "state_insert_own" on public.user_state;
create policy "state_insert_own" on public.user_state
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "state_update_own" on public.user_state;
create policy "state_update_own" on public.user_state
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "state_delete_own" on public.user_state;
create policy "state_delete_own" on public.user_state
  for delete to authenticated using (user_id = auth.uid());

drop trigger if exists user_state_touch on public.user_state;
create trigger user_state_touch before update on public.user_state
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 5. FOTO CATATAN (Storage, privat). Path file wajib diawali <user_id>/...
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('note-photos', 'note-photos', false)
on conflict (id) do nothing;

drop policy if exists "photos_select_own" on storage.objects;
create policy "photos_select_own" on storage.objects
  for select to authenticated
  using (bucket_id = 'note-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "photos_insert_own" on storage.objects;
create policy "photos_insert_own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'note-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "photos_update_own" on storage.objects;
create policy "photos_update_own" on storage.objects
  for update to authenticated
  using (bucket_id = 'note-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "photos_delete_own" on storage.objects;
create policy "photos_delete_own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'note-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- =====================================================================
-- CHECKLIST UJI (lakukan di proyek percobaan sebelum dipakai sungguhan)
--   [ ] Akun A tidak bisa membaca profiles/user_state/foto akun B.
--   [ ] Pengguna tidak bisa insert ke school_members (harus ditolak).
--   [ ] redeem_school_code dengan kode salah ditolak; kode benar sukses.
--   [ ] Percobaan ke-11 dalam 1 jam ditolak.
--   [ ] is_verified_member('smkn1-ciamis') = true hanya setelah redeem.
--   [ ] school_codes tidak bisa dibaca dari aplikasi (anon maupun authenticated).
-- =====================================================================
