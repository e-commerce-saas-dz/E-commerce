-- =============================================================================
--  TESTS MULTI-TENANT (à lancer APRÈS schema.sql, dans Supabase → SQL Editor)
-- =============================================================================
--  Crée 4 comptes de test (clientA, clientB, clientC en attente, admin),
--  simule chaque utilisateur comme le ferait l'API Supabase (rôle + JWT),
--  vérifie l'isolation, puis SUPPRIME toutes les données de test.
--  Résultat : un tableau "test / ok". Toutes les lignes doivent être "true".
--
--  Sans danger pour une base réelle : seuls les comptes de test
--  (UUID fixes ci-dessous, emails @test.local) sont créés puis supprimés.
-- =============================================================================

drop schema if exists tests cascade;
create schema tests;
grant usage on schema tests to anon, authenticated;

create table tests.results (n serial, test text, ok boolean, info text);
grant insert, select on tests.results to anon, authenticated;
grant usage on sequence tests.results_n_seq to anon, authenticated;

-- Identifiants fixes des comptes de test
create function tests.uid(p text) returns uuid language sql immutable as $$
  select case p
    when 'A'     then 'aaaaaaaa-0000-4000-8000-00000000000a'
    when 'B'     then 'bbbbbbbb-0000-4000-8000-00000000000b'
    when 'C'     then 'cccccccc-0000-4000-8000-00000000000c'
    when 'ADMIN' then 'dddddddd-0000-4000-8000-00000000000d'
  end::uuid
$$;

