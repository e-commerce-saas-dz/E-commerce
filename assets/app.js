/* =============================================================================
   APP.JS : configuration + fonctions partagées par toutes les pages.
   Ce fichier ne contient AUCUNE règle de sécurité : la sécurité est dans
   Supabase (RLS, policies, fonctions SQL). Ici, on ne fait que de l'affichage.
   ============================================================================= */

// ============================ CONFIGURATION ==================================
// Remplacer ces deux valeurs (Supabase → Project Settings → API).
// N'utiliser QUE la clé publique "anon". JAMAIS la clé "service_role".
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";

// Nom affiché de la plateforme.
const APP_NAME = "MonSaaS";

// Optionnel : URL publique du site (ex. "https://monsaas.com/").
// Laisser vide pour la calculer automatiquement depuis l'adresse actuelle.
const PUBLIC_BASE_URL = "";

// Numéro WhatsApp de l'équipe commerciale (format international sans +), affiché aux comptes en attente.
const SUPPORT_WHATSAPP = "";
// =============================================================================

const APP_BASE_URL = PUBLIC_BASE_URL
  ? PUBLIC_BASE_URL.replace(/\/?$/, "/")
  : window.location.origin + window.location.pathname.replace(/[^/]*$/, "");

const IS_CONFIGURED = !SUPABASE_URL.startsWith("YOUR_") && !SUPABASE_ANON_KEY.startsWith("YOUR_");

// Client Supabase unique pour toute l'application.
const sb = IS_CONFIGURED
  ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    })
  : null;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/* ----------------------------- Session / compte ----------------------------- */

async function getCurrentUser() {
  const { data, error } = await sb.auth.getSession();
  if (error) throw error;
  return data.session ? data.session.user : null;
}

async function getCurrentProfile() {
  const user = await getCurrentUser();
  if (!user) return null;
  const { data, error } = await sb.from("profiles").select("*").eq("id", user.id).single();
  if (error) throw error;
  return data;
}

// La boutique vient TOUJOURS de l'utilisateur connecté, jamais de l'URL.
async function getCurrentStore() {
  const user = await getCurrentUser();
  if (!user) return null;
  const { data, error } = await sb.from("stores").select("*").eq("owner_id", user.id).maybeSingle();
  if (error) throw error;
  return data;
}

// État complet du compte calculé par la base : rôle, état, plan, jours restants…
async function getAccountStatus() {
  const { data, error } = await sb.rpc("my_account_status");
  if (error) throw error;
  return data;
}

function pageForStatus(status) {
  if (!status || status.state === "anonymous") return "login.html";
  if (status.role === "admin") return "admin.html";
  if (status.state === "active") return "dashboard.html";
  return "pending.html";
}

async function redirectByStatus() {
  const status = await getAccountStatus();
  window.location.replace(pageForStatus(status));
}

// Page protégée : renvoie vers login.html si personne n'est connecté.
async function checkAuth() {
  if (!IS_CONFIGURED) { showConfigError(); return null; }
  const user = await getCurrentUser();
  if (!user) { window.location.replace("login.html"); return null; }
  return user;
}

// Page admin : confort d'affichage uniquement, la base refuse de toute façon.
async function checkAdmin() {
  const user = await checkAuth();
  if (!user) return null;
  const status = await getAccountStatus();
  if (status.role !== "admin") { window.location.replace(pageForStatus(status)); return null; }
  return status;
}

// Dashboard client : uniquement si l'abonnement est actif.
async function checkSubscription() {
  const user = await checkAuth();
  if (!user) return null;
  const status = await getAccountStatus();
  if (status.role === "admin") { window.location.replace("admin.html"); return null; }
  if (status.state !== "active") { window.location.replace("pending.html"); return null; }
  return status;
}

async function logout() {
  try { await sb.auth.signOut(); } catch (e) { console.error(e); }
  window.location.replace("login.html");
}

/* ----------------------------- URL de boutique ------------------------------ */

