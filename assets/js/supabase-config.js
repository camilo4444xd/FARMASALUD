/*
 * Configuración pública del cliente web de FarmaSalud.
 * La publishable key (o la legacy anon key) es apta para el navegador siempre que RLS esté configurado.
 * NUNCA pegues aquí una service_role key, secret key ni la contraseña de la base de datos.
 */
window.FARMASALUD_SUPABASE_CONFIG = {
  url: 'https://pdkdeojpyivlphjkqgpz.supabase.co',
  publishableKey: 'PEGA_AQUI_TU_PUBLISHABLE_KEY',
  adminEmail: 'CAMBIA_POR_TU_CORREO_ADMIN',
  clientEmail: 'CAMBIA_POR_TU_CORREO_CLIENTE'
};
