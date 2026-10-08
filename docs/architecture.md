# SaaS E-commerce multi-boutiques : Phase 0 (analyse et architecture)

Statut : **proposition à valider**. Aucun code ni SQL n'est écrit tant que tu n'as pas validé ce document.

---

## 1. Analyse du projet existant

**Fichiers présents : aucun.** L'espace du projet est vide et aucun dépôt GitHub n'est rattaché au projet.

J'ai parcouru la liste de tes dépôts GitHub : aucun ne correspond clairement à ce SaaS. Les plus proches sont `DZcouture` / `DZcoutureAdmin` (boutique mono-marchand, probablement) et `Gestion-de-stockage`. Je pars donc d'un **projet neuf**.

> Si tu as déjà des fichiers (une maquette, un ancien projet Supabase, un SQL existant), donne-moi le dépôt ou le dossier local et je refais l'analyse avant la Phase 1.

**Architecture actuelle :** inexistante. **Problèmes détectés :** aucun dans l'existant ; en revanche, la spécification contient quelques points qui méritent une décision (section 11) et quelques pièges techniques que j'ai corrigés dans la proposition (section 10).

---

## 2. Principes retenus

| Principe | Traduction concrète |
|---|---|
| Simple | HTML + CSS + JS Vanilla, Supabase via CDN, zéro build, zéro npm. |
| Sécurisé | La sécurité est **dans la base** (RLS, contraintes, fonctions SQL). Le JS ne fait que de l'affichage et du confort. |
| Maintenable | Une poignée de fonctions JS claires, partagées entre les pages. Pas d'abstraction inutile. |
| Évolutif | Chaque table métier porte un `store_id`. Toutes les règles d'accès passent par 3 ou 4 fonctions SQL : les changer suffit pour ajouter employés, sous-domaines, paiement en ligne, etc. |

**Supabase est le seul backend.** Quand une opération doit être atomique ou sécurisée (inscription, passer une commande, activer un compte), elle est écrite en **fonction SQL Postgres** (appelée via `supabase.rpc(...)`). Ce n'est pas un serveur personnalisé : c'est du SQL stocké dans Supabase, copié-collé depuis le SQL Editor.

---

## 3. Architecture cible des fichiers

```
/
├── index.html            Landing page + tarifs (plans actifs lus depuis Supabase)
├── login.html            Connexion + "mot de passe oublié" + redirection selon rôle/statut
├── register.html         Inscription (12 champs)
├── pending.html          Page d'état du compte : en attente / suspendu / expiré
├── dashboard.html        Dashboard commerçant (SPA légère : sections affichées/masquées)
├── admin.html            Dashboard Super Admin
├── shop.html             Boutique publique ?store=UUID (+ panier + checkout)
├── manifest.json
├── service-worker.js
├── README.md
├── supabase/
│   ├── schema.sql        Phase 1 : tout le SQL à coller dans le SQL Editor
│   └── tests.sql         Phase 1/12 : scénarios clientA/clientB vérifiables en SQL
└── assets/
    ├── app.js            Config Supabase + fonctions partagées (voir ci-dessous)
    ├── app.css           Design system partagé (variables, boutons, cards, modales, toasts)
    └── icons/            Icônes PWA (192, 512, maskable) + favicon
```

**Pourquoi `assets/app.js` et `assets/app.css` ?** Tu demandes HTML + CSS + JS dans le même fichier quand c'est possible, et c'est ce que je fais pour tout ce qui est propre à une page. Mais la config Supabase et les fonctions communes (`getCurrentUser`, `showToast`, `formatPrice`, `getStoreUrl`…) sont utilisées par 7 pages. Sans fichier partagé, il faudrait remplacer `SUPABASE_URL` dans 7 fichiers et corriger chaque bug 7 fois. C'est le seul cas où la séparation est « réellement nécessaire ». **(Décision D1)**

Contenu de `assets/app.js` (environ 300 lignes) :

```js
// ===== CONFIGURATION (à remplacer) =====
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
const APP_BASE_URL = window.location.origin + window.location.pathname.replace(/[^/]*$/, "");
// =======================================

const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

getCurrentUser()  getCurrentProfile()  getCurrentStore()  getMySubscription()
checkAuth()  checkAdmin()  checkSubscription()  redirectByStatus()
getStoreUrl(storeId)  copyStoreUrl()  shareStore()
showToast()  openModal()  closeModal()  confirmAction()
formatPrice()  formatDate()  daysLeft()  escapeHtml()
uploadImage(bucket, storeId, file)
```