// SEUL endroit où l'URL publique d'une boutique est construite.
function getStoreUrl(storeId) {
  return APP_BASE_URL + "shop.html?store=" + encodeURIComponent(storeId);
}

async function copyText(text, okMessage) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (e) {
    const ta = document.createElement("textarea");
    ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); } catch (_) { /* rien */ }
    ta.remove();
  }
  showToast(okMessage || "Copié.", "success");
}

function copyStoreUrl(storeId) {
  return copyText(getStoreUrl(storeId), "Lien de la boutique copié.");
}

async function shareStore(storeId, storeName) {
  const url = getStoreUrl(storeId);
  if (navigator.share) {
    try { await navigator.share({ title: storeName || "Ma boutique", text: storeName || "", url }); return; }
    catch (e) { if (e && e.name === "AbortError") return; }
  }
  copyStoreUrl(storeId);
}

function whatsappLink(phone, message) {
  const digits = String(phone || "").replace(/[^\d]/g, "").replace(/^00/, "");
  return "https://wa.me/" + digits + (message ? "?text=" + encodeURIComponent(message) : "");
}

function telLink(phone) {
  return "tel:" + String(phone || "").replace(/[^\d+]/g, "");
}

/* ----------------------------- Formatage ------------------------------------ */

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// N'autorise que des URLs http(s) (empêche les liens "javascript:").
function safeUrl(url) {
  if (!url || typeof url !== "string") return "";
  try {
    const u = new URL(url, window.location.href);
    return (u.protocol === "https:" || u.protocol === "http:") ? u.href : "";
  } catch (e) { return ""; }
}

function formatPrice(amount, currency = "DZD") {
  const n = Number(amount || 0);
  const formatted = new Intl.NumberFormat("fr-FR", {
    minimumFractionDigits: Number.isInteger(n) ? 0 : 2,
    maximumFractionDigits: 2,
  }).format(n);
  return formatted + " " + (currency === "DZD" ? "DA" : currency);
}

function formatDate(value) {
  if (!value) return "—";
  const d = typeof value === "string" && value.length === 10 ? new Date(value + "T00:00:00") : new Date(value);
  if (isNaN(d)) return "—";
  return d.toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric" });
}

function formatDateTime(value) {
  if (!value) return "—";
  const d = new Date(value);
  return d.toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric" })
    + " " + d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
}

// Message d'expiration à partir des jours restants (calculés par la base).
function expiryMessage(daysLeft) {
  if (daysLeft === null || daysLeft === undefined) return { text: "", level: "info" };
  if (daysLeft < 0) return { text: "Votre abonnement a expiré.", level: "danger" };
  if (daysLeft === 0) return { text: "Votre abonnement expire aujourd'hui.", level: "danger" };
  if (daysLeft <= 2) return { text: "Attention, votre abonnement expire bientôt.", level: "danger" };
  if (daysLeft <= 7) return { text: `Votre abonnement expire dans ${daysLeft} jours.`, level: "warning" };
  return { text: `Votre abonnement expire dans ${daysLeft} jours.`, level: "info" };
}

const STATE_LABELS = {
  active: ["Actif", "success"],
  pending: ["En attente", "warning"],
  suspended: ["Suspendu", "danger"],
  expired: ["Expiré", "danger"],
  not_found: ["Introuvable", ""],
};
function stateBadge(state) {
  const [label, kind] = STATE_LABELS[state] || [state, ""];
  return `<span class="badge ${kind ? "badge-" + kind : ""}">${escapeHtml(label)}</span>`;
}

const ORDER_STATUS = {
  new: ["Nouvelle", "info"],
  confirmed: ["Confirmée", "primary"],
  shipped: ["Expédiée", "warning"],
  delivered: ["Livrée", "success"],
  cancelled: ["Annulée", "danger"],
};
function orderBadge(status) {
  const [label, kind] = ORDER_STATUS[status] || [status, ""];
  return `<span class="badge badge-${kind}">${escapeHtml(label)}</span>`;
}