-- Se faire passer pour un utilisateur (exactement ce que fait l'API Supabase)
create function tests.login(p text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.uid(p), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function tests.login_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('role', 'anon', true);
end $$;

create function tests.logout() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tests.check(p_test text, p_ok boolean, p_info text default null) returns void
language sql as $$
  insert into tests.results (test, ok, info) values (p_test, coalesce(p_ok, false), p_info);
$$;

grant execute on all functions in schema tests to anon, authenticated;

create function tests.store(p text) returns uuid language sql stable security definer
set search_path = public as $$
  select id from public.stores where owner_id = tests.uid(p)
$$;
grant execute on function tests.store(text) to anon, authenticated;

-- ---------- Nettoyage d'une éventuelle exécution précédente ----------
create function tests.cleanup() returns void language plpgsql as $$
begin
  delete from public.audit_logs
   where actor_id in (select tests.uid(x) from unnest(array['A','B','C','ADMIN']) x)
      or target_user_id in (select tests.uid(x) from unnest(array['A','B','C','ADMIN']) x)
      or store_id in (select id from public.stores
                       where owner_id in (select tests.uid(x) from unnest(array['A','B','C','ADMIN']) x));
  delete from auth.users where id in (select tests.uid(x) from unnest(array['A','B','C','ADMIN']) x);
  delete from public.plans where name = 'TEST_TINY';
end $$;
select tests.cleanup();

-- =============================================================================
-- SETUP
-- =============================================================================

-- clientA essaie de s'inscrire avec role = admin (doit être ignoré)
insert into auth.users (id, email, raw_user_meta_data) values
  (tests.uid('A'), 'clienta@test.local', '{"first_name":"Alice","last_name":"A","business_name":"Boutique Alpha","phone":"0550000001","role":"admin"}'),
  (tests.uid('B'), 'clientb@test.local', '{"first_name":"Bob","last_name":"B","business_name":"Bêta Parfums","phone":"0550000002"}'),
  (tests.uid('C'), 'clientc@test.local', '{"first_name":"Carl","last_name":"C","business_name":"Gamma"}'),
  (tests.uid('ADMIN'), 'admin@test.local', '{"first_name":"Admin","last_name":"Test"}');

update public.profiles set role = 'admin' where id = tests.uid('ADMIN');
insert into public.plans (name, price, duration_days, max_products, max_categories)
values ('TEST_TINY', 0, 30, 2, 1);

-- =============================================================================
-- 1. INSCRIPTION
-- =============================================================================
do $$ begin
  perform tests.check('inscription : profil, boutique, paramètres, abonnement créés',
    (select count(*) from public.profiles where id = tests.uid('A')) = 1
    and tests.store('A') is not null
    and (select count(*) from public.store_settings where store_id = tests.store('A')) = 1
    and (select status from public.subscriptions where store_id = tests.store('A')) = 'pending');
  perform tests.check('inscription : role=admin envoyé par le navigateur ignoré',
    (select role from public.profiles where id = tests.uid('A')) = 'client');
  perform tests.check('inscription : slug généré',
    (select slug from public.stores where id = tests.store('B')) like 'beta-parfums-%');
  perform tests.check('inscription : journal "signup" écrit',
    exists (select 1 from public.audit_logs where action = 'signup' and target_user_id = tests.uid('A')));
end $$;

-- =============================================================================
-- 2. COMPTE PENDING
-- =============================================================================
do $$
declare v jsonb; n int;
begin
  perform tests.login('C');
  v := public.my_account_status();
  perform tests.check('pending : my_account_status = pending', v ->> 'state' = 'pending', v::text);
  select count(*) into n from public.stores where id = tests.store('C');
  perform tests.check('pending : peut lire sa propre boutique', n = 1);
  begin
    insert into public.products (store_id, name, price) values (tests.store('C'), 'X', 10);
    perform tests.check('pending : ne peut PAS créer de produit', false);
  exception when others then
    perform tests.check('pending : ne peut PAS créer de produit', true, sqlerrm);
  end;
  update public.store_settings set primary_color = '#ff0000' where store_id = tests.store('C');
  get diagnostics n = row_count;
  perform tests.check('pending : ne peut PAS modifier ses paramètres', n = 0);
  perform tests.logout();
end $$;

do $$ begin
  perform tests.login_anon();
  perform tests.check('pending : boutique publique indisponible',
    public.get_public_store(tests.store('C')) ->> 'state' = 'pending');
  perform tests.logout();
end $$;

-- =============================================================================
-- 3. ADMIN : seul l'admin peut activer
-- =============================================================================
do $$ begin
  perform tests.login('A');
  begin
    perform public.admin_activate(tests.store('A'), (select id from public.plans where name = 'Basic'));
    perform tests.check('client : ne peut PAS appeler admin_activate', false);
  exception when others then
    perform tests.check('client : ne peut PAS appeler admin_activate', sqlerrm = 'FORBIDDEN', sqlerrm);
  end;
  begin
    update public.subscriptions set status = 'active' where store_id = tests.store('A');
    perform tests.check('client : ne peut PAS modifier son abonnement',
      (select status from public.subscriptions where store_id = tests.store('A')) = 'pending');
  exception when others then
    perform tests.check('client : ne peut PAS modifier son abonnement', true, sqlerrm);
  end;
  begin
    update public.profiles set role = 'admin' where id = tests.uid('A');
    perform tests.check('client : ne peut PAS se donner le rôle admin', false);
  exception when others then
    perform tests.check('client : ne peut PAS se donner le rôle admin', true, sqlerrm);
  end;
  perform tests.logout();
end $$;

do $$
declare v jsonb;
begin
  perform tests.login('ADMIN');
  v := public.admin_activate(tests.store('A'), (select id from public.plans where name = 'Basic'));
  perform tests.check('admin : active clientA (fin = début + 30 j)',
    (v ->> 'end_date')::date = public.app_today() + 30, v::text);
  perform public.admin_activate(tests.store('B'), (select id from public.plans where name = 'TEST_TINY'));
  perform tests.check('admin : voit toutes les boutiques',
    (select count(*) from public.stores where id in (tests.store('A'), tests.store('B'), tests.store('C'))) = 3);
  v := public.admin_stats();
  perform tests.check('admin : statistiques', (v ->> 'active')::int >= 2 and (v ->> 'pending')::int >= 1, v::text);
  v := public.admin_list_clients('Alpha', null, 25, 0);
  perform tests.check('admin : recherche clients', (v ->> 'total')::int = 1, v::text);
  insert into public.admin_notes (target_user_id, store_id, content)
  values (tests.uid('A'), tests.store('A'), 'Paiement reçu le 08/10/2026.');
  perform tests.logout();
end $$;

do $$
declare v jsonb;
begin
  perform tests.login('A');
  v := public.my_account_status();
  perform tests.check('clientA actif : my_account_status = active, 30 jours',
    v ->> 'state' = 'active' and (v ->> 'days_left')::int = 30, v::text);
  perform tests.check('clientA : notification "compte activé" reçue',
    exists (select 1 from public.notifications where type = 'account_activated'));
  perform tests.check('clientA : ne voit PAS les notes internes admin',
    (select count(*) from public.admin_notes) = 0);
  begin
    perform count(*) from public.audit_logs;
    perform tests.check('clientA : ne voit PAS le journal d''audit',
      (select count(*) from public.audit_logs) = 0);
  exception when others then
    perform tests.check('clientA : ne voit PAS le journal d''audit', true, sqlerrm);
  end;
  perform tests.logout();
end $$;

-- =============================================================================
-- 4. ISOLATION A / B
-- =============================================================================
do $$
declare n int;
begin
  perform tests.login('A');
  insert into public.categories (store_id, name) values (tests.store('A'), 'Robes');
  insert into public.products (store_id, name, price, stock, category_id)
  values (tests.store('A'), 'Robe rouge', 3000, 5,
          (select id from public.categories where store_id = tests.store('A') and name = 'Robes'));
  insert into public.products (store_id, name, price, stock, is_active)
  values (tests.store('A'), 'Brouillon A', 100, 1, false);
  perform tests.check('clientA : crée catégorie et produits dans SA boutique',
    (select count(*) from public.products where store_id = tests.store('A')) = 2);
  perform tests.logout();

  perform tests.login('B');
  insert into public.products (store_id, name, price, stock) values (tests.store('B'), 'Parfum B', 8000, 3);
  insert into public.products (store_id, name, price, stock, is_active)
  values (tests.store('B'), 'Secret B (inactif)', 1, 1, false);
  perform tests.logout();
end $$;

do $$
declare n int;
begin
  perform tests.login('A');

  begin
    insert into public.products (store_id, name, price) values (tests.store('B'), 'Intrus', 1);
    perform tests.check('clientA : ne peut PAS créer un produit dans storeB', false);
  exception when others then
    perform tests.check('clientA : ne peut PAS créer un produit dans storeB', true, sqlerrm);
  end;

  select count(*) into n from public.products where store_id = tests.store('B') and not is_active;
  perform tests.check('clientA : ne voit PAS les produits inactifs de storeB', n = 0);

  select count(*) into n from public.stores where id = tests.store('B');
  perform tests.check('clientA : ne lit PAS la fiche de storeB', n = 0);

  select count(*) into n from public.store_settings where store_id = tests.store('B');
  perform tests.check('clientA : ne lit PAS les paramètres de storeB', n = 0);

  update public.products set price = 1 where store_id = tests.store('B');
  get diagnostics n = row_count;
  perform tests.check('clientA : ne peut PAS modifier les produits de storeB', n = 0);

  delete from public.products where store_id = tests.store('B');
  get diagnostics n = row_count;
  perform tests.check('clientA : ne peut PAS supprimer les produits de storeB', n = 0);

  update public.store_settings set primary_color = '#000000' where store_id = tests.store('B');
  get diagnostics n = row_count;
  perform tests.check('clientA : ne peut PAS modifier les paramètres de storeB', n = 0);

  update public.stores set name = 'Piraté' where id = tests.store('B');
  get diagnostics n = row_count;
  perform tests.check('clientA : ne peut PAS renommer storeB', n = 0);

  begin
    update public.products set store_id = tests.store('B') where store_id = tests.store('A');
    perform tests.check('clientA : ne peut PAS déplacer un produit vers storeB', false);
  exception when others then
    perform tests.check('clientA : ne peut PAS déplacer un produit vers storeB', true, sqlerrm);
  end;

  begin
    update public.stores set status = 'active', slug = 'pirate' where id = tests.store('A');
    perform tests.check('clientA : ne peut PAS changer le statut/slug de sa boutique', false);
  exception when others then
    perform tests.check('clientA : ne peut PAS changer le statut/slug de sa boutique', true, sqlerrm);
  end;

  begin
    update public.store_settings set primary_color = 'red;}body{display:none' where store_id = tests.store('A');
    perform tests.check('couleurs : injection CSS refusée', false);
  exception when others then
    perform tests.check('couleurs : injection CSS refusée', true, sqlerrm);
  end;

  perform tests.check('clientA : my_store_id() = storeA (jamais storeB)', public.my_store_id() = tests.store('A'));
  perform tests.logout();
end $$;

-- =============================================================================
-- 5. VISITEUR ANONYME
-- =============================================================================
do $$
declare v jsonb; n int;
begin
  perform tests.login_anon();

  begin
    select count(*) into n from public.stores;
    perform tests.check('visiteur : ne peut PAS lister les boutiques', n = 0);
  exception when others then
    perform tests.check('visiteur : ne peut PAS lister les boutiques', true, sqlerrm);
  end;

  v := public.get_public_store(tests.store('A'));
  perform tests.check('visiteur : get_public_store(A) = ok, sans owner_id',
    v ->> 'state' = 'ok' and v -> 'store' ->> 'name' = 'Boutique Alpha'
    and not (v -> 'store' ? 'owner_id'), v::text);

  perform tests.check('visiteur : boutique inconnue = not_found',
    public.get_public_store(gen_random_uuid()) ->> 'state' = 'not_found');

  select count(*) into n from public.products where store_id = tests.store('A');
  perform tests.check('visiteur : voit uniquement les produits ACTIFS de storeA', n = 1);

  select count(*) into n from public.products where store_id = tests.store('C');
  perform tests.check('visiteur : aucun produit d''une boutique pending', n = 0);

  begin
    select count(*) into n from public.orders;
    perform tests.check('visiteur : ne lit PAS les commandes', n = 0);
  exception when others then
    perform tests.check('visiteur : ne lit PAS les commandes', true, sqlerrm);
  end;

  begin
    insert into public.orders (store_id, order_number, customer_name, customer_phone, total)
    values (tests.store('A'), 999, 'Pirate', '000000', 1);
    perform tests.check('visiteur : ne peut PAS insérer une commande directement', false);
  exception when others then
    perform tests.check('visiteur : ne peut PAS insérer une commande directement', true, sqlerrm);
  end;

  begin
    perform public.admin_stats();
    perform tests.check('visiteur : ne peut PAS appeler les fonctions admin', false);
  exception when others then
    perform tests.check('visiteur : ne peut PAS appeler les fonctions admin', true, sqlerrm);
  end;

  perform tests.logout();
end $$;

-- =============================================================================
-- 6. COMMANDES
-- =============================================================================
do $$
declare v jsonb; pid uuid; pidB uuid;
begin
  select id into pid from public.products where store_id = tests.store('A') and name = 'Robe rouge';
  select id into pidB from public.products where store_id = tests.store('B') and name = 'Parfum B';
  perform tests.login_anon();

  -- le navigateur envoie un faux prix : il doit être ignoré
  v := public.place_order(tests.store('A'),
         '{"name":"Client Final","phone":"0661000000","address":"Alger"}',
         jsonb_build_array(jsonb_build_object('product_id', pid, 'quantity', 2, 'price', 1)));
  perform tests.check('commande : total recalculé en base (2 × 3000)',
    (v ->> 'total')::numeric = 6000 and (v ->> 'order_number')::int = 1, v::text);

  begin
    perform public.place_order(tests.store('A'), '{"name":"X","phone":"0661000001"}',
      jsonb_build_array(jsonb_build_object('product_id', pidB, 'quantity', 1)));
    perform tests.check('commande : produit de storeB refusé dans storeA', false);
  exception when others then
    perform tests.check('commande : produit de storeB refusé dans storeA', sqlerrm = 'PRODUCT_UNAVAILABLE', sqlerrm);
  end;

  begin
    perform public.place_order(tests.store('A'), '{"name":"X","phone":"0661000001"}',
      jsonb_build_array(jsonb_build_object('product_id', pid, 'quantity', 50)));
    perform tests.check('commande : stock insuffisant refusé', false);
  exception when others then
    perform tests.check('commande : stock insuffisant refusé', sqlerrm like 'INSUFFICIENT_STOCK%', sqlerrm);
  end;

  begin
    perform public.place_order(tests.store('C'), '{"name":"X","phone":"0661000001"}', '[]');
    perform tests.check('commande : boutique pending refusée', false);
  exception when others then
    perform tests.check('commande : boutique pending refusée', sqlerrm = 'STORE_UNAVAILABLE', sqlerrm);
  end;

  perform tests.logout();

  perform tests.check('commande : stock décrémenté (5 → 3)',
    (select stock from public.products where id = pid) = 3);
  perform tests.check('commande : order_items avec store_id = storeA',
    (select count(*) from public.order_items where store_id = tests.store('A')) = 1);
end $$;

do $$
declare n int; oid uuid; v_total numeric;
begin
  perform tests.login('A');
  select count(*) into n from public.orders;
  perform tests.check('clientA : voit sa commande', n = 1);
  perform tests.check('clientA : voit le client final avec ses stats',
    (select orders_count from public.customer_stats where phone = '0661000000') = 1);
  perform tests.check('clientA : notification "nouvelle commande"',
    exists (select 1 from public.notifications where type = 'new_order'));

  select id into oid from public.orders limit 1;
  update public.orders set total = 1, customer_name = 'Modifié', status = 'confirmed' where id = oid;
  select total into v_total from public.orders where id = oid;
  perform tests.check('clientA : peut changer le statut, PAS le total ni le client',
    v_total = 6000 and (select status from public.orders where id = oid) = 'confirmed'
    and (select customer_name from public.orders where id = oid) = 'Client Final');

  update public.orders set status = 'cancelled' where id = oid;
  perform tests.check('annulation : stock remis (3 → 5)',
    (select stock from public.products where store_id = tests.store('A') and name = 'Robe rouge') = 5);
  perform tests.logout();

  perform tests.login('B');
  select count(*) into n from public.orders;
  perform tests.check('clientB : ne voit PAS les commandes de storeA', n = 0);
  select count(*) into n from public.customers;
  perform tests.check('clientB : ne voit PAS les clients de storeA', n = 0);
  select count(*) into n from public.order_items;
  perform tests.check('clientB : ne voit PAS les lignes de commande de storeA', n = 0);
  perform tests.logout();
end $$;

-- =============================================================================
-- 7. LIMITES DU PLAN (storeB : TEST_TINY = 2 produits, 1 catégorie)
-- =============================================================================
do $$ begin
  perform tests.login('B');
  begin
    insert into public.products (store_id, name, price) values (tests.store('B'), 'Troisième', 10);
    perform tests.check('plan : 3e produit refusé par la base (max 2)', false);
  exception when others then
    perform tests.check('plan : 3e produit refusé par la base (max 2)', sqlerrm = 'PLAN_LIMIT_PRODUCTS:2', sqlerrm);
  end;
  insert into public.categories (store_id, name) values (tests.store('B'), 'Cat 1');
  begin
    insert into public.categories (store_id, name) values (tests.store('B'), 'Cat 2');
    perform tests.check('plan : 2e catégorie refusée par la base (max 1)', false);
  exception when others then
    perform tests.check('plan : 2e catégorie refusée par la base (max 1)', sqlerrm = 'PLAN_LIMIT_CATEGORIES:1', sqlerrm);
  end;
  begin
    update public.products set category_id = (select id from public.categories where store_id = tests.store('A') limit 1)
     where store_id = tests.store('B');
    perform tests.check('produit : catégorie d''une autre boutique refusée', false);
  exception when others then
    perform tests.check('produit : catégorie d''une autre boutique refusée', true, sqlerrm);
  end;
  perform tests.logout();
end $$;

-- =============================================================================
-- 8. SUSPENSION / RÉACTIVATION
-- =============================================================================
do $$ begin
  perform tests.login('ADMIN');
  perform public.admin_suspend(tests.store('A'), 'Compte suspendu pour non-paiement.');
  perform tests.logout();
end $$;

do $$
declare n int; v jsonb;
begin
  perform tests.login('A');
  v := public.my_account_status();
  perform tests.check('suspendu : état + raison',
    v ->> 'state' = 'suspended' and v ->> 'suspension_reason' = 'Compte suspendu pour non-paiement.', v::text);
  select count(*) into n from public.orders;
  perform tests.check('suspendu : ne lit plus ses commandes', n = 0);
  begin
    insert into public.products (store_id, name, price) values (tests.store('A'), 'Y', 1);
    perform tests.check('suspendu : ne peut plus créer de produit', false);
  exception when others then
    perform tests.check('suspendu : ne peut plus créer de produit', true, sqlerrm);
  end;
  perform tests.logout();

  perform tests.login_anon();
  perform tests.check('suspendu : boutique publique = suspended',
    public.get_public_store(tests.store('A')) ->> 'state' = 'suspended');
  select count(*) into n from public.products where store_id = tests.store('A');
  perform tests.check('suspendu : aucun produit visible publiquement', n = 0);
  perform tests.logout();

  perform tests.login('ADMIN');
  perform tests.check('réactivation : état active',
    public.admin_reactivate(tests.store('A')) = 'active');
  perform tests.logout();
end $$;

-- =============================================================================
-- 9. EXPIRATION (la date suffit, sans attendre la tâche planifiée)
-- =============================================================================
update public.subscriptions
   set start_date = public.app_today() - 40, end_date = public.app_today() - 1
 where store_id = tests.store('B');

do $$
declare n int; v jsonb;
begin
  perform tests.login('B');
  v := public.my_account_status();
  perform tests.check('expiré : état expired dès que la date est dépassée',
    v ->> 'state' = 'expired' and (v ->> 'days_left')::int = -1, v::text);
  select count(*) into n from public.products where store_id = tests.store('B');
  perform tests.check('expiré : ne lit plus ses propres produits', n = 0);
  perform tests.logout();

  perform tests.login_anon();
  perform tests.check('expiré : boutique publique = expired',
    public.get_public_store(tests.store('B')) ->> 'state' = 'expired');
  perform tests.logout();
end $$;

do $$
declare v jsonb;
begin
  v := public.run_daily_subscription_jobs();
  perform tests.check('tâche quotidienne : statut passé à expired',
    (select status from public.subscriptions where store_id = tests.store('B')) = 'expired', v::text);

  perform tests.login('ADMIN');
  v := public.admin_extend(tests.store('B'), 30, null);
  perform tests.check('prolongation : +30 j depuis aujourd''hui, compte réactivé',
    (v ->> 'end_date')::date = public.app_today() + 30
    and public.store_state(tests.store('B')) = 'active', v::text);
  perform public.admin_change_plan(tests.store('B'), (select id from public.plans where name = 'Pro'));
  perform tests.check('changement de plan journalisé',
    exists (select 1 from public.audit_logs where action = 'change_plan' and store_id = tests.store('B')));
  perform tests.logout();
end $$;

-- =============================================================================
-- 10. CORBEILLE : mise à la corbeille, restauration, purge (manuelle et après 30 jours)
-- =============================================================================
do $$
declare v_store uuid := tests.store('A'); n int; v jsonb;
begin
  perform tests.login('B');
  begin
    perform public.admin_trash_store(v_store);
    perform tests.check('corbeille : refusée à un client', false);
  exception when others then
    perform tests.check('corbeille : refusée à un client', sqlerrm = 'FORBIDDEN', sqlerrm);
  end;
  begin
    perform public.purge_store(v_store);
    perform tests.check('purge interne non appelable par un client', false);
  exception when others then
    perform tests.check('purge interne non appelable par un client', true, sqlerrm);
  end;
  perform tests.logout();

  perform tests.login('ADMIN');
  begin
    perform public.admin_trash_store(v_store);
    perform tests.check('corbeille : refusée si le compte n''est pas suspendu', false);
  exception when others then
    perform tests.check('corbeille : refusée si le compte n''est pas suspendu', sqlerrm = 'NOT_SUSPENDED', sqlerrm);
  end;
  perform public.admin_suspend(v_store, 'test');
  perform public.admin_trash_store(v_store);
  v := public.admin_list_trash();
  perform tests.check('corbeille : listée, cachée des clients',
    jsonb_array_length(v) = 1
    and not exists (select 1 from jsonb_array_elements(public.admin_list_clients(null, null, 100, 0) -> 'rows') r
                     where r ->> 'store_id' = v_store::text), v::text);
  perform public.admin_restore_store(v_store);
  perform tests.check('corbeille : restaurée (toujours suspendue)',
    jsonb_array_length(public.admin_list_trash()) = 0 and public.store_state(v_store) = 'suspended');
  perform public.admin_trash_store(v_store);
  perform tests.logout();

  -- 31 jours plus tard : la tâche quotidienne purge.
  update public.stores set deleted_at = now() - interval '31 days' where id = v_store;
  v := public.run_daily_subscription_jobs();
  select (select count(*) from auth.users where id = tests.uid('A'))
       + (select count(*) from public.profiles where id = tests.uid('A'))
       + (select count(*) from public.stores where id = v_store)
       + (select count(*) from public.products where store_id = v_store)
       + (select count(*) from public.orders where store_id = v_store)
       + (select count(*) from public.subscriptions where store_id = v_store) into n;
  perform tests.check('purge auto après 30 j : compte, boutique, produits, commandes effacés',
    n = 0 and (v ->> 'purged')::int = 1, n::text || ' ' || v::text);
  perform tests.check('purge : tracée dans le journal',
    exists (select 1 from public.audit_logs where action = 'delete_client' and details ->> 'email' = 'clienta@test.local'));
  perform tests.check('purge : les autres boutiques sont intactes',
    exists (select 1 from public.stores where id = tests.store('B')));
end $$;

do $$
declare v_store uuid := tests.store('ADMIN'); v text;
begin
  perform tests.login('ADMIN');
  perform public.admin_suspend(v_store, 'test');
  begin
    perform public.admin_purge_store(v_store);
    perform tests.check('purge manuelle : refusée hors corbeille', false);
  exception when others then
    perform tests.check('purge manuelle : refusée hors corbeille', sqlerrm = 'NOT_IN_TRASH', sqlerrm);
  end;
  perform public.admin_trash_store(v_store);
  v := public.admin_purge_store(v_store);
  perform tests.check('boutique d''un admin : seule la boutique part, le compte admin reste',
    v = 'store'
    and not exists (select 1 from public.stores where id = v_store)
    and exists (select 1 from public.profiles where id = tests.uid('ADMIN') and role = 'admin'));
  perform tests.check('admin sans boutique : statut lisible, toujours admin',
    public.my_account_status() ->> 'role' = 'admin' and public.my_account_status() ->> 'state' = 'no_store');
  perform tests.logout();
end $$;

-- =============================================================================
-- RÉSULTATS puis NETTOYAGE
-- =============================================================================
select tests.cleanup();

select n, test, ok, info from tests.results order by n;
