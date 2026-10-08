-- Mise à jour du 2026-10-08 : corbeille admin (30 jours) + suppression de boutique.
-- À exécuter UNE fois dans Supabase > SQL Editor (inutile si schema.sql a été installé après cette date).
-- Ne touche pas aux données existantes.

alter table public.stores add column if not exists deleted_at timestamptz;

create or replace function public.guard_stores()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.id is distinct from old.id
       or new.owner_id is distinct from old.owner_id
       or new.status is distinct from old.status
       or new.suspension_reason is distinct from old.suspension_reason
       or new.deleted_at is distinct from old.deleted_at
       or new.slug is distinct from old.slug
       or new.created_at is distinct from old.created_at then
      raise exception 'FORBIDDEN_FIELD' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop function if exists public.admin_list_clients(text, text, int, int);
create or replace function public.admin_list_clients(
  p_search text default null, p_status text default null,
  p_limit int default 25, p_offset int default 0, p_include_admins boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_search text := nullif(trim(p_search), '');
  v_result jsonb;
begin
  perform public.assert_admin();
  with rows as (
    select
      p.id as user_id, p.first_name, p.last_name, p.email, p.phone, p.whatsapp,
      p.city, p.country, p.created_at,
      s.id as store_id, s.name as store_name, s.business_type, s.slug,
      s.suspension_reason,
      pl.id as plan_id, pl.name as plan_name,
      sub.start_date, sub.end_date,
      case when sub.end_date is null then null else sub.end_date - public.app_today() end as days_left,
      public.store_state(s.id) as state
    from public.profiles p
    join public.stores s on s.owner_id = p.id
    left join public.subscriptions sub on sub.store_id = s.id
    left join public.plans pl on pl.id = sub.plan_id
    where (p.role = 'client' or p_include_admins)
      and s.deleted_at is null
      and (v_search is null
           or p.first_name ilike '%' || v_search || '%'
           or p.last_name  ilike '%' || v_search || '%'
           or p.email      ilike '%' || v_search || '%'
           or p.phone      ilike '%' || v_search || '%'
           or s.name       ilike '%' || v_search || '%')
  ), filtered as (
    select * from rows
     where p_status is null
        or state = p_status
        or (p_status = 'expiring' and state = 'active' and days_left <= 7)
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc)
                        from (select * from filtered order by created_at desc
                              limit least(greatest(p_limit, 1), 100)
                              offset greatest(p_offset, 0)) f), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.admin_stats()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
begin
  perform public.assert_admin();
  with st as (
    select s.id, s.created_at, public.store_state(s.id) as state, sub.end_date
      from public.stores s
      join public.profiles p on p.id = s.owner_id and p.role = 'client'
      left join public.subscriptions sub on sub.store_id = s.id
     where s.deleted_at is null
  )
  select jsonb_build_object(
    'total_clients', count(*),
    'new_clients',   count(*) filter (where created_at >= now() - interval '7 days'),
    'pending',       count(*) filter (where state = 'pending'),
    'active',        count(*) filter (where state = 'active'),
    'suspended',     count(*) filter (where state = 'suspended'),
    'expired',       count(*) filter (where state = 'expired'),
    'expiring_soon', count(*) filter (where state = 'active'
                                        and end_date - public.app_today() <= 7)
  ) into v from st;
  return v;
end;
$$;

-- ---------- CORBEILLE (admin) -------------------------------------------------
-- 1) Un compte SUSPENDU peut être mis à la corbeille (restaurable pendant 30 jours).
-- 2) Purge définitive : à la main depuis la corbeille, ou automatiquement après 30 jours
--    (run_daily_subscription_jobs). Client : compte + boutique + tout le reste (cascade
--    depuis auth.users). Admin : seule sa boutique est supprimée, le compte admin reste.
--    Les images sont effacées par admin.html via l'API Storage (impossible en SQL).
drop function if exists public.admin_delete_client(uuid);