/* ----------------------------- Erreurs -------------------------------------- */

// Traduit les erreurs techniques en messages compréhensibles (jamais de détail technique).
function friendlyError(error) {
  const msg = String((error && (error.message || error.error_description)) || error || "");
  let m;
  if ((m = msg.match(/PLAN_LIMIT_PRODUCTS:(\d+)/)))
    return `Votre abonnement actuel autorise ${m[1]} produits. Veuillez changer de formule pour ajouter davantage de produits.`;
  if ((m = msg.match(/PLAN_LIMIT_CATEGORIES:(\d+)/)))
    return `Votre abonnement actuel autorise ${m[1]} catégories. Veuillez changer de formule pour en ajouter davantage.`;
  if ((m = msg.match(/INSUFFICIENT_STOCK:?(.*)/)))
    return m[1] ? `Stock insuffisant pour « ${m[1].trim()} ».` : "Stock insuffisant.";
  if (msg.includes("PRODUCT_UNAVAILABLE")) return "Un produit de votre panier n'est plus disponible.";
  if (msg.includes("STORE_UNAVAILABLE")) return "Cette boutique ne prend pas de commandes pour le moment.";
  if (msg.includes("INVALID_CUSTOMER")) return "Vérifiez votre nom et votre numéro de téléphone.";
  if (msg.includes("INVALID_DATES")) return "Les dates saisies ne sont pas valides.";
  if (msg.includes("NOT_ACTIVATED")) return "Ce compte doit d'abord être activé.";
  if (msg.includes("FORBIDDEN") || msg.includes("row-level security") || msg.includes("permission denied"))
    return "Action non autorisée.";
  if (msg.includes("Invalid login credentials")) return "Email ou mot de passe incorrect.";
  if (msg.includes("Email not confirmed")) return "Veuillez d'abord confirmer votre email (vérifiez votre boîte de réception).";
  if (msg.includes("User already registered") || msg.includes("already been registered"))
    return "Un compte existe déjà avec cet email.";
  if (msg.includes("Password should be")) return "Le mot de passe doit contenir au moins 8 caractères.";
  if (msg.includes("rate limit") || msg.includes("For security purposes"))
    return "Trop de tentatives. Patientez quelques instants puis réessayez.";
  if (msg.includes("duplicate key") && msg.includes("sku")) return "Cette référence existe déjà dans votre boutique.";
  if (msg.includes("duplicate key") && msg.includes("categories")) return "Une catégorie porte déjà ce nom.";
  if (msg.includes("Failed to fetch") || msg.includes("NetworkError")) return "Connexion impossible. Vérifiez votre réseau.";
  return "Une erreur est survenue.";
}

function handleError(error, fallback) {
  console.error(error);
  const message = friendlyError(error);
  showToast(message === "Une erreur est survenue." && fallback ? fallback : message, "error");
}

function showConfigError() {
  document.body.innerHTML = `
    <div class="auth-page"><div class="card auth-card">
      <h2>Configuration requise</h2>
      <p class="muted">Renseignez <code>SUPABASE_URL</code> et <code>SUPABASE_ANON_KEY</code>
      dans <code>assets/app.js</code> (voir README.md).</p>
    </div></div>`;
}

/* ----------------------------- UI : toasts / modales ------------------------ */

function showToast(message, type = "info", duration = 3500) {
  let box = document.querySelector(".toasts");
  if (!box) {
    box = document.createElement("div");
    box.className = "toasts";
    box.setAttribute("role", "status");
    box.setAttribute("aria-live", "polite");
    document.body.appendChild(box);
  }
  const t = document.createElement("div");
  t.className = "toast" + (type === "success" ? " toast-success" : type === "error" ? " toast-error" : "");
  t.textContent = message;
  box.appendChild(t);
  setTimeout(() => t.remove(), duration);
}

