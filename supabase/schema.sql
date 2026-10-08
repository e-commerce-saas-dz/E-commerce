-- =============================================================================
--  SAAS E-COMMERCE MULTI-BOUTIQUES : SCHÉMA SUPABASE COMPLET (Phase 1)
-- =============================================================================
--  À coller tel quel dans : Supabase → SQL Editor → New query → Run.
--  Le script est ré-exécutable : le lancer une seconde fois ne casse rien.
--
--  Contenu :
--    1. Réglages (fuseau horaire)
--    2. Tables, contraintes, index
--    3. Fonctions d'accès (cœur du multi-tenant)
--    4. Triggers (inscription, gardes, limites de plan, audit)
--    5. Fonctions RPC (boutique publique, commande, compte, admin)
--    6. Row Level Security (policies)
--    7. Droits (grants)
--    8. Storage (buckets + policies)
--    9. Plans d'exemple
--   10. Tâche planifiée quotidienne (expiration)
--
--  Après exécution, pour créer le premier Super Admin :
--    1. inscris-toi normalement sur register.html ;
--    2. exécute ici :  select public.promote_to_admin('ton-email@exemple.com');
-- =============================================================================


-- =============================================================================
-- 1. RÉGLAGES
-- =============================================================================

-- Date "du jour" utilisée partout pour les abonnements.
-- Pour changer de fuseau horaire, modifier uniquement cette fonction.
create or replace function public.app_today()
returns date
language sql
stable
as $$
  select (now() at time zone 'Africa/Algiers')::date;
$$;


-- =============================================================================
-- 2. TABLES
-- =============================================================================

-- ---------- profiles : un par utilisateur (id = auth.users.id) ---------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  first_name  text not null default '' check (char_length(first_name) <= 80),
  last_name   text not null default '' check (char_length(last_name) <= 80),
  email       text not null,
  phone       text check (char_length(phone) <= 30),
  whatsapp    text check (char_length(whatsapp) <= 30),
  role        text not null default 'client' check (role in ('client', 'admin')),
  city        text check (char_length(city) <= 80),
  country     text check (char_length(country) <= 80),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- stores : une boutique par commerçant (V1) ------------------------
create table if not exists public.stores (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null unique references public.profiles (id) on delete cascade,
  name               text not null check (char_length(name) between 1 and 120),
  slug               text unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  business_type      text check (char_length(business_type) <= 80),
  description        text check (char_length(description) <= 2000),
  slogan             text check (char_length(slogan) <= 200),
  address            text check (char_length(address) <= 300),
  city               text check (char_length(city) <= 80),
  country            text check (char_length(country) <= 80),
  logo_url           text check (char_length(logo_url) <= 1000),
  favicon_url        text check (char_length(favicon_url) <= 1000),
  banner_url         text check (char_length(banner_url) <= 1000),
  status             text not null default 'pending' check (status in ('pending', 'active', 'suspended')),
  suspension_reason  text check (char_length(suspension_reason) <= 500),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists stores_status_idx on public.stores (status);

-- ---------- store_settings : apparence et paramètres (1-1 avec stores) -------
create table if not exists public.store_settings (
  store_id                uuid primary key references public.stores (id) on delete cascade,
  theme                   text not null default 'modern' check (theme in ('classic', 'modern', 'minimal', 'elegant')),
  primary_color           text not null default '#111827' check (primary_color ~ '^#[0-9a-fA-F]{6}$'),
  secondary_color         text not null default '#6366f1' check (secondary_color ~ '^#[0-9a-fA-F]{6}$'),
  text_color              text not null default '#111827' check (text_color ~ '^#[0-9a-fA-F]{6}$'),
  button_color            text not null default '#111827' check (button_color ~ '^#[0-9a-fA-F]{6}$'),
  background_color        text not null default '#ffffff' check (background_color ~ '^#[0-9a-fA-F]{6}$'),
  contact_phone           text check (char_length(contact_phone) <= 30),
  contact_whatsapp        text check (char_length(contact_whatsapp) <= 30),
  contact_email           text check (char_length(contact_email) <= 120),
  opening_hours           text check (char_length(opening_hours) <= 300),
  instagram_url           text check (char_length(instagram_url) <= 300),
  facebook_url            text check (char_length(facebook_url) <= 300),
  tiktok_url              text check (char_length(tiktok_url) <= 300),
  currency                text not null default 'DZD' check (char_length(currency) between 1 and 8),
  whatsapp_order_enabled  boolean not null default false,
  delivery_info           text check (char_length(delivery_info) <= 1000),
  delivery_fee            numeric(12,2) not null default 0 check (delivery_fee >= 0),
  seo_title               text check (char_length(seo_title) <= 120),
  seo_description         text check (char_length(seo_description) <= 300),
  extra                   jsonb not null default '{}'::jsonb,
  updated_at              timestamptz not null default now()
);

-- ---------- plans : formules modifiables par le Super Admin ------------------
create table if not exists public.plans (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(name) between 1 and 80),
  description     text check (char_length(description) <= 1000),
  price           numeric(12,2) not null default 0 check (price >= 0),
  duration_days   int not null default 30 check (duration_days > 0),
  max_products    int check (max_products is null or max_products >= 0),   -- null = illimité
  max_categories  int check (max_categories is null or max_categories >= 0), -- null = illimité
  features        jsonb not null default '[]'::jsonb,
  active          boolean not null default true,
  sort_order      int not null default 0,
  created_at      timestamptz not null default now()
);

-- ---------- subscriptions : abonnement courant d'une boutique ----------------
create table if not exists public.subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  store_id    uuid not null unique references public.stores (id) on delete cascade,
  plan_id     uuid references public.plans (id) on delete restrict,
  status      text not null default 'pending' check (status in ('pending', 'active', 'suspended', 'expired')),
  start_date  date,
  end_date    date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- un abonnement actif a forcément un plan et des dates cohérentes
  constraint subscriptions_active_complete check (
    status <> 'active'
    or (plan_id is not null and start_date is not null and end_date is not null)
  ),
  constraint subscriptions_dates_order check (end_date is null or start_date is null or end_date >= start_date)
);
create index if not exists subscriptions_user_idx on public.subscriptions (user_id);
create index if not exists subscriptions_plan_idx on public.subscriptions (plan_id);
create index if not exists subscriptions_status_end_idx on public.subscriptions (status, end_date);

-- ---------- categories --------------------------------------------------------
create table if not exists public.categories (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references public.stores (id) on delete cascade,
  name         text not null check (char_length(name) between 1 and 80),
  description  text check (char_length(description) <= 1000),
  image_url    text check (char_length(image_url) <= 1000),
  sort_order   int not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (store_id, name),
  unique (id, store_id)          -- permet aux produits de vérifier "même boutique"
);
create index if not exists categories_store_idx on public.categories (store_id, sort_order);