create or replace function public.admin_trash_store(p_store_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_store public.stores%rowtype;
begin
  perform public.assert_admin();
  select * into v_store from public.stores where id = p_store_id for update;
  if not found then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;
  if v_store.status <> 'suspended' then raise exception 'NOT_SUSPENDED' using errcode = 'P0001'; end if;
  if v_store.deleted_at is not null then return; end if;
  update public.stores set deleted_at = now() where id = p_store_id;
  perform public.write_audit('trash', v_store.owner_id, p_store_id, jsonb_build_object('name', v_store.name));
end;
$$;

create or replace function public.admin_restore_store(p_store_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_store public.stores%rowtype;
begin
  perform public.assert_admin();
  update public.stores set deleted_at = null
   where id = p_store_id and deleted_at is not null returning * into v_store;
  if not found then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;
  perform public.write_audit('restore', v_store.owner_id, p_store_id, jsonb_build_object('name', v_store.name));
end;
$$;

-- Interne (non exécutable depuis le navigateur).
create or replace function public.purge_store(p_store_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_store public.stores%rowtype;
  v_owner public.profiles%rowtype;
  v_details jsonb;
begin
  select * into v_store from public.stores where id = p_store_id and deleted_at is not null for update;
  if not found then raise exception 'NOT_IN_TRASH' using errcode = 'P0001'; end if;
  select * into v_owner from public.profiles where id = v_store.owner_id;
  v_details := jsonb_build_object('name', v_store.name, 'email', v_owner.email,
    'owner', trim(coalesce(v_owner.first_name, '') || ' ' || coalesce(v_owner.last_name, '')));
  -- Le journal garde une trace (store_id / target_user_id passeront à null).
  if v_owner.role = 'admin' then
    perform public.write_audit('delete_store', v_owner.id, p_store_id, v_details);
    delete from public.stores where id = p_store_id;
    return 'store';
  end if;
  perform public.write_audit('delete_client', v_owner.id, p_store_id, v_details);
  delete from auth.users where id = v_owner.id;
  return 'client';
end;
$$;

create or replace function public.admin_purge_store(p_store_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_admin();
  return public.purge_store(p_store_id);
end;
$$;

create or replace function public.admin_list_trash()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public.assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'store_id', s.id, 'store_name', s.name, 'deleted_at', s.deleted_at,
      'purge_on', (s.deleted_at + interval '30 days')::date,
      'user_id', p.id, 'first_name', p.first_name, 'last_name', p.last_name,
      'email', p.email, 'role', p.role) order by s.deleted_at desc)
      from public.stores s join public.profiles p on p.id = s.owner_id
     where s.deleted_at is not null), '[]'::jsonb);
end;
$$;

create or replace function public.run_daily_subscription_jobs()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_expired int := 0;
  v_reminded int := 0;
  v_purged int := 0;
  r record;
begin
  -- Corbeille : purge définitive après 30 jours.
  for r in select id from public.stores where deleted_at < now() - interval '30 days' loop
    perform public.purge_store(r.id);
    v_purged := v_purged + 1;
  end loop;

  for r in
    update public.subscriptions
       set status = 'expired'
     where status = 'active' and end_date < public.app_today()
    returning store_id, user_id, end_date
  loop
    v_expired := v_expired + 1;
    insert into public.audit_logs (actor_id, action, target_user_id, store_id, details)
    values (null, 'expire', r.user_id, r.store_id, jsonb_build_object('end_date', r.end_date));
    perform public.notify_owner(r.store_id, 'subscription_expired', 'Abonnement expiré',
      'Votre abonnement a expiré.');
  end loop;

  for r in
    select sub.store_id, sub.end_date - public.app_today() as days_left
      from public.subscriptions sub
     where sub.status = 'active'
       and sub.end_date - public.app_today() in (30, 7, 2)
       and not exists (select 1 from public.notifications n
                        where n.store_id = sub.store_id and n.type = 'subscription_expiring'
                          and n.created_at::date = current_date)
  loop
    v_reminded := v_reminded + 1;
    perform public.notify_owner(r.store_id, 'subscription_expiring',
      case when r.days_left <= 2 then 'Attention, votre abonnement expire bientôt.'
           else 'Votre abonnement expire dans ' || r.days_left || ' jours.' end,
      'Contactez-nous pour renouveler votre abonnement.');
  end loop;

  return jsonb_build_object('expired', v_expired, 'reminders', v_reminded, 'purged', v_purged);
end;
$$;

revoke execute on function public.purge_store(uuid) from public, anon, authenticated;
revoke execute on function public.run_daily_subscription_jobs() from public, anon, authenticated;
revoke execute on function public.admin_list_clients(text, text, int, int, boolean) from public, anon;
revoke execute on function public.admin_trash_store(uuid) from public, anon;
revoke execute on function public.admin_restore_store(uuid) from public, anon;
revoke execute on function public.admin_purge_store(uuid) from public, anon;
revoke execute on function public.admin_list_trash() from public, anon;
grant execute on function public.admin_trash_store(uuid)               to authenticated;
grant execute on function public.admin_restore_store(uuid)             to authenticated;
grant execute on function public.admin_purge_store(uuid)               to authenticated;
grant execute on function public.admin_list_trash()                    to authenticated;
grant execute on function public.admin_list_clients(text, text, int, int, boolean) to authenticated;
grant execute on all functions in schema public to service_role;