// openModal({ title, body (HTML), size, onOpen(modalEl) }) → renvoie l'élément de la modale.
function openModal({ title = "", body = "", size = "", onOpen } = {}) {
  closeModal();
  const backdrop = document.createElement("div");
  backdrop.className = "modal-backdrop";
  backdrop.innerHTML = `
    <div class="modal ${size === "lg" ? "modal-lg" : ""}" role="dialog" aria-modal="true" aria-label="${escapeHtml(title)}">
      <div class="modal-header">
        <h2>${escapeHtml(title)}</h2>
        <button class="btn btn-ghost btn-icon" data-close aria-label="Fermer">${icon("x")}</button>
      </div>
      <div class="modal-body">${body}</div>
    </div>`;
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop || e.target.closest("[data-close]")) closeModal();
  });
  document.body.appendChild(backdrop);
  document.body.style.overflow = "hidden";
  const modal = backdrop.querySelector(".modal");
  const first = modal.querySelector("input, select, textarea");
  if (first && window.matchMedia("(min-width: 640px)").matches) first.focus();
  if (onOpen) onOpen(modal);
  return modal;
}

function closeModal() {
  document.querySelectorAll(".modal-backdrop").forEach((m) => m.remove());
  document.body.style.overflow = "";
}

document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeModal(); });

// Confirmation "Êtes-vous sûr ?" → Promise<boolean>
function confirmAction(message, { confirmText = "Confirmer", danger = true } = {}) {
  return new Promise((resolve) => {
    let answered = false;
    const modal = openModal({
      title: "Êtes-vous sûr ?",
      body: `<p>${escapeHtml(message)}</p>
        <div class="modal-footer">
          <button class="btn" data-answer="no">Annuler</button>
          <button class="btn ${danger ? "btn-danger-solid" : "btn-primary"}" data-answer="yes">${escapeHtml(confirmText)}</button>
        </div>`,
    });
    const backdrop = modal.parentElement;
    const observer = new MutationObserver(() => {
      if (!document.body.contains(backdrop) && !answered) { answered = true; observer.disconnect(); resolve(false); }
    });
    observer.observe(document.body, { childList: true });
    modal.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-answer]");
      if (!btn) return;
      answered = true; observer.disconnect();
      closeModal();
      resolve(btn.dataset.answer === "yes");
    });
  });
}

// Désactive un bouton pendant une opération asynchrone.
async function withBusy(button, fn) {
  if (button) { button.disabled = true; button.setAttribute("aria-busy", "true"); }
  try { return await fn(); }
  finally { if (button) { button.disabled = false; button.removeAttribute("aria-busy"); } }
}

function formData(form) {
  const data = {};
  new FormData(form).forEach((v, k) => { data[k] = typeof v === "string" ? v.trim() : v; });
  form.querySelectorAll('input[type="checkbox"][name]').forEach((c) => { data[c.name] = c.checked; });
  return data;
}

/* ----------------------------- Images (Storage) ----------------------------- */

// Redimensionne l'image dans le navigateur (WebP, côté max 1200 px) avant envoi.
function resizeImage(file, maxSize = 1200, quality = 0.82) {
  return new Promise((resolve, reject) => {
    if (!file.type.startsWith("image/")) return reject(new Error("Fichier non image"));
    const img = new Image();
    const url = URL.createObjectURL(file);
    img.onload = () => {
      const scale = Math.min(1, maxSize / Math.max(img.width, img.height));
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext("2d").drawImage(img, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("Conversion impossible"))), "image/webp", quality);
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("Image illisible")); };
    img.src = url;
  });
}

// bucket : logos | banners | products | avatars ; folderId : store_id (ou user_id pour avatars)
async function uploadImage(bucket, folderId, file, maxSize = 1200) {
  const blob = await resizeImage(file, maxSize);
  const path = `${folderId}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.webp`;
  const { error } = await sb.storage.from(bucket).upload(path, blob, {
    contentType: "image/webp", cacheControl: "31536000", upsert: false,
  });
  if (error) throw error;
  return sb.storage.from(bucket).getPublicUrl(path).data.publicUrl;
}