-- ---------- products ----------------------------------------------------------
create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references public.stores (id) on delete cascade,
  category_id  uuid,
  name         text not null check (char_length(name) between 1 and 150),
  description  text check (char_length(description) <= 5000),
  price        numeric(12,2) not null check (price >= 0),
  old_price    numeric(12,2) check (old_price is null or old_price >= 0),
  stock        int not null default 0 check (stock >= 0),
  track_stock  boolean not null default true,   -- false = stock non géré (toujours commandable)
  sku          text check (char_length(sku) <= 60),
  image_url    text check (char_length(image_url) <= 1000),
  images       text[] not null default '{}' check (cardinality(images) <= 8),
  is_featured  boolean not null default false,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (store_id, sku),
  unique (id, store_id),
  -- la catégorie doit appartenir à la MÊME boutique ; si elle est supprimée,
  -- seul category_id devient null (store_id reste intact)
  foreign key (category_id, store_id)
    references public.categories (id, store_id) on delete set null (category_id)
);
create index if not exists products_store_active_idx on public.products (store_id, is_active);
create index if not exists products_store_category_idx on public.products (store_id, category_id);
create index if not exists products_store_created_idx on public.products (store_id, created_at desc);

-- ---------- customers : clients finaux d'une boutique -------------------------
create table if not exists public.customers (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 120),
  phone       text not null check (char_length(phone) between 4 and 30),
  whatsapp    text check (char_length(whatsapp) <= 30),
  address     text check (char_length(address) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (store_id, phone),
  unique (id, store_id)
);

-- ---------- orders -------------------------------------------------------------
create table if not exists public.orders (
  id                 uuid primary key default gen_random_uuid(),
  store_id           uuid not null references public.stores (id) on delete cascade,
  order_number       int not null,
  customer_id        uuid,
  customer_name      text not null check (char_length(customer_name) between 1 and 120),
  customer_phone     text not null check (char_length(customer_phone) between 4 and 30),
  customer_whatsapp  text check (char_length(customer_whatsapp) <= 30),
  customer_address   text check (char_length(customer_address) <= 500),
  comment            text check (char_length(comment) <= 1000),
  subtotal           numeric(12,2) not null default 0 check (subtotal >= 0),
  delivery_fee       numeric(12,2) not null default 0 check (delivery_fee >= 0),
  total              numeric(12,2) not null default 0 check (total >= 0),
  status             text not null default 'new'
                       check (status in ('new', 'confirmed', 'shipped', 'delivered', 'cancelled')),
  source             text not null default 'web' check (source in ('web', 'whatsapp')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (store_id, order_number),
  unique (id, store_id),
  foreign key (customer_id, store_id)
    references public.customers (id, store_id) on delete set null (customer_id)
);
create index if not exists orders_store_created_idx on public.orders (store_id, created_at desc);
create index if not exists orders_store_status_idx on public.orders (store_id, status);
create index if not exists orders_customer_idx on public.orders (customer_id);

-- ---------- order_items --------------------------------------------------------
create table if not exists public.order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null,
  store_id      uuid not null references public.stores (id) on delete cascade,
  product_id    uuid,
  product_name  text not null,
  unit_price    numeric(12,2) not null check (unit_price >= 0),
  quantity      int not null check (quantity between 1 and 999),
  line_total    numeric(12,2) not null check (line_total >= 0),
  created_at    timestamptz not null default now(),
  foreign key (order_id, store_id)
    references public.orders (id, store_id) on delete cascade,
  foreign key (product_id, store_id)
    references public.products (id, store_id) on delete set null (product_id)
);
create index if not exists order_items_order_idx on public.order_items (order_id);
create index if not exists order_items_store_idx on public.order_items (store_id);
create index if not exists order_items_product_idx on public.order_items (product_id);

-- ---------- admin_notes : notes internes, JAMAIS visibles par le client --------
create table if not exists public.admin_notes (
  id              uuid primary key default gen_random_uuid(),
  target_user_id  uuid not null references public.profiles (id) on delete cascade,
  store_id        uuid references public.stores (id) on delete cascade,
  author_id       uuid default auth.uid() references public.profiles (id) on delete set null,
  content         text not null check (char_length(content) between 1 and 5000),
  created_at      timestamptz not null default now()
);
create index if not exists admin_notes_target_idx on public.admin_notes (target_user_id, created_at desc);

-- ---------- notifications -------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  store_id    uuid references public.stores (id) on delete cascade,
  type        text not null check (type in (
                'account_activated', 'account_suspended', 'account_reactivated',
                'subscription_expiring', 'subscription_expired', 'subscription_extended',
                'plan_changed', 'new_order', 'new_signup')),
  title       text not null,
  message     text,
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, is_read, created_at desc);
create index if not exists notifications_store_idx on public.notifications (store_id);

