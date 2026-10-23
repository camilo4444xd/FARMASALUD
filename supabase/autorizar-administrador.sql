-- Ejecuta este bloque DESPUÉS de crear el usuario en Supabase > Authentication > Users.
-- Reemplaza el correo de ejemplo por el mismo correo exacto que pusiste en assets/js/supabase-config.js.
-- NO ejecutes el texto de ejemplo sin reemplazarlo.

insert into public.farmasalud_admins(user_id)
select id
from auth.users
where lower(email) = lower('REEMPLAZA_POR_TU_CORREO_ADMIN')
on conflict (user_id) do nothing;

-- Resultado esperado: Success. No rows returned.
-- Para verificar la autorización puedes ejecutar:
-- select a.user_id, u.email from public.farmasalud_admins a join auth.users u on u.id = a.user_id;
