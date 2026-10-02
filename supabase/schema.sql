-- Présences danse : schéma Supabase
-- À coller dans Supabase > SQL Editor > New query, puis Run.
-- Heures en minutes depuis minuit : 540 = 9h00, 900 = 15h00.

-- 1. Tables ---------------------------------------------------------------

create table public.members (
  name     text primary key,
  position int  not null default 0
);

create table public.absences (
  id        bigint generated always as identity primary key,
  member    text not null references public.members(name)
              on update cascade on delete cascade,
  day       date not null,
  start_min int  not null check (start_min >= 540 and start_min < 900),
  end_min   int  not null check (end_min > 540 and end_min <= 900),
  check (end_min > start_min)
);
create index absences_day_idx on public.absences(day);

-- Journal en ajout seul : jamais modifié ni supprimé par le site.
create table public.absence_history (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  member     text not null,
  day        date not null,
  action     text not null check (action in ('add', 'remove', 'clear')),
  start_min  int,
  end_min    int
);

-- 2. Membres (ordre alphabétique) ---------------------------------------------

insert into public.members (name, position) values
  ('Alexandra', 1), ('Aneko', 2), ('Elsa', 3), ('Ilho', 4), ('Inês', 5),
  ('Lisa', 6), ('Lisandra', 7), ('Neila', 8), ('Noémy', 9), ('Rafi', 10),
  ('Salomé', 11), ('Thalia', 12), ('Yann', 13), ('Yuno', 14), ('Zeynep', 15);

-- 3. Accès : lecture pour tous, écriture uniquement via les fonctions ----------

alter table public.members         enable row level security;
alter table public.absences        enable row level security;
alter table public.absence_history enable row level security;

create policy "lecture membres"    on public.members         for select to anon using (true);
create policy "lecture absences"   on public.absences        for select to anon using (true);
create policy "lecture historique" on public.absence_history for select to anon using (true);

grant select on public.members, public.absences, public.absence_history to anon;

-- 4. Fonctions d'écriture -----------------------------------------------------

-- Ajoute une absence et fusionne les plages qui se chevauchent ou se touchent.
create or replace function public.add_absence(
  p_member text, p_day date, p_start int, p_end int
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_start int := p_start;
  v_end   int := p_end;
begin
  if not exists (select 1 from members where name = p_member) then
    raise exception 'Membre inconnu';
  end if;
  if extract(dow from p_day) <> 0 then
    raise exception 'Ce jour n''est pas un dimanche';
  end if;
  if p_start < 540 or p_end > 900 or p_end <= p_start then
    raise exception 'Plage horaire invalide';
  end if;

  select least(v_start, min(start_min)), greatest(v_end, max(end_min))
    into v_start, v_end
    from absences
   where member = p_member and day = p_day
     and start_min <= p_end and end_min >= p_start;

  delete from absences
   where member = p_member and day = p_day
     and start_min <= p_end and end_min >= p_start;

  insert into absences (member, day, start_min, end_min)
  values (p_member, p_day, v_start, v_end);

  insert into absence_history (member, day, action, start_min, end_min)
  values (p_member, p_day, 'add', p_start, p_end);
end $$;

-- Retire une plage précise.
create or replace function public.remove_absence(p_id bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r absences%rowtype;
begin
  delete from absences where id = p_id returning * into r;
  if found then
    insert into absence_history (member, day, action, start_min, end_min)
    values (r.member, r.day, 'remove', r.start_min, r.end_min);
  end if;
end $$;

-- Remet un membre disponible pour tout un dimanche.
create or replace function public.clear_absences(p_member text, p_day date)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from absences where member = p_member and day = p_day) then
    delete from absences where member = p_member and day = p_day;
    insert into absence_history (member, day, action)
    values (p_member, p_day, 'clear');
  end if;
end $$;

revoke all on function public.add_absence(text, date, int, int) from public;
revoke all on function public.remove_absence(bigint)            from public;
revoke all on function public.clear_absences(text, date)        from public;
grant execute on function public.add_absence(text, date, int, int) to anon;
grant execute on function public.remove_absence(bigint)            to anon;
grant execute on function public.clear_absences(text, date)        to anon;

-- 5. Test rapide (facultatif) -------------------------------------------------
-- select add_absence('Yann', '2026-10-04', 660, 780);
-- select add_absence('Yann', '2026-10-04', 780, 840);   -- fusionne : 11:00-14:00
-- select * from absences;
-- select * from absence_history;
-- Nettoyage :
-- select clear_absences('Yann', '2026-10-04');
-- delete from absence_history;