-- ---------- audit_logs : journal, lecture admin uniquement, jamais modifié -----
create table if not exists public.audit_logs (
  id              uuid primary key default gen_random_uuid(),
  actor_id        uuid references public.profiles (id) on delete set null,  -- null = système
  action          text not null,
  target_user_id  uuid references public.profiles (id) on delete set null,
  store_id        uuid references public.stores (id) on delete set null,
  details         jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
create index if not exists audit_logs_created_idx on public.audit_logs (created_at desc);
create index if not exists audit_logs_store_idx on public.audit_logs (store_id);
create index if not exists audit_logs_target_idx on public.audit_logs (target_user_id);

-- ---------- vue : statistiques des clients d'une boutique ----------------------
-- security_invoker : la vue respecte la RLS de l'utilisateur qui l'interroge.
create or replace view public.customer_stats
with (security_invoker = true) as
select
  c.id,
  c.store_id,
  c.name,
  c.phone,
  c.whatsapp,
  c.address,
  c.created_at,
  count(o.id) filter (where o.status <> 'cancelled')                         as orders_count,
  coalesce(sum(o.total) filter (where o.status <> 'cancelled'), 0)::numeric(12,2) as total_spent,
  max(o.created_at)                                                           as last_order_at
from public.customers c
left join public.orders o on o.customer_id = c.id and o.store_id = c.store_id
group by c.id;


-- =============================================================================
-- 3. FONCTIONS D'ACCÈS (utilisées par toutes les policies)
--    SECURITY DEFINER + search_path figé : pas de récursion RLS, pas de détournement.
-- =============================================================================

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.my_store_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select id from public.stores where owner_id = auth.uid() limit 1;
$$;

-- Pour ajouter des employés plus tard, il suffira de modifier cette fonction.
create or replace function public.is_store_owner(p_store_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.stores where id = p_store_id and owner_id = auth.uid());
$$;

-- État réel d'une boutique, calculé depuis la base (et la date du jour) :
--   not_found | pending | suspended | expired | active
create or replace function public.store_state(p_store_id uuid)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare
  v_store_status text;
  v_sub          public.subscriptions%rowtype;
begin
  select status into v_store_status from public.stores where id = p_store_id;
  if not found then
    return 'not_found';
  end if;

  select * into v_sub from public.subscriptions where store_id = p_store_id;

  if v_store_status = 'suspended' or v_sub.status = 'suspended' then
    return 'suspended';
  end if;
  if v_sub.id is null or v_sub.status = 'pending' or v_store_status = 'pending' then
    return 'pending';
  end if;
  if v_sub.status = 'expired' or v_sub.end_date < public.app_today() then
    return 'expired';
  end if;
  if v_sub.start_date > public.app_today() then
    return 'pending';      -- abonnement qui démarre plus tard
  end if;
  return 'active';
end;
$$;

create or replace function public.store_is_active(p_store_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.store_state(p_store_id) = 'active';
$$;

-- Le commerçant peut gérer sa boutique UNIQUEMENT si son abonnement est actif.
create or replace function public.can_manage_store(p_store_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_store_owner(p_store_id) and public.store_is_active(p_store_id);
$$;


-- =============================================================================
-- 4. TRIGGERS
-- =============================================================================

-- ---------- updated_at automatique ---------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['profiles','stores','store_settings','subscriptions',
                           'categories','products','customers','orders']
  loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format('create trigger set_updated_at before update on public.%I
                    for each row execute function public.set_updated_at()', t);
  end loop;
end;
$$;

-- ---------- utilitaire : transformer un nom en slug -----------------------------
create or replace function public.slugify(p_text text)
returns text
language sql immutable
as $$
  select coalesce(nullif(left(trim(both '-' from regexp_replace(
           translate(lower(coalesce(p_text, '')),
                     'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ',
                     'aaaaaaceeeeiiiinooooouuuuyyoa'),
           '[^a-z0-9]+', '-', 'g')), 40), ''), 'boutique');
$$;

-- ---------- utilitaire : écrire dans le journal --------------------------------
create or replace function public.write_audit(
  p_action text, p_target_user uuid, p_store_id uuid, p_details jsonb default '{}'::jsonb)
returns void
language sql security definer set search_path = public
as $$
  insert into public.audit_logs (actor_id, action, target_user_id, store_id, details)
  values (auth.uid(), p_action, p_target_user, p_store_id, coalesce(p_details, '{}'::jsonb));
$$;

-- ---------- INSCRIPTION : tout est créé en une seule transaction ---------------
-- Déclenché par Supabase Auth à la création de l'utilisateur.
-- Le rôle est TOUJOURS 'client' : la valeur "role" envoyée par le navigateur est ignorée.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  m          jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_name     text  := left(nullif(trim(m ->> 'business_name'), ''), 120);
  v_store_id uuid;
begin
  insert into public.profiles (id, first_name, last_name, email, phone, whatsapp, role, city, country)
  values (
    new.id,
    coalesce(left(trim(m ->> 'first_name'), 80), ''),
    coalesce(left(trim(m ->> 'last_name'), 80), ''),
    coalesce(new.email, ''),
    left(nullif(trim(m ->> 'phone'), ''), 30),
    left(nullif(trim(m ->> 'whatsapp'), ''), 30),
    'client',
    left(nullif(trim(m ->> 'city'), ''), 80),
    left(nullif(trim(m ->> 'country'), ''), 80)
  );

  insert into public.stores (owner_id, name, slug, business_type, city, country)
  values (
    new.id,
    coalesce(v_name, 'Ma Boutique'),
    public.slugify(v_name) || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6),
    left(nullif(trim(m ->> 'business_type'), ''), 80),
    left(nullif(trim(m ->> 'city'), ''), 80),
    left(nullif(trim(m ->> 'country'), ''), 80)
  )
  returning id into v_store_id;

  insert into public.store_settings (store_id, contact_phone, contact_whatsapp, contact_email)
  values (v_store_id,
          left(nullif(trim(m ->> 'phone'), ''), 30),
          left(nullif(trim(m ->> 'whatsapp'), ''), 30),
          left(new.email, 120));

  insert into public.subscriptions (user_id, store_id, status)
  values (new.id, v_store_id, 'pending');

  insert into public.audit_logs (actor_id, action, target_user_id, store_id, details)
  values (new.id, 'signup', new.id, v_store_id, jsonb_build_object('business_name', v_name));

  -- prévenir les Super Admins
  insert into public.notifications (user_id, store_id, type, title, message)
  select p.id, v_store_id, 'new_signup', 'Nouvelle inscription',
         coalesce(v_name, 'Ma Boutique') || ' attend une validation.'
  from public.profiles p
  where p.role = 'admin';

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- garder l'email du profil synchronisé avec Auth ---------------------
create or replace function public.handle_user_email_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = coalesce(new.email, '') where id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.handle_user_email_change();

-- ---------- GARDE profiles : un client ne change jamais son rôle ni son email --
-- auth.uid() est null quand la requête vient du SQL Editor ou de la service_role.
create or replace function public.guard_profiles()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.role is distinct from old.role
       or new.email is distinct from old.email
       or new.id is distinct from old.id
       or new.created_at is distinct from old.created_at then
      raise exception 'FORBIDDEN_FIELD' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists guard_profiles on public.profiles;
create trigger guard_profiles before update on public.profiles
  for each row execute function public.guard_profiles();

-- ---------- GARDE stores : statut, propriétaire et slug réservés à l'admin -----
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
       or new.slug is distinct from old.slug
       or new.created_at is distinct from old.created_at then
      raise exception 'FORBIDDEN_FIELD' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists guard_stores on public.stores;
create trigger guard_stores before update on public.stores
  for each row execute function public.guard_stores();

-- ---------- GARDE orders : le commerçant ne modifie que le statut --------------
create or replace function public.guard_orders()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_status text := new.status;
begin
  if auth.uid() is not null and not public.is_admin() then
    new := old;               -- tout revient à l'ancienne valeur…
    new.status := v_status;   -- …sauf le statut
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists guard_orders on public.orders;
create trigger guard_orders before update on public.orders
  for each row execute function public.guard_orders();

-- ---------- stock remis / repris quand une commande est annulée / rétablie -----
create or replace function public.handle_order_status_stock()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  r record;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    update public.products p
       set stock = p.stock + oi.quantity
      from public.order_items oi
     where oi.order_id = new.id and oi.product_id = p.id and p.track_stock;
  elsif old.status = 'cancelled' and new.status <> 'cancelled' then
    for r in
      select p.id, p.stock, oi.quantity
        from public.order_items oi
        join public.products p on p.id = oi.product_id
       where oi.order_id = new.id and p.track_stock
         for update of p
    loop
      if r.stock < r.quantity then
        raise exception 'INSUFFICIENT_STOCK' using errcode = 'P0001';
      end if;
      update public.products set stock = stock - r.quantity where id = r.id;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists handle_order_status_stock on public.orders;
create trigger handle_order_status_stock after update of status on public.orders
  for each row execute function public.handle_order_status_stock();

-- ---------- GARDE notifications : le destinataire ne change que "lu" -----------
create or replace function public.guard_notifications()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_read boolean := new.is_read;
begin
  if auth.uid() is not null and not public.is_admin() then
    new := old;
    new.is_read := v_read;
  end if;
  return new;
end;
$$;

drop trigger if exists guard_notifications on public.notifications;
create trigger guard_notifications before update on public.notifications
  for each row execute function public.guard_notifications();

-- ---------- LIMITES DU PLAN (contrôlées par la base, pas par le JS) -----------
-- Erreurs renvoyées : PLAN_LIMIT_PRODUCTS:<max>  /  PLAN_LIMIT_CATEGORIES:<max>
create or replace function public.enforce_plan_limits()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_max   int;
  v_count int;
begin
  -- d'abord les droits : ne rien révéler du plan d'une autre boutique
  if auth.uid() is not null and not (public.can_manage_store(new.store_id) or public.is_admin()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- verrou par boutique : deux ajouts simultanés ne peuvent pas dépasser la limite
  perform pg_advisory_xact_lock(hashtext(tg_table_name || new.store_id::text));

  if tg_table_name = 'products' then
    select pl.max_products into v_max
      from public.subscriptions s join public.plans pl on pl.id = s.plan_id
     where s.store_id = new.store_id;
    if v_max is not null then
      select count(*) into v_count from public.products where store_id = new.store_id;
      if v_count >= v_max then
        raise exception 'PLAN_LIMIT_PRODUCTS:%', v_max using errcode = 'P0001';
      end if;
    end if;
  else
    select pl.max_categories into v_max
      from public.subscriptions s join public.plans pl on pl.id = s.plan_id
     where s.store_id = new.store_id;
    if v_max is not null then
      select count(*) into v_count from public.categories where store_id = new.store_id;
      if v_count >= v_max then
        raise exception 'PLAN_LIMIT_CATEGORIES:%', v_max using errcode = 'P0001';
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_plan_limits on public.products;
create trigger enforce_plan_limits before insert on public.products
  for each row execute function public.enforce_plan_limits();
drop trigger if exists enforce_plan_limits on public.categories;
create trigger enforce_plan_limits before insert on public.categories
  for each row execute function public.enforce_plan_limits();

-- ---------- AUDIT des suppressions importantes ---------------------------------
create or replace function public.audit_delete()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- suppression en cascade d'une boutique entière : rien à journaliser ici
  if not exists (select 1 from public.stores where id = old.store_id) then
    return old;
  end if;
  insert into public.audit_logs (actor_id, action, target_user_id, store_id, details)
  values (auth.uid(), 'delete_' || left(tg_table_name, -1),
          (select owner_id from public.stores where id = old.store_id),
          old.store_id,
          jsonb_build_object('id', old.id, 'name', old.name));
  return old;
end;
$$;

drop trigger if exists audit_delete on public.products;
create trigger audit_delete after delete on public.products
  for each row execute function public.audit_delete();
drop trigger if exists audit_delete on public.categories;
create trigger audit_delete after delete on public.categories
  for each row execute function public.audit_delete();


-- =============================================================================
-- 5. FONCTIONS RPC (appelées depuis le JS avec supabase.rpc(...))
-- =============================================================================

-- ---------- BOUTIQUE PUBLIQUE : une seule boutique, jamais la liste ------------
-- Renvoie { state: 'ok', store: {...}, settings: {...} }
--      ou { state: 'not_found' | 'pending' | 'suspended' | 'expired' }
create or replace function public.get_public_store(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_state text := public.store_state(p_store_id);
  v_store jsonb;
  v_set   jsonb;
begin
  if v_state <> 'active' then
    return jsonb_build_object('state', v_state);
  end if;

  select jsonb_build_object(
           'id', s.id, 'name', s.name, 'slug', s.slug, 'business_type', s.business_type,
           'description', s.description, 'slogan', s.slogan, 'address', s.address,
           'city', s.city, 'country', s.country, 'logo_url', s.logo_url,
           'favicon_url', s.favicon_url, 'banner_url', s.banner_url)
    into v_store
    from public.stores s where s.id = p_store_id;

  select jsonb_build_object(
           'theme', t.theme, 'primary_color', t.primary_color,
           'secondary_color', t.secondary_color, 'text_color', t.text_color,
           'button_color', t.button_color, 'background_color', t.background_color,
           'contact_phone', t.contact_phone, 'contact_whatsapp', t.contact_whatsapp,
           'contact_email', t.contact_email, 'opening_hours', t.opening_hours,
           'instagram_url', t.instagram_url, 'facebook_url', t.facebook_url,
           'tiktok_url', t.tiktok_url, 'currency', t.currency,
           'whatsapp_order_enabled', t.whatsapp_order_enabled,
           'delivery_info', t.delivery_info, 'delivery_fee', t.delivery_fee,
           'seo_title', t.seo_title, 'seo_description', t.seo_description)
    into v_set
    from public.store_settings t where t.store_id = p_store_id;

  return jsonb_build_object('state', 'ok', 'store', v_store, 'settings', coalesce(v_set, '{}'::jsonb));
end;
$$;

-- ---------- PASSER UNE COMMANDE (visiteur) --------------------------------------
-- p_customer : { name, phone, whatsapp, address, comment }
-- p_items    : [ { product_id, quantity }, ... ]   (le prix envoyé est ignoré)
-- Renvoie    : { order_id, order_number, subtotal, delivery_fee, total, currency, items: [...] }
create or replace function public.place_order(
  p_store_id uuid, p_customer jsonb, p_items jsonb, p_source text default 'web')
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_name     text := left(trim(coalesce(p_customer ->> 'name', '')), 120);
  v_phone    text := left(trim(coalesce(p_customer ->> 'phone', '')), 30);
  v_whatsapp text := left(nullif(trim(p_customer ->> 'whatsapp'), ''), 30);
  v_address  text := left(nullif(trim(p_customer ->> 'address'), ''), 500);
  v_comment  text := left(nullif(trim(p_customer ->> 'comment'), ''), 1000);
  v_source   text := case when p_source = 'whatsapp' then 'whatsapp' else 'web' end;
  v_owner    uuid;
  v_fee      numeric(12,2);
  v_currency text;
  v_customer uuid;
  v_order    uuid;
  v_number   int;
  v_subtotal numeric(12,2) := 0;
  v_lines    jsonb := '[]'::jsonb;
  r          record;
  p          public.products%rowtype;
begin
  if public.store_state(p_store_id) <> 'active' then
    raise exception 'STORE_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if char_length(v_name) < 1 or v_phone !~ '^[0-9+() .-]{4,30}$' then
    raise exception 'INVALID_CUSTOMER' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 50 then
    raise exception 'INVALID_ITEMS' using errcode = 'P0001';
  end if;

  -- verrou sur la boutique : numérotation des commandes sans doublon
  select owner_id into v_owner from public.stores where id = p_store_id for update;
  select delivery_fee, currency into v_fee, v_currency
    from public.store_settings where store_id = p_store_id;
  v_fee := coalesce(v_fee, 0);

  insert into public.customers (store_id, name, phone, whatsapp, address)
  values (p_store_id, v_name, v_phone, v_whatsapp, v_address)
  on conflict (store_id, phone) do update
    set name = excluded.name,
        whatsapp = coalesce(excluded.whatsapp, public.customers.whatsapp),
        address = coalesce(excluded.address, public.customers.address)
  returning id into v_customer;

  select coalesce(max(order_number), 0) + 1 into v_number
    from public.orders where store_id = p_store_id;

  insert into public.orders (store_id, order_number, customer_id, customer_name, customer_phone,
                             customer_whatsapp, customer_address, comment, source)
  values (p_store_id, v_number, v_customer, v_name, v_phone, v_whatsapp, v_address, v_comment, v_source)
  returning id into v_order;

  -- regrouper les doublons, valider les quantités
  for r in
    select (e ->> 'product_id')::uuid as product_id, sum((e ->> 'quantity')::int) as qty
      from jsonb_array_elements(p_items) e
     group by 1
  loop
    if r.product_id is null or r.qty is null or r.qty < 1 or r.qty > 999 then
      raise exception 'INVALID_ITEMS' using errcode = 'P0001';
    end if;

    -- le produit doit appartenir à CETTE boutique et être actif ; prix relu en base
    select * into p from public.products
     where id = r.product_id and store_id = p_store_id and is_active
       for update;
    if not found then
      raise exception 'PRODUCT_UNAVAILABLE' using errcode = 'P0001';
    end if;
    if p.track_stock then
      if p.stock < r.qty then
        raise exception 'INSUFFICIENT_STOCK:%', p.name using errcode = 'P0001';
      end if;
      update public.products set stock = stock - r.qty where id = p.id;
    end if;

    insert into public.order_items (order_id, store_id, product_id, product_name, unit_price, quantity, line_total)
    values (v_order, p_store_id, p.id, p.name, p.price, r.qty, p.price * r.qty);

    v_subtotal := v_subtotal + p.price * r.qty;
    v_lines := v_lines || jsonb_build_object('name', p.name, 'quantity', r.qty,
                                             'unit_price', p.price, 'line_total', p.price * r.qty);
  end loop;

  update public.orders
     set subtotal = v_subtotal, delivery_fee = v_fee, total = v_subtotal + v_fee
   where id = v_order;

  insert into public.notifications (user_id, store_id, type, title, message)
  values (v_owner, p_store_id, 'new_order', 'Nouvelle commande #' || v_number,
          v_name || ' · ' || (v_subtotal + v_fee)::text || ' ' || coalesce(v_currency, ''));

  return jsonb_build_object(
    'order_id', v_order, 'order_number', v_number, 'subtotal', v_subtotal,
    'delivery_fee', v_fee, 'total', v_subtotal + v_fee, 'currency', v_currency,
    'items', v_lines);
end;
$$;

-- ---------- ÉTAT DU COMPTE CONNECTÉ (routage après connexion) ------------------
create or replace function public.my_account_status()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_store   public.stores%rowtype;
  v_sub     public.subscriptions%rowtype;
  v_plan    public.plans%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('state', 'anonymous');
  end if;
  select * into v_profile from public.profiles where id = auth.uid();
  if not found then
    return jsonb_build_object('state', 'no_profile');
  end if;
  select * into v_store from public.stores where owner_id = auth.uid();
  select * into v_sub from public.subscriptions where store_id = v_store.id;
  select * into v_plan from public.plans where id = v_sub.plan_id;

  return jsonb_build_object(
    'user_id', v_profile.id,
    'role', v_profile.role,
    'first_name', v_profile.first_name,
    'store_id', v_store.id,
    'store_name', v_store.name,
    'state', case when v_store.id is null then 'no_store' else public.store_state(v_store.id) end,
    'suspension_reason', v_store.suspension_reason,
    'plan_id', v_plan.id,
    'plan_name', v_plan.name,
    'max_products', v_plan.max_products,
    'max_categories', v_plan.max_categories,
    'features', coalesce(v_plan.features, '[]'::jsonb),
    'start_date', v_sub.start_date,
    'end_date', v_sub.end_date,
    'days_left', case when v_sub.end_date is null then null
                      else v_sub.end_date - public.app_today() end,
    'today', public.app_today()
  );
end;
$$;

-- ---------- STATISTIQUES DU DASHBOARD COMMERÇANT -------------------------------
create or replace function public.store_dashboard_stats()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_store uuid := public.my_store_id();
begin
  if v_store is null or not public.can_manage_store(v_store) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'products',      (select count(*) from public.products where store_id = v_store),
    'out_of_stock',  (select count(*) from public.products
                       where store_id = v_store and track_stock and stock = 0),
    'categories',    (select count(*) from public.categories where store_id = v_store),
    'orders',        (select count(*) from public.orders where store_id = v_store),
    'new_orders',    (select count(*) from public.orders where store_id = v_store and status = 'new'),
    'customers',     (select count(*) from public.customers where store_id = v_store),
    'revenue',       (select coalesce(sum(total), 0) from public.orders
                       where store_id = v_store and status <> 'cancelled'),
    'revenue_delivered', (select coalesce(sum(total), 0) from public.orders
                       where store_id = v_store and status = 'delivered')
  );
end;
$$;

-- ---------- PREMIER SUPER ADMIN (SQL Editor uniquement) -------------------------
create or replace function public.promote_to_admin(p_email text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  update public.profiles set role = 'admin'
   where lower(email) = lower(trim(p_email))
  returning id into v_id;
  if v_id is null then
    raise exception 'Aucun compte avec cet email. Inscris-toi d''abord sur register.html.';
  end if;
  insert into public.audit_logs (actor_id, action, target_user_id, details)
  values (null, 'promote_admin', v_id, jsonb_build_object('email', p_email));
  return 'OK : ' || p_email || ' est maintenant Super Admin.';
end;
$$;

-- ---------- ACTIONS SUPER ADMIN (atomiques, journalisées, notifiées) -----------
create or replace function public.assert_admin()
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.notify_owner(p_store_id uuid, p_type text, p_title text, p_message text)
returns void
language sql security definer set search_path = public
as $$
  insert into public.notifications (user_id, store_id, type, title, message)
  select owner_id, id, p_type, p_title, p_message from public.stores where id = p_store_id;
$$;

-- Activer un compte : plan + dates. Fin par défaut = début + durée du plan.
create or replace function public.admin_activate(
  p_store_id uuid, p_plan_id uuid, p_start_date date default null, p_end_date date default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_plan  public.plans%rowtype;
  v_start date := coalesce(p_start_date, public.app_today());
  v_end   date;
  v_owner uuid;
begin
  perform public.assert_admin();
  select * into v_plan from public.plans where id = p_plan_id;
  if not found then raise exception 'PLAN_NOT_FOUND' using errcode = 'P0001'; end if;
  v_end := coalesce(p_end_date, v_start + v_plan.duration_days);
  if v_end < v_start then raise exception 'INVALID_DATES' using errcode = 'P0001'; end if;

  update public.stores set status = 'active', suspension_reason = null
   where id = p_store_id returning owner_id into v_owner;
  if v_owner is null then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;

  update public.subscriptions
     set plan_id = p_plan_id, status = 'active', start_date = v_start, end_date = v_end
   where store_id = p_store_id;

  perform public.write_audit('activate', v_owner, p_store_id, jsonb_build_object(
    'plan', v_plan.name, 'start_date', v_start, 'end_date', v_end));
  perform public.notify_owner(p_store_id, 'account_activated', 'Compte activé',
    'Votre abonnement ' || v_plan.name || ' est actif jusqu''au ' || to_char(v_end, 'DD/MM/YYYY') || '.');
  return jsonb_build_object('start_date', v_start, 'end_date', v_end);
end;
$$;

create or replace function public.admin_suspend(p_store_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid;
begin
  perform public.assert_admin();
  update public.stores set status = 'suspended', suspension_reason = left(nullif(trim(p_reason), ''), 500)
   where id = p_store_id returning owner_id into v_owner;
  if v_owner is null then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;
  update public.subscriptions set status = 'suspended' where store_id = p_store_id;
  perform public.write_audit('suspend', v_owner, p_store_id, jsonb_build_object('reason', p_reason));
  perform public.notify_owner(p_store_id, 'account_suspended', 'Compte suspendu',
    coalesce(nullif(trim(p_reason), ''), 'Votre compte a été suspendu.'));
end;
$$;

create or replace function public.admin_reactivate(p_store_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid;
  v_sub   public.subscriptions%rowtype;
begin
  perform public.assert_admin();
  select * into v_sub from public.subscriptions where store_id = p_store_id;
  if not found then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;

  update public.stores
     set status = case when v_sub.plan_id is null then 'pending' else 'active' end,
         suspension_reason = null
   where id = p_store_id returning owner_id into v_owner;
  update public.subscriptions
     set status = case when v_sub.plan_id is null then 'pending'
                       when v_sub.end_date < public.app_today() then 'expired'
                       else 'active' end
   where store_id = p_store_id;

  perform public.write_audit('reactivate', v_owner, p_store_id, '{}'::jsonb);
  perform public.notify_owner(p_store_id, 'account_reactivated', 'Compte réactivé',
    'Votre compte a été réactivé.');
  return public.store_state(p_store_id);
end;
$$;

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

-- Prolonger : soit de N jours (à partir de la fin actuelle, ou d'aujourd'hui si déjà expiré),
-- soit jusqu'à une date précise.
create or replace function public.admin_extend(
  p_store_id uuid, p_days int default null, p_new_end_date date default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_sub   public.subscriptions%rowtype;
  v_owner uuid;
  v_end   date;
begin
  perform public.assert_admin();
  select * into v_sub from public.subscriptions where store_id = p_store_id for update;
  if not found then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;
  if v_sub.plan_id is null then raise exception 'NOT_ACTIVATED' using errcode = 'P0001'; end if;
  if p_new_end_date is null and (p_days is null or p_days <= 0) then
    raise exception 'INVALID_DATES' using errcode = 'P0001';
  end if;

  v_end := coalesce(p_new_end_date, greatest(v_sub.end_date, public.app_today()) + p_days);
  if v_end < v_sub.start_date then raise exception 'INVALID_DATES' using errcode = 'P0001'; end if;

  update public.subscriptions
     set end_date = v_end,
         status = case when status = 'suspended' then 'suspended'
                       when v_end >= public.app_today() then 'active'
                       else 'expired' end
   where store_id = p_store_id;
  select owner_id into v_owner from public.stores where id = p_store_id;

  perform public.write_audit('extend', v_owner, p_store_id, jsonb_build_object(
    'old_end_date', v_sub.end_date, 'new_end_date', v_end, 'days', p_days));
  perform public.notify_owner(p_store_id, 'subscription_extended', 'Abonnement prolongé',
    'Votre abonnement est prolongé jusqu''au ' || to_char(v_end, 'DD/MM/YYYY') || '.');
  return jsonb_build_object('end_date', v_end);
end;
$$;

-- Modifier librement les dates (correction manuelle).
create or replace function public.admin_set_dates(p_store_id uuid, p_start_date date, p_end_date date)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_sub   public.subscriptions%rowtype;
  v_owner uuid;
begin
  perform public.assert_admin();
  select * into v_sub from public.subscriptions where store_id = p_store_id for update;
  if not found then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;
  if v_sub.plan_id is null then raise exception 'NOT_ACTIVATED' using errcode = 'P0001'; end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'INVALID_DATES' using errcode = 'P0001';
  end if;
  update public.subscriptions
     set start_date = p_start_date, end_date = p_end_date,
         status = case when status = 'suspended' then 'suspended'
                       when p_end_date >= public.app_today() then 'active'
                       else 'expired' end
   where store_id = p_store_id;
  select owner_id into v_owner from public.stores where id = p_store_id;
  perform public.write_audit('set_dates', v_owner, p_store_id, jsonb_build_object(
    'old_start_date', v_sub.start_date, 'old_end_date', v_sub.end_date,
    'new_start_date', p_start_date, 'new_end_date', p_end_date));
end;
$$;

create or replace function public.admin_change_plan(p_store_id uuid, p_plan_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_old   text;
  v_new   public.plans%rowtype;
  v_owner uuid;
begin
  perform public.assert_admin();
  select * into v_new from public.plans where id = p_plan_id;
  if not found then raise exception 'PLAN_NOT_FOUND' using errcode = 'P0001'; end if;
  select pl.name into v_old from public.subscriptions s
    left join public.plans pl on pl.id = s.plan_id where s.store_id = p_store_id;
  update public.subscriptions set plan_id = p_plan_id where store_id = p_store_id;
  if not found then raise exception 'STORE_NOT_FOUND' using errcode = 'P0001'; end if;
  select owner_id into v_owner from public.stores where id = p_store_id;
  perform public.write_audit('change_plan', v_owner, p_store_id,
    jsonb_build_object('old_plan', v_old, 'new_plan', v_new.name));
  perform public.notify_owner(p_store_id, 'plan_changed', 'Formule modifiée',
    'Votre formule est maintenant : ' || v_new.name || '.');
end;
$$;

-- Tableau de bord Super Admin
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

-- Liste des clients, paginée et filtrée côté base (jamais "tout charger").
-- p_status : null | pending | active | suspended | expired | expiring
create or replace function public.admin_list_clients(
  p_search text default null, p_status text default null,
  p_limit int default 25, p_offset int default 0)
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
    where p.role = 'client'
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

-- ---------- TÂCHE QUOTIDIENNE : expirations et rappels -------------------------
-- (La sécurité ne dépend PAS de cette tâche : store_state() compare déjà la date
--  à chaque requête. Elle sert à garder des statuts lisibles et à notifier.)
create or replace function public.run_daily_subscription_jobs()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_expired int := 0;
  v_reminded int := 0;
  r record;
begin
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

  return jsonb_build_object('expired', v_expired, 'reminders', v_reminded);
end;
$$;


-- =============================================================================
-- 6. ROW LEVEL SECURITY
-- =============================================================================

alter table public.profiles       enable row level security;
alter table public.stores         enable row level security;
alter table public.store_settings enable row level security;
alter table public.plans          enable row level security;
alter table public.subscriptions  enable row level security;
alter table public.categories     enable row level security;
alter table public.products       enable row level security;
alter table public.customers      enable row level security;
alter table public.orders         enable row level security;
alter table public.order_items    enable row level security;
alter table public.admin_notes    enable row level security;
alter table public.notifications  enable row level security;
alter table public.audit_logs     enable row level security;

-- ---------- profiles ----------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.is_admin());

-- ---------- stores ----------
-- Le propriétaire lit toujours sa boutique (pour afficher pending/suspendu/expiré),
-- mais ne la modifie que si son abonnement est actif. Les visiteurs n'y ont
-- PAS accès directement : ils passent par get_public_store().
drop policy if exists stores_select on public.stores;
create policy stores_select on public.stores for select to authenticated
  using (owner_id = auth.uid() or public.is_admin());
drop policy if exists stores_update on public.stores;
create policy stores_update on public.stores for update to authenticated
  using (public.can_manage_store(id) or public.is_admin())
  with check (public.can_manage_store(id) or public.is_admin());
drop policy if exists stores_delete on public.stores;
create policy stores_delete on public.stores for delete to authenticated
  using (public.is_admin());

-- ---------- store_settings ----------
drop policy if exists store_settings_select on public.store_settings;
create policy store_settings_select on public.store_settings for select to authenticated
  using (public.is_store_owner(store_id) or public.is_admin());
drop policy if exists store_settings_update on public.store_settings;
create policy store_settings_update on public.store_settings for update to authenticated
  using (public.can_manage_store(store_id) or public.is_admin())
  with check (public.can_manage_store(store_id) or public.is_admin());

-- ---------- plans ----------
drop policy if exists plans_select on public.plans;
create policy plans_select on public.plans for select to anon, authenticated
  using (active or public.is_admin());
drop policy if exists plans_insert on public.plans;
create policy plans_insert on public.plans for insert to authenticated
  with check (public.is_admin());
drop policy if exists plans_update on public.plans;
create policy plans_update on public.plans for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists plans_delete on public.plans;
create policy plans_delete on public.plans for delete to authenticated
  using (public.is_admin());

-- ---------- subscriptions : lecture seule ; écriture via fonctions admin -------
drop policy if exists subscriptions_select on public.subscriptions;
create policy subscriptions_select on public.subscriptions for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- ---------- categories ----------
drop policy if exists categories_select on public.categories;
create policy categories_select on public.categories for select to anon, authenticated
  using ((is_active and public.store_is_active(store_id))
         or public.can_manage_store(store_id) or public.is_admin());
drop policy if exists categories_insert on public.categories;
create policy categories_insert on public.categories for insert to authenticated
  with check (public.can_manage_store(store_id) or public.is_admin());
drop policy if exists categories_update on public.categories;
create policy categories_update on public.categories for update to authenticated
  using (public.can_manage_store(store_id) or public.is_admin())
  with check (public.can_manage_store(store_id) or public.is_admin());
drop policy if exists categories_delete on public.categories;
create policy categories_delete on public.categories for delete to authenticated
  using (public.can_manage_store(store_id) or public.is_admin());

-- ---------- products ----------
drop policy if exists products_select on public.products;
create policy products_select on public.products for select to anon, authenticated
  using ((is_active and public.store_is_active(store_id))
         or public.can_manage_store(store_id) or public.is_admin());
drop policy if exists products_insert on public.products;
create policy products_insert on public.products for insert to authenticated
  with check (public.can_manage_store(store_id) or public.is_admin());
drop policy if exists products_update on public.products;
create policy products_update on public.products for update to authenticated
  using (public.can_manage_store(store_id) or public.is_admin())
  with check (public.can_manage_store(store_id) or public.is_admin());
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete to authenticated
  using (public.can_manage_store(store_id) or public.is_admin());

-- ---------- customers (créés uniquement par place_order) ----------
drop policy if exists customers_select on public.customers;
create policy customers_select on public.customers for select to authenticated
  using (public.can_manage_store(store_id) or public.is_admin());
drop policy if exists customers_update on public.customers;
create policy customers_update on public.customers for update to authenticated
  using (public.can_manage_store(store_id) or public.is_admin())
  with check (public.can_manage_store(store_id) or public.is_admin());
drop policy if exists customers_delete on public.customers;
create policy customers_delete on public.customers for delete to authenticated
  using (public.can_manage_store(store_id) or public.is_admin());

-- ---------- orders (créées uniquement par place_order) ----------
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (public.can_manage_store(store_id) or public.is_admin());
drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders for update to authenticated
  using (public.can_manage_store(store_id) or public.is_admin())
  with check (public.can_manage_store(store_id) or public.is_admin());

-- ---------- order_items ----------
drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items for select to authenticated
  using (public.can_manage_store(store_id) or public.is_admin());

-- ---------- admin_notes : Super Admin uniquement ----------
drop policy if exists admin_notes_all on public.admin_notes;
create policy admin_notes_all on public.admin_notes for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- notifications ----------
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists notifications_delete on public.notifications;
create policy notifications_delete on public.notifications for delete to authenticated
  using (user_id = auth.uid());

-- ---------- audit_logs : lecture admin, aucune écriture directe ----------
drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (public.is_admin());


-- =============================================================================
-- 7. DROITS (explicites : on ne dépend pas des droits par défaut)
-- =============================================================================

-- Tables : les visiteurs ne voient que plans, catégories et produits (filtrés par RLS).
revoke all on all tables in schema public from anon;
grant select on public.plans, public.categories, public.products to anon;

revoke all on all tables in schema public from authenticated;
grant select, update, delete on public.profiles to authenticated;
grant select, update, delete on public.stores to authenticated;
grant select, update on public.store_settings to authenticated;
grant select, insert, update, delete on public.plans to authenticated;
grant select on public.subscriptions to authenticated;
grant select, insert, update, delete on public.categories to authenticated;
grant select, insert, update, delete on public.products to authenticated;
grant select, update, delete on public.customers to authenticated;
grant select, update on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant select, insert, update, delete on public.admin_notes to authenticated;
grant select, update, delete on public.notifications to authenticated;
grant select on public.audit_logs to authenticated;
grant select on public.customer_stats to authenticated;

grant all on all tables in schema public to service_role;

-- Fonctions : rien par défaut, puis uniquement ce qui doit être appelable.
revoke execute on all functions in schema public from public, anon, authenticated;

-- utilisées par les policies (doivent être exécutables par les rôles concernés)
grant execute on function public.app_today()              to anon, authenticated;
grant execute on function public.is_admin()               to anon, authenticated;
grant execute on function public.my_store_id()            to authenticated;
grant execute on function public.is_store_owner(uuid)     to anon, authenticated;
grant execute on function public.store_state(uuid)        to anon, authenticated;
grant execute on function public.store_is_active(uuid)    to anon, authenticated;
grant execute on function public.can_manage_store(uuid)   to anon, authenticated;

-- RPC publiques
grant execute on function public.get_public_store(uuid)               to anon, authenticated;
grant execute on function public.place_order(uuid, jsonb, jsonb, text) to anon, authenticated;

-- RPC utilisateur connecté (les fonctions admin vérifient elles-mêmes is_admin())
grant execute on function public.my_account_status()                   to authenticated;
grant execute on function public.store_dashboard_stats()               to authenticated;
grant execute on function public.admin_activate(uuid, uuid, date, date) to authenticated;
grant execute on function public.admin_suspend(uuid, text)             to authenticated;
grant execute on function public.admin_reactivate(uuid)                to authenticated;
grant execute on function public.admin_delete_client(uuid)             to authenticated;
grant execute on function public.admin_extend(uuid, int, date)         to authenticated;
grant execute on function public.admin_set_dates(uuid, date, date)     to authenticated;
grant execute on function public.admin_change_plan(uuid, uuid)         to authenticated;
grant execute on function public.admin_stats()                         to authenticated;
grant execute on function public.admin_list_clients(text, text, int, int) to authenticated;

-- promote_to_admin, run_daily_subscription_jobs, write_audit, notify_owner,
-- assert_admin, handle_new_user… : NON exécutables depuis le navigateur.

grant execute on all functions in schema public to service_role;


-- =============================================================================
-- 8. STORAGE
--    Chemin imposé : <store_id>/<fichier> (logos, banners, products)
--                    <user_id>/<fichier>  (avatars)
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('logos',    'logos',    true, 1048576, array['image/png','image/jpeg','image/webp']),
  ('banners',  'banners',  true, 3145728, array['image/png','image/jpeg','image/webp']),
  ('products', 'products', true, 2097152, array['image/png','image/jpeg','image/webp']),
  ('avatars',  'avatars',  true, 1048576, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Fichiers de boutique : le propriétaire actif gère uniquement le dossier de SA boutique.
drop policy if exists store_files_select on storage.objects;
create policy store_files_select on storage.objects for select to authenticated
  using (bucket_id in ('logos', 'banners', 'products')
         and ((storage.foldername(name))[1] = public.my_store_id()::text or public.is_admin()));

drop policy if exists store_files_insert on storage.objects;
create policy store_files_insert on storage.objects for insert to authenticated
  with check (bucket_id in ('logos', 'banners', 'products')
              and (((storage.foldername(name))[1] = public.my_store_id()::text
                    and public.can_manage_store(public.my_store_id()))
                   or public.is_admin()));

drop policy if exists store_files_update on storage.objects;
create policy store_files_update on storage.objects for update to authenticated
  using (bucket_id in ('logos', 'banners', 'products')
         and (((storage.foldername(name))[1] = public.my_store_id()::text
               and public.can_manage_store(public.my_store_id()))
              or public.is_admin()))
  with check (bucket_id in ('logos', 'banners', 'products')
              and (((storage.foldername(name))[1] = public.my_store_id()::text
                    and public.can_manage_store(public.my_store_id()))
                   or public.is_admin()));

drop policy if exists store_files_delete on storage.objects;
create policy store_files_delete on storage.objects for delete to authenticated
  using (bucket_id in ('logos', 'banners', 'products')
         and (((storage.foldername(name))[1] = public.my_store_id()::text
               and public.can_manage_store(public.my_store_id()))
              or public.is_admin()));

-- Avatars : chaque utilisateur gère son propre dossier.
drop policy if exists avatar_files_select on storage.objects;
create policy avatar_files_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatar_files_insert on storage.objects;
create policy avatar_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatar_files_update on storage.objects;
create policy avatar_files_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatar_files_delete on storage.objects;
create policy avatar_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);


-- =============================================================================
-- 9. PLANS D'EXEMPLE (modifiables ensuite depuis admin.html)
-- =============================================================================

insert into public.plans (name, description, price, duration_days, max_products, max_categories, features, sort_order)
select * from (values
  ('Basic',    'Pour démarrer : catalogue, commandes et WhatsApp.',            2500.00, 30, 100,  20,
     '["orders","whatsapp"]'::jsonb, 1),
  ('Pro',      'Pour grandir : plus de produits, statistiques, personnalisation.', 5000.00, 30, 500,  100,
     '["orders","whatsapp","stats","custom_theme"]'::jsonb, 2),
  ('Business', 'Sans limite : produits illimités et statistiques avancées.',   9000.00, 30, null, null,
     '["orders","whatsapp","stats","advanced_stats","custom_theme"]'::jsonb, 3)
) as v(name, description, price, duration_days, max_products, max_categories, features, sort_order)
where not exists (select 1 from public.plans);


-- =============================================================================
-- 10. TÂCHE PLANIFIÉE (pg_cron) : tous les jours à 00:05 UTC
--     Si pg_cron n'est pas disponible, le script continue : la sécurité n'en dépend pas.
-- =============================================================================

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('daily-subscription-jobs', '5 0 * * *',
                          'select public.run_daily_subscription_jobs()');
  else
    raise notice 'pg_cron indisponible : activez-le dans Database > Extensions pour les rappels automatiques.';
  end if;
exception when others then
  raise notice 'pg_cron non configuré (%). Activez-le dans Database > Extensions puis relancez ce bloc.', sqlerrm;
end;
$$;

-- =============================================================================
-- FIN. Étape suivante : select public.promote_to_admin('ton-email@exemple.com');
-- =============================================================================
