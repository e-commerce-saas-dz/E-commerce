# SaaS E-commerce multi-boutiques

Plateforme SaaS permettant à des commerçants de créer et gérer leur propre boutique en ligne.
Chaque boutique a son compte, ses produits, ses commandes, ses clients, son thème et son URL unique :

```
https://votre-domaine.com/shop.html?store=UUID-DE-LA-BOUTIQUE
```

**Technologies :** HTML, CSS, JavaScript Vanilla, Supabase (Auth, Database, Storage, RLS), PWA.
**Aucun** Node.js, npm, build, framework ou serveur backend. Les fichiers se déposent tels quels sur un hébergement statique.

---

## Sommaire

1. [Créer le projet Supabase](#1-créer-le-projet-supabase)
2. [Configurer l'authentification](#2-configurer-lauthentification)
3. [Exécuter le SQL](#3-exécuter-le-sql)
4. [Buckets de stockage](#4-buckets-de-stockage)
5. [Policies (sécurité)](#5-policies-sécurité)
6. [Ajouter SUPABASE_URL](#6-et-7-ajouter-supabase_url-et-supabase_anon_key)
7. [Ajouter SUPABASE_ANON_KEY](#6-et-7-ajouter-supabase_url-et-supabase_anon_key)
8. [Créer le premier Super Admin](#8-créer-le-premier-super-admin)
9. [Lancer en local](#9-lancer-en-local)
10. [Déployer sur GitHub Pages](#10-déployer-sur-github-pages)
11. [Déployer sur Cloudflare Pages](#11-déployer-sur-cloudflare-pages)
12. [Vérifier l'isolation multi-tenant](#12-vérifier-lisolation-multi-tenant)

---

## Structure

```
/
├── index.html           Landing page + tarifs (lus depuis Supabase)
├── register.html        Inscription (crée compte + boutique + abonnement "pending")
├── login.html           Connexion, mot de passe oublié, nouveau mot de passe
├── pending.html         Compte en attente / suspendu / expiré
├── dashboard.html       Dashboard commerçant (installable en PWA)
├── admin.html           Dashboard Super Admin
├── shop.html            Boutique publique : shop.html?store=UUID
├── manifest.json        PWA
├── service-worker.js    PWA (ne met jamais en cache les données Supabase)
├── robots.txt
├── supabase/
│   ├── schema.sql       Tout le SQL : tables, RLS, fonctions, Storage, plans
│   └── tests.sql        70 tests d'isolation multi-tenant (clientA / clientB / admin / visiteur)
└── assets/
    ├── app.js           Configuration + fonctions partagées
    ├── app.css          Design system partagé
    └── icons/           Icônes PWA
```

Chaque page contient son propre HTML, CSS et JavaScript. Seuls la configuration et les fonctions communes
(`getCurrentUser`, `showToast`, `getStoreUrl`…) sont partagées dans `assets/app.js`, pour n'avoir qu'un seul endroit à modifier.

---

## 1. Créer le projet Supabase

1. Créez un compte sur [supabase.com](https://supabase.com) puis **New project**.
2. Choisissez un nom, un mot de passe de base de données (gardez-le) et la région la plus proche de vos clients (par ex. *Frankfurt* pour l'Algérie).
3. Attendez la fin de la création (1 à 2 minutes).

## 2. Configurer l'authentification

Dans **Authentication** :

1. **Sign In / Providers → Email** : activé, avec **Confirm email** activé (recommandé : évite les faux comptes).
   Le mot de passe minimum peut rester à 6 ; le formulaire impose déjà 8 caractères.
2. **URL Configuration** :
   - **Site URL** : l'adresse de votre site, par ex. `https://monsaas.com/` (ou `https://votre-compte.github.io/E-commerce/`).
   - **Redirect URLs** : ajoutez `https://monsaas.com/login.html` et `https://monsaas.com/login.html?mode=reset`
     (ainsi que `http://localhost:8080/login.html` pour les tests en local).
3. *(Optionnel)* **Emails** : personnalisez les textes en français (confirmation, mot de passe oublié).
   Le service d'email intégré de Supabase est limité à quelques emails par heure : pour la production,
   configurez un SMTP (Brevo, Resend, Mailjet…) dans **Authentication → Emails → SMTP Settings**.

## 3. Exécuter le SQL

1. Ouvrez **SQL Editor → New query**.
2. Copiez-collez **tout** le contenu de [`supabase/schema.sql`](supabase/schema.sql), puis **Run**.
3. Le script est ré-exécutable : le relancer ne casse rien et ne supprime aucune donnée.

Il crée : les 13 tables, les relations, index et contraintes, les fonctions de sécurité, les triggers
(création automatique de la boutique à l'inscription, limites de plan, audit), les policies RLS,
les buckets de stockage et 3 formules d'exemple (Basic, Pro, Business, modifiables depuis l'admin).

**Tâche quotidienne (recommandé)** : le script programme avec `pg_cron` une tâche qui passe chaque nuit les abonnements
dépassés en « expiré » et envoie les rappels (30, 7 et 2 jours). Si le message *pg_cron indisponible* apparaît :
**Database → Extensions → pg_cron → Enable**, puis relancez le SQL.
La sécurité n'en dépend pas : un abonnement dont la date est dépassée est bloqué immédiatement par la base, même sans cette tâche.

## 4. Buckets de stockage

Rien à faire : `schema.sql` crée les 4 buckets publics en lecture :

| Bucket | Contenu | Taille max |
|---|---|---|
| `logos` | logos et favicons | 1 Mo |
| `banners` | bannières | 3 Mo |
| `products` | images produits et catégories | 2 Mo |
| `avatars` | photos de profil | 1 Mo |

Les fichiers sont rangés dans un dossier au nom de la boutique (`<store_id>/fichier.webp`).
Les images sont redimensionnées et converties en WebP dans le navigateur avant l'envoi.
Vérifiez dans **Storage** que les 4 buckets apparaissent.

## 5. Policies (sécurité)

Rien à faire non plus : elles sont dans `schema.sql`. Pour contrôler : **Database → Tables** : chaque table affiche
« RLS enabled ». Résumé :

- un commerçant ne lit et ne modifie **que** les lignes de **sa** boutique, et uniquement si son abonnement est actif ;
- un compte en attente, suspendu ou expiré ne peut **rien** lire ni écrire dans ses produits, commandes et clients ;
- un visiteur ne voit que les produits et catégories **actifs** des boutiques **actives** ; il ne peut pas lister les boutiques ;
- les commandes ne peuvent être créées que par la fonction `place_order`, qui recalcule les prix en base ;
- le rôle `admin` ne peut jamais être obtenu depuis le navigateur ; les notes internes et le journal ne sont visibles que par l'admin.

## 6 et 7. Ajouter SUPABASE_URL et SUPABASE_ANON_KEY

Dans Supabase : **Project Settings → API** (ou **Data API**). Copiez **Project URL** et la clé **anon public**.

Ouvrez `assets/app.js` et remplacez en haut du fichier :

```js
const SUPABASE_URL = "YOUR_SUPABASE_URL";            // ex. "https://abcd1234.supabase.co"
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";  // la clé "anon public"
const APP_NAME = "MonSaaS";                           // nom affiché de votre plateforme
const PUBLIC_BASE_URL = "";                           // optionnel, ex. "https://monsaas.com/"
const SUPPORT_WHATSAPP = "";                          // ex. "213550000000" (affiché aux comptes en attente)
```

> ⚠️ N'utilisez **jamais** la clé `service_role` dans ces fichiers : elle contourne toute la sécurité.
> La clé `anon` peut être publique : c'est la RLS qui protège les données.

`PUBLIC_BASE_URL` sert à générer les liens et QR codes des boutiques. Laissé vide, il est calculé automatiquement
à partir de l'adresse du site. Renseignez-le si vous utilisez un domaine personnalisé.

Pensez aussi à remplacer « MonSaaS » dans `manifest.json` (nom de l'application installée).

## 8. Créer le premier Super Admin

1. Inscrivez-vous normalement sur `register.html` avec votre email, puis confirmez l'email.
2. Dans **SQL Editor**, exécutez :

```sql
select public.promote_to_admin('votre-email@exemple.com');
```

3. Reconnectez-vous : vous arrivez sur `admin.html`.

Cette fonction n'est exécutable que depuis le SQL Editor (droits du propriétaire du projet), jamais depuis le site.

## 9. Lancer en local

Les pages doivent être servies en `http://` (pas en double-cliquant sur le fichier, à cause de la connexion et du service worker).
N'importe quel petit serveur statique convient, par exemple :

```bash
# Python (préinstallé sur macOS / Linux)
python3 -m http.server 8080
```

ou l'extension **Live Server** de VS Code. Puis ouvrez <http://localhost:8080>.

## 10. Déployer sur GitHub Pages

1. Poussez les fichiers sur votre dépôt GitHub (branche `main`).
2. **Settings → Pages → Build and deployment** : *Source* = **Deploy from a branch**, *Branch* = `main`, dossier `/ (root)`.
3. Après une minute, le site est disponible sur `https://<organisation>.github.io/<dépôt>/`.
4. Ajoutez cette URL dans Supabase (**Authentication → URL Configuration**, étape 2).

## 11. Déployer sur Cloudflare Pages

1. Sur [dash.cloudflare.com](https://dash.cloudflare.com) : **Workers & Pages → Create → Pages → Connect to Git**.
2. Sélectionnez le dépôt.
3. Réglages de build :
   - **Framework preset** : *None*
   - **Build command** : *(vide)*
   - **Build output directory** : `/`
4. **Save and Deploy**. Chaque push sur `main` redéploie automatiquement.
5. *(Optionnel)* **Custom domains** pour utiliser `monsaas.com`.
6. Ajoutez l'URL finale dans Supabase (étape 2) et, si besoin, dans `PUBLIC_BASE_URL`.

Après chaque mise en ligne importante, incrémentez `CACHE_VERSION` dans `service-worker.js` pour que les téléphones
qui ont installé l'application récupèrent la nouvelle version.

## 12. Vérifier l'isolation multi-tenant

Dans **SQL Editor**, exécutez [`supabase/tests.sql`](supabase/tests.sql) **après** `schema.sql`. Il crée temporairement
clientA, clientB, un compte en attente et un admin, simule chacun exactement comme le fait l'API Supabase, vérifie 70 règles
(clientA ne voit jamais storeB, un compte suspendu ou expiré est bloqué, les prix des commandes sont recalculés, etc.),
puis supprime toutes les données de test. Toutes les lignes du résultat doivent afficher `ok = true`.

---

## Fonctionnement

### Parcours

```
Visiteur → index.html → register.html → compte "pending" → pending.html
Super Admin → admin.html → appelle / WhatsApp → paiement manuel → Activer (plan + dates)
Commerçant → login.html → dashboard.html → personnalise, ajoute ses produits → partage son lien / QR code
Client final → shop.html?store=UUID → panier → commande (ou WhatsApp) → arrive dans le dashboard du commerçant
```

### Statuts d'un compte

| Statut | Dashboard | Boutique publique |
|---|---|---|
| `pending` | bloqué, page d'attente | « Cette boutique est actuellement indisponible. » |
| `active` | accessible | visible |
| `suspended` | bloqué, raison affichée | « Cette boutique est temporairement indisponible. » |
| `expired` (date dépassée) | bloqué | « Cette boutique est actuellement indisponible. » |

Le comportement d'une boutique expirée est défini à un seul endroit : la fonction SQL `get_public_store`.

### Fonctions SQL appelées par le site

| Fonction | Qui | Rôle |
|---|---|---|
| `get_public_store(id)` | visiteur | renvoie UNE boutique publique et son état |
| `place_order(...)` | visiteur | crée la commande, recalcule les prix, gère le stock |
| `my_account_status()` | connecté | rôle, état, plan, jours restants (routage) |
| `store_dashboard_stats()` | commerçant | chiffres du tableau de bord |
| `admin_activate / admin_suspend / admin_reactivate / admin_extend / admin_set_dates / admin_change_plan` | admin | actions sur les comptes (journalisées et notifiées) |
| `admin_stats()` / `admin_list_clients(...)` | admin | statistiques et liste paginée |

### Limites connues de la V1

- **Aperçus de lien** : le titre, la description et le favicon de chaque boutique sont appliqués par JavaScript.
  Google les indexe correctement, mais WhatsApp, Facebook ou Instagram n'exécutent pas le JavaScript et affichent
  le titre générique de `shop.html` dans l'aperçu. Une évolution future (petite fonction Cloudflare ou Supabase Edge
  Function) pourra générer ces balises côté serveur.
- **Commandes anonymes** : un robot pourrait envoyer de fausses commandes. Si cela arrive, ajouter Cloudflare Turnstile
  (anti-robot gratuit) au formulaire de commande.
- **Slugs** : la colonne `stores.slug` est déjà remplie et unique, prête pour des URLs `/shop/ma-boutique`
  ou `ma-boutique.monsaas.com` ; seule `getStoreUrl()` sera à modifier.

### Évolutions prévues par l'architecture

Paiement en ligne, domaines personnalisés, employés (il suffira de modifier la fonction SQL `is_store_owner`),
coupons, avis, factures, emails, SMS, WhatsApp API, application mobile.