Les fonctions spécifiques (`loadProducts`, `saveProduct`, `deleteProduct`, `loadOrders`…) restent dans `dashboard.html`. Celles du panier restent dans `shop.html`.

`APP_BASE_URL` est calculé automatiquement : `getStoreUrl()` fonctionne aussi bien sur `monsaas.com/` que sur `tchinkou.github.io/mon-repo/`, sans URL écrite en dur.

**Bibliothèques externes (uniquement celles qui apportent une vraie valeur) :**

| Lib | Usage | Poids |
|---|---|---|
| `@supabase/supabase-js@2` (version figée, pas `@latest`) | Auth, DB, Storage | ~50 Ko gz |
| `qrcode-generator` (CDN) | QR code de la boutique | ~20 Ko |

Rien d'autre. Icônes en SVG inline, pas de framework CSS.

> `@latest` est risqué : une future v3 de supabase-js pourrait casser le site du jour au lendemain sans que tu aies touché à rien. Je fige une version précise.

---

## 4. Schéma Supabase complet

### 4.1 Vue d'ensemble des relations

```
auth.users (géré par Supabase Auth)
   │ 1─1
   ▼
profiles ─────────────── 1─N ── notifications
   │ 1─1 (owner_id)            admin_notes (N, sur un profil client, écrites par l'admin)
   ▼
stores ──1─1── store_settings
   │  ──1─1── subscriptions ──N─1── plans
   │
   ├──1─N── categories ──1─N── products (category_id nullable)
   ├──1─N── products
   ├──1─N── customers ──1─N── orders
   └──1─N── orders ──1─N── order_items ──N─1── products (nullable si produit supprimé)

audit_logs (journal global, lecture admin uniquement)
```

**Règle d'or : toute table métier porte un `store_id NOT NULL` avec clé étrangère vers `stores(id) ON DELETE CASCADE`**, et un index sur `store_id`. C'est ce qui rend l'isolation à la fois simple et rapide avec des centaines de boutiques.

### 4.2 Tables

Types : `uuid` = identifiant généré par `gen_random_uuid()`, `timestamptz` = date + heure UTC.

#### `profiles` : un par utilisateur
| Colonne | Type | Notes |
|---|---|---|
| id | uuid PK | **= `auth.users.id`** (FK, cascade). Voir D2. |
| first_name, last_name | text not null | |
| email | text not null | copié depuis Auth, non modifiable par le client |
| phone, whatsapp | text | |
| role | text not null default `'client'` | check `in ('client','admin')`. **Jamais modifiable par un client** (trigger). |
| city, country | text | |
| created_at, updated_at | timestamptz | `updated_at` maintenu par trigger |

#### `stores` : une par commerçant (V1)
| Colonne | Type | Notes |
|---|---|---|
| id | uuid PK default gen_random_uuid() | **L'identifiant public de la boutique** (`?store=`) |
| owner_id | uuid not null → profiles(id) | `unique` en V1 (1 boutique par compte), retirable plus tard |
| name | text not null | |
| slug | text unique | généré à l'inscription (`ma-boutique-4f2a`), inutilisé en V1, prêt pour `/shop/slug` ou sous-domaine |
| business_type | text | vêtements, parfums… |
| description, slogan | text | |
| address, city, country | text | |
| logo_url, favicon_url, banner_url | text | URLs Supabase Storage |
| status | text not null default `'pending'` | `pending / active / suspended`. Modifiable **uniquement** par l'admin. |
| suspension_reason | text | ex. « Compte suspendu pour non-paiement. » |
| created_at, updated_at | timestamptz | |