/* ----------------------------- QR code -------------------------------------- */

const QR_LIB_URL = "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js";

function loadScript(src) {
  return new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${src}"]`)) return resolve();
    const s = document.createElement("script");
    s.src = src; s.onload = resolve; s.onerror = reject;
    document.head.appendChild(s);
  });
}

// Renvoie une image PNG (data URL) du QR code de l'URL donnée.
async function makeQrDataUrl(text, cellSize = 8) {
  await loadScript(QR_LIB_URL);
  const qr = window.qrcode(0, "M");
  qr.addData(text);
  qr.make();
  return qr.createDataURL(cellSize, cellSize * 2);
}

/* ----------------------------- PWA ------------------------------------------ */

function registerServiceWorker() {
  if ("serviceWorker" in navigator && location.protocol !== "file:") {
    navigator.serviceWorker.register("service-worker.js").catch((e) => console.error(e));
  }
}

/* ----------------------------- Icônes (SVG inline) -------------------------- */

const ICONS = {
  home: '<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
  store: '<path d="M3 9l1.5-5h15L21 9M3 9v11h18V9M3 9a3 3 0 0 0 6 0 3 3 0 0 0 6 0 3 3 0 0 0 6 0M9 20v-6h6v6"/>',
  box: '<path d="M21 8 12 3 3 8v8l9 5 9-5zM3 8l9 5 9-5M12 13v8"/>',
  tag: '<path d="M20.6 13.4 13.4 20.6a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8zM7.5 7.5h.01"/>',
  cart: '<path d="M3 3h2l2.4 12.2a2 2 0 0 0 2 1.6h8.2a2 2 0 0 0 2-1.6L21 7H6M9 21h.01M18 21h.01"/>',
  users: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM22 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8"/>',
  palette: '<path d="M12 22a10 10 0 1 1 10-10c0 2.8-2.2 4-4 4h-2a2 2 0 0 0-1 3.7A1.5 1.5 0 0 1 12 22zM7.5 10.5h.01M10.5 7h.01M15 7.5h.01M17 11h.01"/>',
  settings: '<path d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
  card: '<path d="M2 7a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2zM2 10h20"/>',
  menu: '<path d="M3 6h18M3 12h18M3 18h18"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  edit: '<path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
  trash: '<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>',
  eye: '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z"/><circle cx="12" cy="12" r="3"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  share: '<path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8M16 6l-4-4-4 4M12 2v13"/>',
  qr: '<path d="M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h3v3h-3zM20 14v.01M14 20h.01M17 17h4v4h-4z"/>',
  external: '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14 21 3"/>',
  phone: '<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z"/>',
  whatsapp: '<path d="M3 21l1.6-4.7A8.5 8.5 0 1 1 7.8 19.6z"/><path d="M9 9.5c0 3 2.5 5.5 5.5 5.5l1.3-1.3-1.8-.9-.8.8a4 4 0 0 1-2.3-2.3l.8-.8-.9-1.8z"/>',
  logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>',
  bell: '<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0"/>',
  chart: '<path d="M3 3v18h18M7 15l4-4 3 3 5-6"/>',
  file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 13h8M8 17h5"/>',
  clock: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  minus: '<path d="M5 12h14"/>',
  instagram: '<rect x="2" y="2" width="20" height="20" rx="5"/><circle cx="12" cy="12" r="4"/><path d="M17.5 6.5h.01"/>',
  facebook: '<path d="M18 2h-3a5 5 0 0 0-5 5v3H7v4h3v8h4v-8h3l1-4h-4V7a1 1 0 0 1 1-1h3z"/>',
  tiktok: '<path d="M9 12a4 4 0 1 0 4 4V2a5 5 0 0 0 5 5"/>',
  map: '<path d="M21 10c0 7-9 13-9 13S3 17 3 10a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/>',
  mail: '<path d="M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"/><path d="m22 6-10 7L2 6"/>',
};
function icon(name, cls = "icon") {
  return `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ""}</svg>`;
}
