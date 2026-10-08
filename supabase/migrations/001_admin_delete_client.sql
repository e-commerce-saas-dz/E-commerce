-- Mise à jour du 2026-10-08 : corbeille admin (suppression définitive d'un client suspendu).
-- À exécuter une fois dans Supabase > SQL Editor si schema.sql a été installé avant cette date.

-- Supprimer définitivement un client SUSPENDU : compte de connexion, profil, boutique,
-- produits, commandes… (tout part en cascade depuis auth.users). Irréversible.
-- Les images de la boutique sont effacées avant par admin.html (API Storage).
create or replace function public.admin_delete_client(p_store_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_store public.stores%rowtype;
  v_owner public.profiles%rowtype;
begin
  perform public.assert_admin();
  select * into v_store from public.stores where id = p_store_id for update;
  if not found then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;
  if v_store.status <> 'suspended' then raise exception 'NOT_SUSPENDED' using errcode = 'P0001'; end if;
  select * into v_owner from public.profiles where id = v_store.owner_id;
  if v_owner.role = 'admin' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;

  -- Le journal garde une trace (store_id / target_user_id passeront à null).
  perform public.write_audit('delete_client', v_owner.id, p_store_id, jsonb_build_object(
    'name', v_store.name, 'email', v_owner.email,
    'owner', trim(coalesce(v_owner.first_name, '') || ' ' || coalesce(v_owner.last_name, ''))));
  delete from auth.users where id = v_owner.id;
end;
$$;

revoke execute on function public.admin_delete_client(uuid) from public, anon;
grant execute on function public.admin_delete_client(uuid) to authenticated;