#### `store_settings` : 1-1 avec stores
| Colonne | Type | Notes |
|---|---|---|
| store_id | uuid PK → stores(id) | |
| theme | text default `'modern'` | `classic / modern / minimal / elegant` |
| primary_color, secondary_color, text_color, button_color, background_color | text | hex, validés par `check` regex `^#[0-9a-fA-F]{6}$` (empêche l'injection CSS) |
| contact_phone, contact_whatsapp, contact_email | text | |
| opening_hours | text | texte libre en V1 (ex. « Sam–Jeu 9h–19h ») |
| instagram_url, facebook_url, tiktok_url | text | |
| currency | text default `'DZD'` | voir D5 |
| whatsapp_order_enabled | boolean default false | « Commander via WhatsApp » |
| delivery_info | text | |
| delivery_fee | numeric(12,2) default 0 | |
| seo_title, seo_description | text | |
| extra | jsonb default `'{}'` | réserve pour les paramètres futurs sans migration |
| updated_at | timestamptz | |

#### `plans`
| Colonne | Type | Notes |
|---|---|---|
| id | uuid PK | |
| name | text not null | Basic, Pro, Business… |
| description | text | |
| price | numeric(12,2) not null | |
| duration_days | int not null | ex. 30, 365 |
| max_products | int | **null = illimité** |
| max_categories | int | null = illimité |
| features | jsonb default `'[]'` | ex. `["whatsapp","stats","custom_theme"]` |
| active | boolean default true | un plan inactif n'est plus proposé mais reste valable pour les abonnés existants |
| sort_order | int default 0 | ordre d'affichage |
| created_at | timestamptz | |

Le SQL insère 3 plans d'exemple (Basic 100, Pro 500, Business illimité) que tu peux modifier depuis l'admin.

#### `subscriptions` : 1 par boutique
| Colonne | Type | Notes |
|---|---|---|
| id | uuid PK | |
| user_id | uuid not null → profiles(id) | |
| store_id | uuid not null unique → stores(id) | une ligne « courante » par boutique ; l'historique est dans `audit_logs` |
| plan_id | uuid → plans(id) | null tant que pending |
| status | text not null default `'pending'` | `pending / active / suspended / expired` |
| start_date, end_date | date | |
| created_at, updated_at | timestamptz | |

Contrainte : `check (status <> 'active' or (plan_id is not null and start_date is not null and end_date is not null and end_date >= start_date))`. Un abonnement actif sans dates est impossible.

#### `categories`
id, **store_id**, name, description, image_url, sort_order, is_active, created_at, updated_at. Unique `(store_id, name)`.

#### `products`
| Colonne | Type | Notes |
|---|---|---|
| id | uuid PK | |
| store_id | uuid not null | |
| category_id | uuid → categories(id) on delete set null | + contrainte : la catégorie doit appartenir au **même** store (FK composite `(category_id, store_id)`) |
| name | text not null | |
| description | text | |
| price | numeric(12,2) not null check ≥ 0 | |
| old_price | numeric(12,2) | prix barré (promo) |
| stock | int not null default 0 check ≥ 0 | |
| sku | text | référence ; unique `(store_id, sku)` |
| image_url | text | image principale |
| images | text[] default '{}' | images supplémentaires (max 8, check) |
| is_featured | boolean default false | |
| is_active | boolean default true | |
| created_at, updated_at | timestamptz | |

Index : `(store_id)`, `(store_id, is_active)`, `(store_id, category_id)`.

#### `customers` : clients finaux d'une boutique
id, **store_id**, name, phone, whatsapp, address, orders_count, total_spent, last_order_at, created_at. Unique `(store_id, phone)` : le même téléphone dans deux boutiques donne deux clients distincts (isolation). Les compteurs sont mis à jour par la fonction de commande.

#### `orders`
| Colonne | Type | Notes |
|---|---|---|
| id | uuid PK | |
| store_id | uuid not null | |
| order_number | int | numéro lisible par boutique (#1, #2…), unique `(store_id, order_number)` |
| customer_id | uuid → customers(id) | |
| customer_name, customer_phone, customer_whatsapp, customer_address | text | copie figée au moment de la commande |
| comment | text | |
| subtotal, delivery_fee, total | numeric(12,2) | **calculés côté base**, jamais envoyés par le navigateur |
| status | text default `'new'` | `new / confirmed / shipped / delivered / cancelled` |
| source | text default `'web'` | `web / whatsapp` |
| created_at, updated_at | timestamptz | |

#### `order_items`
id, order_id, **store_id** (dénormalisé pour une RLS simple et rapide), product_id (nullable, `on delete set null`), product_name, unit_price, quantity (check > 0), line_total. Le nom et le prix sont **copiés** : supprimer ou modifier un produit ne change pas les anciennes commandes.

#### `admin_notes`
id, **target_user_id** → profiles, store_id, author_id, content, created_at. **Aucune policy pour les clients** : invisible même en lecture.

#### `notifications`
id, user_id, store_id, type (`account_activated / account_suspended / subscription_expiring / subscription_expired / new_order`), title, message, is_read, created_at. Créées uniquement par les fonctions SQL ; le client peut seulement les lire et les marquer comme lues.

#### `audit_logs`
id, actor_id (null = système), action (`signup / activate / suspend / reactivate / change_plan / extend / delete_product / delete_category …`), target_user_id, store_id, details jsonb (ancien/nouveau plan, anciennes/nouvelles dates, raison…), created_at. **Écriture uniquement par fonctions SQL, lecture admin uniquement, jamais modifiable ni supprimable.**

### 4.3 Storage

| Bucket | Public en lecture | Chemin imposé | Taille max | Types |
|---|---|---|---|---|
| `logos` | oui | `{store_id}/…` | 1 Mo | png, jpg, webp, svg* |
| `banners` | oui | `{store_id}/…` | 3 Mo | png, jpg, webp |
| `products` | oui | `{store_id}/…` | 2 Mo | png, jpg, webp |
| `avatars` | oui | `{user_id}/…` | 1 Mo | png, jpg, webp |

\* SVG à discuter : un SVG peut contenir du script. Je propose de **l'exclure** par défaut (le favicon peut être un PNG).

Policies Storage : un utilisateur ne peut **écrire, remplacer ou supprimer** que dans le dossier dont le premier segment est **sa** boutique (`(storage.foldername(name))[1] = id de sa boutique`). Pas de policy de listing : on peut afficher une image dont on connaît l'URL, pas lister les fichiers des autres. Le navigateur redimensionne les images avant envoi (canvas, ~1200 px, WebP) pour rester léger.

---

## 5. Sécurité : RLS et fonctions SQL

### 5.1 Les fonctions d'accès (le cœur du multi-tenant)

Toutes les policies s'appuient sur ces fonctions (`SECURITY DEFINER`, `search_path` figé, pour éviter les récursions RLS et les détournements) :

```sql
is_admin()                    -- profiles.role = 'admin' pour auth.uid()
my_store_id()                 -- id de la boutique dont auth.uid() est propriétaire
is_store_owner(store_id)      -- store_id = my_store_id()
store_is_active(store_id)     -- store.status = 'active'
                              -- ET subscription.status = 'active'
                              -- ET today <= end_date      ← expiration réelle, côté base
can_manage_store(store_id)    -- is_store_owner(store_id) AND store_is_active(store_id)
```

**Expiration automatique :** `store_is_active()` compare la date du jour à `end_date` **à chaque requête**. Un compte dont la date est dépassée est bloqué immédiatement par la base, même si personne n'a encore mis à jour le statut, et même si le JS du navigateur est modifié. En complément, une tâche planifiée quotidienne (`pg_cron`, intégré à Supabase) passe les statuts à `expired` pour que l'admin voie des chiffres justes, et crée les notifications « expire dans 7 jours / 2 jours / expiré ». **(D4 : fuseau horaire)**

**Évolution « employés » :** demain, ajouter une table `store_members` ne demandera de modifier que `is_store_owner()`. Aucune policy à réécrire.

### 5.2 Policies par table

Légende : **anon** = visiteur non connecté, **owner** = commerçant propriétaire, **admin** = Super Admin.

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| profiles | soi-même ; admin | ❌ (trigger d'inscription) | soi-même, **sans** role/email (trigger de garde) ; admin | admin |
| stores | owner (toujours, pour afficher l'état pending/suspendu) ; admin. **anon : aucun accès direct** (voir 5.3) | ❌ (trigger d'inscription) | owner actif, **sans** status/owner_id/id ; admin | admin |
| store_settings | owner ; admin | ❌ (trigger) | owner actif ; admin | ❌ |
| plans | tout le monde : plans actifs ; admin : tous | admin | admin | admin |
| subscriptions | owner (lecture seule) ; admin | ❌ (trigger) | **admin uniquement** (via fonctions) | ❌ |
| categories | anon : actives + boutique active ; owner ; admin | owner actif (+ limite du plan) | owner actif | owner actif |
| products | anon : actifs + boutique active ; owner ; admin | owner actif (+ limite du plan) | owner actif | owner actif |
| customers | owner actif ; admin | ❌ (fonction de commande) | owner actif | owner actif |
| orders | owner actif ; admin | ❌ **anon n'insère jamais directement** (voir 5.4) | owner actif : statut uniquement | ❌ (annulation via statut) |
| order_items | owner actif ; admin | ❌ | ❌ | ❌ |
| admin_notes | admin | admin | admin | admin |
| notifications | destinataire ; admin | ❌ (fonctions) | destinataire : `is_read` uniquement | destinataire |
| audit_logs | admin | ❌ (fonctions) | ❌ | ❌ |

« owner actif » = `can_manage_store(store_id)` : un compte **pending, suspendu ou expiré ne peut rien lire ni écrire** dans ses produits/commandes/clients, même en appelant l'API Supabase à la main. Il peut seulement lire son profil, sa boutique et son abonnement pour afficher la bonne page d'état.

### 5.3 Boutique publique sans exposer la liste des boutiques

Si on autorisait `anon` à lire la table `stores`, n'importe qui pourrait appeler l'API avec `select *` et récupérer la liste complète de tes commerçants, même si ton JS ne le fait jamais. Je propose donc :

```sql
get_public_store(p_store_id uuid) returns jsonb
```

Elle renvoie **une seule** boutique et son état :

| Cas | Réponse | Affichage dans shop.html |
|---|---|---|
| UUID invalide ou inconnu | `{ "state": "not_found" }` | « Cette boutique n'existe pas ou n'est plus disponible. » |
| Boutique suspendue | `{ "state": "suspended" }` | « Cette boutique est temporairement indisponible. » |
| Abonnement expiré | `{ "state": "expired" }` | « Cette boutique est actuellement indisponible. » |
| Boutique en attente | `{ "state": "pending" }` | traité comme indisponible |
| Active | `{ "state": "ok", "store": {…champs publics…}, "settings": {…} }` | boutique complète |

Seuls les champs publics sont renvoyés (jamais `owner_id`, les données du profil ou l'abonnement). Le comportement « boutique expirée » est centralisé dans cette fonction : le modifier plus tard (ex. vitrine visible sans commande possible) se fait à un seul endroit.

Les produits et catégories sont ensuite lus normalement avec `.eq("store_id", storeId)`, la RLS garantissant qu'un produit d'une boutique suspendue ou expirée n'est jamais renvoyé.

### 5.4 Passage de commande sécurisé

Laisser un visiteur anonyme faire `insert` dans `orders` permettrait d'envoyer un total à 1 DA, ou de créer des commandes dans n'importe quelle boutique. Je propose :

```sql
place_order(p_store_id uuid, p_customer jsonb, p_items jsonb, p_source text) returns jsonb
```

En une seule transaction, elle :
1. vérifie que la boutique est active ;
2. relit **chaque produit en base** (il doit appartenir à **cette** boutique et être actif) ;
3. recalcule les prix et le total (le prix envoyé par le navigateur est ignoré) ;
4. vérifie le stock et le décrémente ;
5. crée ou met à jour le client (`customers`, par téléphone, dans cette boutique) ;
6. crée `orders` + `order_items` avec `store_id = p_store_id` ;
7. crée une notification « nouvelle commande » pour le commerçant ;
8. renvoie le numéro de commande.

Garde-fous : 50 lignes max par commande, quantité max par ligne, longueur max des champs texte. Le mode « Commander via WhatsApp » appelle **aussi** `place_order` (source `whatsapp`) puis ouvre `wa.me` avec le message pré-rempli : la commande n'est jamais perdue même si le client ne finit pas sur WhatsApp. **(D6)**

> Limite connue en V1 : un robot peut envoyer de fausses commandes (spam). Si cela arrive, on ajoutera Cloudflare Turnstile (anti-robot gratuit), sans changer l'architecture.

### 5.5 Limites du plan, côté base

Un trigger `BEFORE INSERT` sur `products` compte les produits de la boutique et les compare à `plans.max_products` (null = illimité). S'il est dépassé, la base refuse avec un code d'erreur précis que le JS traduit en :
« Votre abonnement actuel autorise 100 produits. Veuillez changer de formule pour ajouter davantage de produits. »
Même principe pour `categories` / `max_categories`. Le bouton est aussi désactivé dans l'interface, mais ce n'est que du confort.

### 5.6 Rôle admin impossible à usurper

- `role` n'est **jamais** lu depuis le formulaire d'inscription : le trigger d'inscription force `'client'`.
- Un trigger de garde sur `profiles` refuse toute modification de `role` si l'appelant n'est pas déjà admin.
- `is_admin()` lit la base, pas le JWT ni le JS.
- **Premier Super Admin** : tu t'inscris normalement sur `register.html`, puis tu exécutes **une** ligne dans le SQL Editor (qui tourne avec les droits du propriétaire du projet, inaccessible depuis le navigateur) :
  ```sql
  select promote_to_admin('ton-email@exemple.com');
  ```
  Cette fonction n'est **pas** exécutable par `anon` ni `authenticated`.
- La `service_role` key n'apparaît nulle part dans le frontend.

### 5.7 Actions admin = fonctions SQL atomiques

Chaque action du Super Admin est une fonction qui vérifie `is_admin()`, modifie les tables concernées, écrit dans `audit_logs` et crée la notification, **dans la même transaction** :

```
admin_activate(store_id, plan_id, start_date, end_date)
admin_suspend(store_id, reason)
admin_reactivate(store_id)
admin_extend(store_id, days | new_end_date)
admin_change_plan(store_id, plan_id)
admin_stats()            -- totaux, nouveaux, pending, actifs, suspendus, expirés, bientôt expirés
admin_list_clients(search, status, limit, offset)   -- liste paginée (pas de "tout charger")
```

---

## 6. Système multi-tenant (résumé)

```
                 ┌──────────────── même application, même base ───────────────┐
Client A ──auth──►  auth.uid() = A  ──► my_store_id() = AAA ──► lignes store_id = AAA
Client B ──auth──►  auth.uid() = B  ──► my_store_id() = BBB ──► lignes store_id = BBB
Visiteur ──anon──►  get_public_store(X) + produits actifs de X uniquement
Admin    ──auth──►  is_admin() = true ──► toutes les lignes
                 └─────────────────────────────────────────────────────────────┘
```

Trois niveaux, comme demandé :
1. **JS** : `dashboard.html` ne lit **jamais** `?store=` ; il fait `getCurrentStore()` = utilisateur connecté → profil → boutique. Toutes les requêtes filtrent `.eq("store_id", …)` côté Supabase.
2. **Supabase Auth** : chaque requête porte le JWT de l'utilisateur ; `auth.uid()` ne peut pas être falsifié.
3. **RLS** : même si A modifie le JS et demande `store_id = BBB`, la base renvoie **0 ligne** (lecture) ou une **erreur** (écriture).

---

## 7. Système d'URL unique

- L'UUID de la boutique (`stores.id`) est généré par Postgres à l'inscription : non devinable, non lié au nom.
- URL publique : `getStoreUrl(storeId)` → `{APP_BASE_URL}shop.html?store={uuid}`. C'est la **seule** fonction qui construit cette URL (copier, partager, QR code, admin).
- `shop.html` : lit `?store=`, vérifie le format UUID en JS (évite un appel inutile), appelle `get_public_store`, puis charge catégories et produits filtrés par ce `store_id`.
- **Évolution slug** : la colonne `slug` existe déjà et est unique. Le jour où tu passes à `/shop/ma-boutique` ou `ma-boutique.monsaas.com`, on ajoute `get_public_store_by_slug(slug)` qui retrouve l'UUID ; tout le reste (produits, commandes, RLS) continue de fonctionner par `store_id`. `getStoreUrl()` change à un seul endroit.

**SEO, point honnête :** `shop.html` met à jour `<title>`, `meta description`, favicon et balises Open Graph en JS depuis Supabase. Google exécute le JS, donc le titre et la description seront bien indexés. En revanche, **les aperçus de lien WhatsApp, Facebook et Instagram n'exécutent pas le JS** : ils afficheront le titre générique de `shop.html`, pas le logo de la boutique. Corriger ça demande un petit traitement côté serveur (par exemple une fonction Cloudflare Pages ou une Edge Function Supabase) : je le note pour une évolution future, hors V1.

---

## 8. Flux utilisateurs

### 8.1 Inscription

```
register.html
  └─ supabase.auth.signUp({ email, password, options: { data: { first_name, last_name,
       business_name, phone, whatsapp, business_type, city, country } } })
        │
        ▼  trigger SQL on auth.users (atomique, SECURITY DEFINER)
        ├─ profiles        (role forcé à 'client')
        ├─ stores          (UUID généré, slug généré, status 'pending')
        ├─ store_settings  (thème et couleurs par défaut)
        ├─ subscriptions   (status 'pending', sans plan)
        ├─ audit_logs      ('signup')
        └─ notification pour l'admin (« nouvelle demande »)
  └─ redirection pending.html :
       « Votre compte est en attente de validation. »
       « Notre équipe vous contactera dans les prochaines 24 heures afin de confirmer votre abonnement. »
```

Pourquoi un trigger plutôt que 4 `insert` depuis le JS : si la confirmation d'email est activée, l'utilisateur n'a **pas encore de session** juste après l'inscription, donc les `insert` JS seraient refusés par la RLS. Et si l'un des 4 échouait, on aurait un compte à moitié créé. Le trigger fait tout ou rien, et l'utilisateur n'a jamais le droit d'insérer lui-même une boutique ou un abonnement. **(D3)**

### 8.2 Connexion et routage

```
login.html → signInWithPassword
  └─ redirectByStatus():
       admin                        → admin.html
       client + pending             → pending.html (état « en attente »)
       client + suspended           → pending.html (état « suspendu » + raison)
       client + expired / date passée → pending.html (état « expiré »)
       client + active              → dashboard.html
```

Chaque page protégée refait la vérification au chargement (`checkAuth()` / `checkAdmin()` / `checkSubscription()`). Ce n'est **pas** la sécurité (la RLS l'est) : c'est ce qui évite d'afficher un dashboard vide à un compte bloqué. Un seul `pending.html` gère les 3 états, déterminés depuis la base et non depuis l'URL.

### 8.3 Cycle commercial (Super Admin)

```
Nouvelle inscription → admin.html (badge « pending », bouton Appeler tel: / WhatsApp wa.me)
  → contact, paiement manuel
  → « Activer » : choix du plan, date de début, date de fin (pré-remplie = début + duration_days)
  → admin_activate() : subscription active + store active + audit + notification client
  → le client se connecte → dashboard.html
Ensuite : Suspendre (avec raison) / Réactiver / Prolonger / Changer de plan / Notes internes
```

Messages d'expiration côté client (calculés depuis `end_date`, la date du jour faisant foi côté base) :

| Jours restants | Message |
|---|---|
| > 7 | « Votre abonnement expire dans N jours. » (badge neutre) |
| 3 à 7 | « Votre abonnement expire dans N jours. » (badge orange) |
| 1 à 2 | « Attention, votre abonnement expire bientôt. » (badge rouge) |
| ≤ 0 | « Votre abonnement a expiré. » → accès bloqué |

### 8.4 Commande d'un visiteur

```
shop.html?store=AAA → panier (localStorage, clé "cart_AAA" : un panier par boutique, jamais mélangé)
  → checkout : nom, téléphone, WhatsApp, adresse, commentaire
  → place_order(AAA, …) → numéro de commande affiché
  → (si activé) ouverture WhatsApp avec le message récapitulatif
  → la commande apparaît dans dashboard.html du commerçant A uniquement
```

### 8.5 Écrans

**admin.html** : Statistiques · Clients (tableau Client / Commerce / Téléphone / Plan / Statut / Début / Expiration / Actions, avec recherche, filtre par statut et pagination) · Fiche client (infos, commerce, abonnement, boutique + URL, notes internes, historique d'audit) · Boutiques · Plans (CRUD) · Journal.

**dashboard.html** : Tableau de bord · Ma boutique (URL, voir, copier, partager, QR) · Produits · Catégories · Commandes · Clients · Personnalisation (identité, contact, réseaux, couleurs, thème avec aperçu) · Paramètres · Abonnement. Mobile-first : sidebar repliée en menu bas/hamburger sur téléphone, tableaux transformés en cartes sous 640 px.

**Thèmes** : un seul `shop.html`. Les 4 thèmes sont des jeux de variables CSS (`--primary-color`, `--secondary-color`, `--background-color`, `--text-color`, `--button-color`, plus rayons, typographie, espacements) appliqués via `data-theme="modern"` sur `<html>` ; les couleurs personnalisées du commerçant écrasent ensuite les variables.

**PWA** : `manifest.json` (nom, icônes, `display: standalone`, `start_url: dashboard.html`). Le `service-worker.js` met en cache **uniquement** les fichiers statiques (HTML, CSS, JS, icônes) et **ne met jamais en cache** les réponses Supabase ni les tokens : pas de données d'une boutique servies à la mauvaise personne, pas de données périmées.

---

## 9. Phases de développement

| Phase | Livrable | Critère de « terminé » |
|---|---|---|
| **1. Supabase** | `supabase/schema.sql` (tables, contraintes, index, fonctions, triggers, RLS, Storage, plans d'exemple, cron) + `supabase/tests.sql` | Le SQL s'exécute sans erreur sur une base vierge **et** une seconde fois (idempotent). Je l'exécute sur un PostgreSQL local avec les rôles `anon`/`authenticated` simulés et je joue les scénarios clientA/clientB/admin/anon avant de te le livrer. |
| 2. Auth | `assets/app.js`, `assets/app.css`, `register.html`, `login.html`, déconnexion, session persistante, mot de passe oublié | Inscription → toutes les lignes créées ; connexion → bonne redirection |
| 3. Pending | `pending.html` (3 états) | Compte pending/suspendu/expiré bloqué côté UI et côté base |
| 4. Super Admin | `admin.html` | Activer, suspendre, réactiver, prolonger, changer de plan, notes, audit |
| 5. Dashboard | `dashboard.html` : coquille, tableau de bord, abonnement, ma boutique, QR, paramètres | |
| 6. Boutique publique | `shop.html` + isolation | Les 5 états (ok / inconnue / suspendue / expirée / pending) |
| 7. Produits | CRUD produits et catégories, images, stock, limites de plan | |
| 8. Commandes | Panier, checkout, `place_order`, WhatsApp, statuts, clients | |
| 9. Personnalisation | Thèmes, couleurs, logo, bannière, infos | |
| 10. PWA | manifest, service worker, icônes | Installable sur Android et iOS |
| 11. SEO | title, meta, OG, favicon dynamiques | |
| 12. Tests | Scénarios multi-tenant complets (section 74) + README final | |

Après chaque phase : test, correction, vérification sécurité et responsive, compte rendu, puis **j'attends ton accord** avant la suivante.

**Où vivra le code ?** Je te propose de créer un dépôt GitHub dédié (ex. `Tchinkou/saas-ecommerce`) : historique propre, déploiement GitHub Pages / Cloudflare Pages direct, et tu peux relire chaque phase. **(D7)**

---

## 10. Pièges de la spécification que la proposition corrige

| Spécification | Risque | Correction proposée |
|---|---|---|
| `supabase-js@latest` | Une mise à jour majeure casse le site sans action de ta part | Version figée |
| Créer profil + boutique + abonnement depuis le JS après `signUp` | Refusé par la RLS si confirmation d'email activée ; compte à moitié créé en cas d'erreur ; un utilisateur pourrait s'auto-créer un abonnement | Trigger SQL atomique |
| Lecture directe de `stores` par les visiteurs | N'importe qui peut lister toutes tes boutiques via l'API | Fonction `get_public_store(id)` |
| Insertion directe des commandes par les visiteurs | Prix et total falsifiables, commandes dans n'importe quelle boutique | Fonction `place_order` qui recalcule tout |
| `stores.status` et `subscriptions.status` en double | Les deux peuvent se contredire | Seules les fonctions admin les modifient, toujours ensemble ; l'accès vérifie les deux + la date |
| Expiration gérée en JS | Contournable | Date vérifiée dans `store_is_active()` à chaque requête + cron quotidien |
| Couleurs libres en texte | Injection CSS dans la boutique publique | Contrainte hex en base + échappement HTML de tous les textes affichés (`escapeHtml`) |
| Logos SVG | Un SVG peut contenir du script | PNG/JPG/WebP uniquement |
| `profiles.id` **et** `profiles.user_id` | Deux identifiants pour la même chose | `profiles.id = auth.users.id` (D2) |

---

## 11. Décisions à valider avant la Phase 1

| # | Question | Ma recommandation |
|---|---|---|
| D1 | Fichiers partagés `assets/app.js` + `assets/app.css` en plus des pages ? | **Oui** (sinon config et fonctions copiées dans 7 fichiers) |
| D2 | `profiles.id` = id Supabase Auth, sans colonne `user_id` séparée ? | **Oui** |
| D3 | Confirmation d'email obligatoire à l'inscription ? | **Oui** (évite les faux comptes) |
| D4 | Fuseau horaire pour les dates d'expiration ? | **Africa/Algiers** (je suppose l'Algérie vu CIB/Edahabia, à confirmer) |
| D5 | Devise par défaut ? | **DZD**, modifiable par boutique |
| D6 | Commande WhatsApp : enregistrer aussi la commande dans Supabase ? | **Oui** |
| D7 | Créer un nouveau dépôt GitHub pour le code ? | **Oui**, `Tchinkou/saas-ecommerce` (ou le nom que tu veux) |
| D8 | Boutique « pending » (pas encore activée) : visible publiquement ? | **Non**, affichée comme indisponible |
| D9 | Décrémenter le stock automatiquement à la commande ? | **Oui**, et le remettre si la commande est annulée |

Réponds simplement « OK pour tout » ou indique les numéros à changer, et je démarre la Phase 1 (le SQL complet).
