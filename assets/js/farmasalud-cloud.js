/* FarmaSalud cloud connector: Supabase Auth, Postgres, Storage y Realtime. */
(function () {
  'use strict';
  const CONFIG = () => window.FARMASALUD_SUPABASE_CONFIG || {};
  let supabaseClient = null;

  function isConfigured() {
    const c = CONFIG();
    return Boolean(
      window.supabase && typeof window.supabase.createClient === 'function' &&
      /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(String(c.url || '')) &&
      c.publishableKey && !String(c.publishableKey).includes('PEGA_AQUI') &&
      !String(c.publishableKey).includes('CAMBIA_')
    );
  }
  function client() {
    if (!isConfigured()) {
      throw new Error('Configura url y publishableKey en assets/js/supabase-config.js. Usa una clave publishable/anon, nunca una clave secret/service_role.');
    }
    if (!supabaseClient) {
      const c = CONFIG();
      supabaseClient = window.supabase.createClient(c.url, c.publishableKey, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
      });
    }
    return supabaseClient;
  }
  function throwIfError(result) {
    if (result && result.error) {
      const e = new Error(result.error.message || 'Supabase devolvió un error.');
      e.code = result.error.code; e.details = result.error.details; e.hint = result.error.hint;
      throw e;
    }
    return result ? result.data : null;
  }
  function productFromRow(r) {
    return { id: Number(r.id), nombre: r.nombre || '', codigo: r.codigo || '', categoria: r.categoria || 'otros', precio: Number(r.precio) || 0, descripcion: r.descripcion || '', receta: r.receta === true, imagen: r.imagen || '', activo: r.activo !== false, updatedAt: r.updated_at || '' };
  }
  function productToRow(p) {
    return { id: Number(p.id), nombre: String(p.nombre || '').trim(), codigo: String(p.codigo || '').trim() || `FAR-${Number(p.id)}`, categoria: String(p.categoria || 'otros'), precio: Math.max(0, Number(p.precio) || 0), descripcion: String(p.descripcion || ''), receta: p.receta === true, imagen: String(p.imagen || ''), activo: p.activo !== false, updated_at: new Date().toISOString() };
  }
  function promoFromRow(r) {
    return { id: String(r.id), active: r.active === true, badge: r.badge || '', title: r.title || '', description: r.description || '', button: r.button || 'Agregar al carrito', image: r.image || '', price: Number(r.price) || 0, originalPrice: Number(r.original_price) || 0, categoria: r.categoria || 'otros', receta: r.receta === true, updatedAt: r.updated_at || '' };
  }
  function promoToRow(p, i) {
    return { id: String(p.id || `p${i + 1}`), active: p.active === true, badge: String(p.badge || ''), title: String(p.title || ''), description: String(p.description || ''), button: String(p.button || 'Agregar al carrito'), image: String(p.image || ''), price: Math.max(0, Number(p.price) || 0), original_price: Math.max(0, Number(p.originalPrice ?? p.original_price) || 0), categoria: String(p.categoria || 'otros'), receta: p.receta === true, updated_at: new Date().toISOString() };
  }
  function founderFromRow(r) {
    return { id: String(r.id), name: r.name || '', role: r.role || '', bio: r.bio || '', image: r.image || '', displayOrder: Number(r.display_order) || 0, updatedAt: r.updated_at || '' };
  }
  function founderToRow(f, i) {
    return { id: String(f.id || `f${i + 1}`), name: String(f.name || ''), role: String(f.role || ''), bio: String(f.bio || ''), image: String(f.image || ''), display_order: Number(f.displayOrder ?? f.display_order) || i + 1, updated_at: new Date().toISOString() };
  }
  async function requireAdmin() {
    const sb = client();
    const sessionData = throwIfError(await sb.auth.getSession());
    if (!sessionData || !sessionData.session) throw new Error('Inicia sesión con la cuenta de administrador.');
    const ok = throwIfError(await sb.rpc('is_farmasalud_admin'));
    if (ok !== true) throw new Error('La cuenta inició sesión, pero todavía no está autorizada como administradora. Añade su usuario a farmasalud_admins con el SQL del manual.');
    return sessionData.session.user;
  }
  async function signInAlias(username, password, expectedRole) {
    const sb = client(); const c = CONFIG();
    const alias = String(username || '').trim().toUpperCase();
    let email = '';
    if (alias === 'ADMIN' || (String(username).includes('@') && expectedRole === 'admin')) email = c.adminEmail;
    else if (alias === 'CLIENTEPRUEBA' || (String(username).includes('@') && expectedRole !== 'admin')) email = c.clientEmail;
    else throw new Error('Escribe ADMIN o CLIENTEPRUEBA según el tipo de cuenta configurado.');
    if (!email || /CAMBIA_|@EJEMPLO\.COM/i.test(email)) throw new Error('Configura el correo de esta cuenta en assets/js/supabase-config.js y crea ese usuario en Supabase Authentication.');
    const result = throwIfError(await sb.auth.signInWithPassword({ email, password }));
    if (expectedRole === 'admin' || alias === 'ADMIN') {
      try { const admin = throwIfError(await sb.rpc('is_farmasalud_admin')); if (admin !== true) { await sb.auth.signOut(); throw new Error('La cuenta no tiene permisos de administrador. Ejecuta el SQL de autorización con el correo de adminEmail.'); } }
      catch (e) { await sb.auth.signOut(); throw e; }
      return { role: 'admin', user: result.user };
    }
    return { role: 'client', user: result.user };
  }
  async function isAdmin() {
    if (!isConfigured()) return false;
    try {
      const sb = client();
      const session = throwIfError(await sb.auth.getSession());
      if (!session || !session.session) return false;
      return throwIfError(await sb.rpc('is_farmasalud_admin')) === true;
    } catch (e) { return false; }
  }
  async function logOut() {
    if (!isConfigured()) return;
    throwIfError(await client().auth.signOut());
  }
  async function getState() {
    const sb = client();
    const [products, promotions, founders] = await Promise.all([
      sb.from('farmasalud_products').select('*').order('id', { ascending: true }),
      sb.from('farmasalud_promotions').select('*').order('id', { ascending: true }),
      sb.from('farmasalud_founders').select('*').order('display_order', { ascending: true })
    ]);
    const p = throwIfError(products) || [], pr = throwIfError(promotions) || [], f = throwIfError(founders) || [];
    return { initialized: p.length > 0, products: p.map(productFromRow), promotions: pr.map(promoFromRow), founders: f.map(founderFromRow) };
  }
  async function syncCollection(table, rows, idCol) {
    const sb = client();
    if (!Array.isArray(rows)) throw new Error(`Datos inválidos para ${table}.`);
    if (rows.length) throwIfError(await sb.from(table).upsert(rows, { onConflict: idCol }));
    const current = throwIfError(await sb.from(table).select(idCol)) || [];
    const keep = new Set(rows.map(r => String(r[idCol])));
    for (const row of current) {
      if (!keep.has(String(row[idCol]))) {
        const filterId = row[idCol];
        throwIfError(await sb.from(table).delete().eq(idCol, filterId));
      }
    }
  }
  async function saveState(partial) {
    await requireAdmin();
    if (!partial || typeof partial !== 'object') throw new Error('No hay cambios para guardar.');
    if (Object.prototype.hasOwnProperty.call(partial, 'products')) {
      const rows = partial.products.map(productToRow);
      if (new Set(rows.map(r => r.id)).size !== rows.length) throw new Error('Hay identificadores de productos duplicados.');
      if (new Set(rows.map(r => r.codigo)).size !== rows.length) throw new Error('Hay códigos/SKU duplicados.');
      await syncCollection('farmasalud_products', rows, 'id');
    }
    if (Object.prototype.hasOwnProperty.call(partial, 'promotions')) {
      const rows = partial.promotions.map(promoToRow);
      await syncCollection('farmasalud_promotions', rows, 'id');
    }
    if (Object.prototype.hasOwnProperty.call(partial, 'founders')) {
      const rows = partial.founders.map(founderToRow);
      await syncCollection('farmasalud_founders', rows, 'id');
    }
    return await getState();
  }
  function slugify(s) {
    return String(s || 'imagen').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 70) || 'imagen';
  }
  function dataUrlToBlob(dataUrl) {
    const m = /^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$/.exec(String(dataUrl || ''));
    if (!m) throw new Error('La imagen debe ser PNG, JPG o WEBP.');
    const binary = atob(m[2]); const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return { blob: new Blob([bytes], { type: m[1] }), mime: m[1] };
  }
  async function uploadDataUrl(kind, dataUrl, name) {
    await requireAdmin();
    const sb = client(); const parsed = dataUrlToBlob(dataUrl);
    const folderByKind = { product: 'productos', promotion: 'promociones', founder: 'fundadores' };
    const folder = folderByKind[kind];
    if (!folder) throw new Error('Tipo de imagen no reconocido.');
    const ext = parsed.mime === 'image/png' ? 'png' : parsed.mime === 'image/jpeg' ? 'jpg' : 'webp';
    const path = `${folder}/${slugify(name)}.${ext}`;
    throwIfError(await sb.storage.from('farmasalud-media').upload(path, parsed.blob, { contentType: parsed.mime, upsert: true, cacheControl: '3600' }));
    const pub = sb.storage.from('farmasalud-media').getPublicUrl(path);
    return { path: pub.data.publicUrl, storagePath: path };
  }
  async function checkImage(value) {
    const v = String(value || '').trim();
    if (!v) return { exists: false, path: v };
    if (v.startsWith('data:image/')) return { exists: true, path: v };
    try {
      const response = await fetch(v, { method: 'HEAD', cache: 'no-store' });
      return { exists: response.ok, path: v, status: response.status };
    } catch (e) {
      // Algunas CDN públicas no responden a HEAD por CORS; en ese caso intentamos GET.
      try { const response = await fetch(v, { method: 'GET', cache: 'no-store' }); return { exists: response.ok, path: v, status: response.status }; }
      catch (e2) { return { exists: false, path: v }; }
    }
  }
  function statusLabel(state) { return ({ '-1': 'Cancelado', '0': 'Pedido recibido', '1': 'Preparando pedido', '2': 'En camino', '3': 'Entregado' })[String(state)] || 'Pedido recibido'; }
  async function listOrders() {
    await requireAdmin();
    const rows = throwIfError(await client().from('farmasalud_orders').select('*').order('created_at', { ascending: false })) || [];
    return rows.map(r => ({ ...(r.payload || {}), codigo: r.codigo, estado: Number(r.estado), estadoTexto: statusLabel(Number(r.estado)), telefono: r.telefono, fecha: (r.payload && r.payload.fecha) || r.created_at, updatedAt: r.updated_at }));
  }
  async function createOrder(order) {
    const sb = client();
    const payload = { ...(order || {}) };
    const codigo = String(payload.codigo || '').trim();
    const telefono = String((payload.usuario && payload.usuario.telefono) || payload.telefono || '').trim();
    if (!codigo || !Array.isArray(payload.productos)) throw new Error('El pedido no contiene código o productos válidos.');
    if (telefono.replace(/\D/g, '').length < 7) throw new Error('Registra un teléfono válido para poder guardar y rastrear el pedido.');
    const estado = Number.isInteger(payload.estado) ? payload.estado : 0;
    payload.estado = estado; payload.estadoTexto = statusLabel(estado);
    const row = { codigo, telefono, payload, estado };
    throwIfError(await sb.from('farmasalud_orders').insert(row));
    return { ...payload };
  }
  async function updateOrder(code, next, previous) {
    await requireAdmin();
    const sb = client(); const now = new Date();
    const base = { ...(previous || {}) };
    const history = Array.isArray(base.historial) ? base.historial.slice() : [];
    history.push({ estado: Number(next), fecha: now.toLocaleString('es-PE'), fechaISO: now.toISOString(), mensaje: `Estado actualizado desde el panel: ${statusLabel(Number(next))}.` });
    base.estado = Number(next); base.estadoTexto = statusLabel(Number(next)); base.historial = history;
    base.updatedAt = now.toISOString();
    const result = await sb.from('farmasalud_orders').update({ estado: Number(next), payload: base, updated_at: now.toISOString() }).eq('codigo', String(code)).select('codigo');
    const rows = throwIfError(result) || [];
    if (!rows.length) throw new Error('No se encontró el pedido o no tienes permisos para actualizarlo.');
    return base;
  }
  async function lookupOrder(code, phone) {
    const result = throwIfError(await client().rpc('farmasalud_lookup_order', { p_codigo: String(code || '').trim(), p_telefono: String(phone || '').trim() }));
    const value = Array.isArray(result) ? result[0] : result;
    if (!value) return null;
    return { ...value, estado: Number(value.estado) };
  }
  function subscribeCatalog(callback) {
    const sb = client();
    return sb.channel('farmasalud-catalog-live')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'farmasalud_products' }, callback)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'farmasalud_promotions' }, callback)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'farmasalud_founders' }, callback)
      .subscribe();
  }
  window.FarmaCloud = { isConfigured, signInAlias, isAdmin, logOut, getState, saveState, uploadDataUrl, checkImage, listOrders, createOrder, updateOrder, lookupOrder, subscribeCatalog };
})();
