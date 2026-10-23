-- FarmaSalud: esquema seguro para GitHub Pages + Supabase.
-- Ejecuta el archivo completo en Supabase > SQL Editor > New query.
-- Esta llave publica de Supabase va en el navegador; NUNCA pongas service_role aquí.
create extension if not exists pgcrypto;

create table if not exists public.farmasalud_products (
  id bigint primary key,
  nombre text not null,
  codigo text not null unique,
  categoria text not null check (categoria in ('medicamentos','vitaminas','cuidado','bebes','primeros','proteccion','otros')),
  precio numeric(10,2) not null check (precio >= 0),
  descripcion text not null default '',
  receta boolean not null default false,
  imagen text not null default '',
  activo boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.farmasalud_promotions (
  id text primary key,
  active boolean not null default true,
  badge text not null default '',
  title text not null,
  description text not null default '',
  button text not null default 'Agregar al carrito',
  image text not null default '',
  price numeric(10,2) not null default 0 check (price >= 0),
  original_price numeric(10,2) not null default 0 check (original_price >= 0),
  categoria text not null default 'otros' check (categoria in ('medicamentos','vitaminas','cuidado','bebes','primeros','proteccion','otros')),
  receta boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists public.farmasalud_founders (
  id text primary key,
  name text not null default '',
  role text not null default '',
  bio text not null default '',
  image text not null default '',
  display_order integer not null default 0,
  updated_at timestamptz not null default now()
);

-- Los pedidos se comparten con el panel, pero el público no puede consultar la tabla directamente.
create table if not exists public.farmasalud_orders (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  telefono text not null default '',
  payload jsonb not null,
  estado integer not null default 0 check (estado between -1 and 3),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Lista de usuarios autorizados a administrar. Solo se modifica desde el SQL Editor por el propietario del proyecto.
create table if not exists public.farmasalud_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_farmasalud_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.farmasalud_admins a where a.user_id = (select auth.uid()));
$$;
revoke all on function public.is_farmasalud_admin() from public;
grant execute on function public.is_farmasalud_admin() to authenticated;

-- Consulta de seguimiento protegida: exige código y teléfono coincidentes y nunca expone la tabla completa.
create or replace function public.farmasalud_lookup_order(p_codigo text, p_telefono text)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_set(o.payload, '{estado}', to_jsonb(o.estado), true)
  from public.farmasalud_orders o
  where upper(o.codigo) = upper(btrim(p_codigo))
    and regexp_replace(o.telefono, '[^0-9]', '', 'g') = regexp_replace(coalesce(p_telefono,''), '[^0-9]', '', 'g')
    and length(regexp_replace(coalesce(p_telefono,''), '[^0-9]', '', 'g')) >= 7
  limit 1;
$$;
revoke all on function public.farmasalud_lookup_order(text,text) from public;
grant execute on function public.farmasalud_lookup_order(text,text) to anon, authenticated;

-- RLS: activado en todas las tablas expuestas.
alter table public.farmasalud_products enable row level security;
alter table public.farmasalud_promotions enable row level security;
alter table public.farmasalud_founders enable row level security;
alter table public.farmasalud_orders enable row level security;
alter table public.farmasalud_admins enable row level security;

revoke all on public.farmasalud_products from anon;
revoke all on public.farmasalud_promotions from anon;
revoke all on public.farmasalud_founders from anon;
revoke all on public.farmasalud_orders from anon;
revoke all on public.farmasalud_admins from anon, authenticated;
grant select on public.farmasalud_products to anon, authenticated;
grant select, insert, update, delete on public.farmasalud_products to authenticated;
grant select on public.farmasalud_promotions to anon, authenticated;
grant select, insert, update, delete on public.farmasalud_promotions to authenticated;
grant select on public.farmasalud_founders to anon, authenticated;
grant select, insert, update, delete on public.farmasalud_founders to authenticated;
grant insert on public.farmasalud_orders to anon, authenticated;
grant select, update, delete on public.farmasalud_orders to authenticated;

-- Quitar políticas anteriores con estos nombres para permitir ejecutar el script de nuevo.
drop policy if exists "Public sees active FarmaSalud products" on public.farmasalud_products;
drop policy if exists "Authenticated reads active products or admins read all" on public.farmasalud_products;
drop policy if exists "Admins manage products" on public.farmasalud_products;
drop policy if exists "Public sees active FarmaSalud promotions" on public.farmasalud_promotions;
drop policy if exists "Authenticated reads active promotions or admins read all" on public.farmasalud_promotions;
drop policy if exists "Admins manage promotions" on public.farmasalud_promotions;
drop policy if exists "Public sees founders" on public.farmasalud_founders;
drop policy if exists "Admins manage founders" on public.farmasalud_founders;
drop policy if exists "Public can create orders" on public.farmasalud_orders;
drop policy if exists "Admins read orders" on public.farmasalud_orders;
drop policy if exists "Admins update orders" on public.farmasalud_orders;
drop policy if exists "Admins delete orders" on public.farmasalud_orders;

create policy "Public sees active FarmaSalud products" on public.farmasalud_products for select to anon using (activo = true);
create policy "Authenticated reads active products or admins read all" on public.farmasalud_products for select to authenticated using (activo = true or (select public.is_farmasalud_admin()));
create policy "Admins manage products" on public.farmasalud_products for all to authenticated using ((select public.is_farmasalud_admin())) with check ((select public.is_farmasalud_admin()));

create policy "Public sees active FarmaSalud promotions" on public.farmasalud_promotions for select to anon using (active = true);
create policy "Authenticated reads active promotions or admins read all" on public.farmasalud_promotions for select to authenticated using (active = true or (select public.is_farmasalud_admin()));
create policy "Admins manage promotions" on public.farmasalud_promotions for all to authenticated using ((select public.is_farmasalud_admin())) with check ((select public.is_farmasalud_admin()));

create policy "Public sees founders" on public.farmasalud_founders for select to anon, authenticated using (true);
create policy "Admins manage founders" on public.farmasalud_founders for all to authenticated using ((select public.is_farmasalud_admin())) with check ((select public.is_farmasalud_admin()));

create policy "Public can create orders" on public.farmasalud_orders for insert to anon, authenticated with check (
  length(btrim(codigo)) between 8 and 50
  and payload->>'codigo' = codigo
  and length(regexp_replace(coalesce(telefono,''), '[^0-9]', '', 'g')) >= 7
  and jsonb_typeof(payload->'productos') = 'array'
);
create policy "Admins read orders" on public.farmasalud_orders for select to authenticated using ((select public.is_farmasalud_admin()));
create policy "Admins update orders" on public.farmasalud_orders for update to authenticated using ((select public.is_farmasalud_admin())) with check ((select public.is_farmasalud_admin()));
create policy "Admins delete orders" on public.farmasalud_orders for delete to authenticated using ((select public.is_farmasalud_admin()));

-- Bucket público para lectura de fotos; solo usuarios incluidos en farmasalud_admins pueden subir, reemplazar o borrar.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('farmasalud-media', 'farmasalud-media', true, 10485760, array['image/png','image/jpeg','image/webp']::text[])
on conflict (id) do update set public = true, file_size_limit = 10485760, allowed_mime_types = array['image/png','image/jpeg','image/webp']::text[];
drop policy if exists "Public reads FarmaSalud media" on storage.objects;
drop policy if exists "FarmaSalud admins upload media" on storage.objects;
drop policy if exists "FarmaSalud admins update media" on storage.objects;
drop policy if exists "FarmaSalud admins delete media" on storage.objects;
create policy "Public reads FarmaSalud media" on storage.objects for select to anon, authenticated using (bucket_id = 'farmasalud-media');
create policy "FarmaSalud admins upload media" on storage.objects for insert to authenticated with check (bucket_id = 'farmasalud-media' and (select public.is_farmasalud_admin()));
create policy "FarmaSalud admins update media" on storage.objects for update to authenticated using (bucket_id = 'farmasalud-media' and (select public.is_farmasalud_admin())) with check (bucket_id = 'farmasalud-media' and (select public.is_farmasalud_admin()));
create policy "FarmaSalud admins delete media" on storage.objects for delete to authenticated using (bucket_id = 'farmasalud-media' and (select public.is_farmasalud_admin()));

-- Realtime: permite que el catálogo abierto refresque cambios hechos desde el panel.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='farmasalud_products') then alter publication supabase_realtime add table public.farmasalud_products; end if;
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='farmasalud_promotions') then alter publication supabase_realtime add table public.farmasalud_promotions; end if;
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='farmasalud_founders') then alter publication supabase_realtime add table public.farmasalud_founders; end if;
  end if;
end $$;

-- SEED INICIAL: no sobrescribe cambios si ya existe un registro (ON CONFLICT DO NOTHING).

-- Productos iniciales (44).
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (1,'Paracetamol 500 mg','FAR-MED-001','medicamentos',8.90,'Analgésico y antipirético.',FALSE,'assets/productos/paracetamol.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (2,'Ibuprofeno 400 mg','FAR-MED-002','medicamentos',12.90,'Antiinflamatorio y analgésico de venta libre.',FALSE,'assets/productos/ibuprofeno.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (3,'Loratadina 10 mg','FAR-MED-003','medicamentos',10.50,'Antihistamínico para alergias y rinitis.',FALSE,'assets/productos/loratadina.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (4,'Omeprazol 20 mg','FAR-MED-004','medicamentos',13.90,'Protector gástrico para la acidez y reflujo.',FALSE,'assets/productos/omeprazol.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (5,'Amoxicilina 500 mg','FAR-MED-005','medicamentos',14.90,'Antibiótico de amplio espectro.',TRUE,'assets/productos/amoxicilina.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (6,'Salbutamol Inhalador 100 mcg','FAR-MED-006','medicamentos',16.90,'Broncodilatador para alivio respiratorio.',TRUE,'assets/productos/salbutamol.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (7,'Naproxeno 550 mg','FAR-MED-007','medicamentos',11.90,'Antiinflamatorio y analgésico muscular.',FALSE,'assets/productos/naproxeno.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (8,'Antigripal NF','FAR-MED-008','medicamentos',9.90,'Alivio de síntomas del resfriado común y gripe.',FALSE,'assets/productos/antigripal-nf.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (9,'Hioscina + Paracetamol','FAR-MED-009','medicamentos',11.50,'Antiespasmódico para alivio de dolores y cólicos.',FALSE,'assets/productos/hioscina-paracetamol.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (10,'Loperamida 2 mg','FAR-MED-010','medicamentos',6.90,'Antidiarreico de acción rápida.',FALSE,'assets/productos/loperamida.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (11,'Sales de Rehidratación Oral','FAR-MED-011','medicamentos',4.50,'Prevención y tratamiento de la deshidratación.',FALSE,'assets/productos/sales-rehidratacion-oral.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (12,'Vitamina C','FAR-VIT-001','vitaminas',18.90,'Suplemento de vitamina C para reforzar defensas.',FALSE,'assets/productos/vitamina-c.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (13,'Multivitamínico','FAR-VIT-002','vitaminas',32.90,'Complemento multivitamínico diario.',FALSE,'assets/productos/multivitaminico.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (14,'Zinc','FAR-VIT-003','vitaminas',22.90,'Suplemento de zinc para el sistema inmune.',FALSE,'assets/productos/zinc.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (15,'Omega 3','FAR-VIT-004','vitaminas',39.90,'Complemento alimenticio para la salud cardiovascular.',FALSE,'assets/productos/omega-3.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (16,'Protector solar FPS 50+','FAR-CUI-001','cuidado',45.90,'Protector solar para uso diario.',FALSE,'assets/productos/protector-solar.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (17,'Gel limpiador facial','FAR-CUI-002','cuidado',34.90,'Producto de higiene facial profunda.',FALSE,'assets/productos/gel-limpiador-facial.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (18,'Crema hidratante','FAR-CUI-003','cuidado',29.90,'Hidratante para cuidado corporal y piel.',FALSE,'assets/productos/crema-hidratante.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (19,'Shampoo','FAR-CUI-004','cuidado',24.90,'Producto para higiene capilar.',FALSE,'assets/productos/shampoo.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (20,'Crema dental protección caries 75 ml','FAR-CUI-005','cuidado',6.90,'Higiene y protección bucal diaria.',FALSE,'assets/productos/crema-dental.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (21,'Enjuague bucal antiséptico 250 ml','FAR-CUI-006','cuidado',11.90,'Protección contra la placa y mal aliento.',FALSE,'assets/productos/enjuague-bucal.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (22,'Jabón líquido antibacterial 400 ml','FAR-CUI-007','cuidado',9.90,'Limpieza profunda y protección familiar.',FALSE,'assets/productos/jabon-liquido-antibacterial.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (23,'Toallas higiénicas (Pack x 10)','FAR-CUI-008','cuidado',7.50,'Protección e higiene femenina diaria.',FALSE,'assets/productos/toallas-higienicas.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (24,'Pañales para bebé','FAR-BEB-001','bebes',39.90,'Pañales desechables suaves y absorbentes.',FALSE,'assets/productos/panales-bebe.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (25,'Toallitas húmedas','FAR-BEB-002','bebes',12.90,'Toallitas para higiene delicada del bebé.',FALSE,'assets/productos/toallitas-humedas.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (26,'Fórmula infantil Etapa 1 / Etapa 2 (400g)','FAR-BEB-003','bebes',38.90,'Alimento lácteo para lactantes.',FALSE,'assets/productos/formula-infantil.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (27,'Crema antipañalitis (Óxido de Zinc)','FAR-BEB-004','bebes',14.90,'Protege y alivia la piel contra escaldaduras.',FALSE,'assets/productos/crema-antipanalitis.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (28,'Biberón anticólicos 250 ml','FAR-BEB-005','bebes',18.90,'Biberón ergonómico con tetina de silicona.',FALSE,'assets/productos/biberon-anticolicos.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (29,'Curitas adhesivas','FAR-PRI-001','primeros',7.90,'Protección para pequeñas lesiones y cortes.',FALSE,'assets/productos/curitas.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (30,'Venda elástica','FAR-PRI-002','primeros',9.90,'Material de soporte y primeros auxilios.',FALSE,'assets/productos/venda-elastica.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (31,'Gasas estériles','FAR-PRI-003','primeros',8.90,'Material estéril para botiquín y curaciones.',FALSE,'assets/productos/gasas-esteriles.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (32,'Alcohol en gel','FAR-PRI-004','primeros',10.90,'Desinfectante para la higiene de manos.',FALSE,'assets/productos/alcohol-en-gel.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (33,'Agua Oxigenada 250 ml','FAR-PRI-005','primeros',4.90,'Antiséptico y desinfectante para heridas.',FALSE,'assets/productos/agua-oxigenada.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (34,'Yodopovidona antiséptica 120 ml','FAR-PRI-006','primeros',7.90,'Solución antiséptica para curaciones.',FALSE,'assets/productos/yodopovidona.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (35,'Algodón Hidrófilo 100g','FAR-PRI-007','primeros',5.90,'Algodón de uso médico e higiene.',FALSE,'assets/productos/algodon-hidrofilo.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (36,'Esparadrapo / Cinta médica','FAR-PRI-008','primeros',6.50,'Fijación de vendajes y gasas.',FALSE,'assets/productos/esparadrapo.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (37,'Guantes descartables','FAR-PRO-001','proteccion',15.90,'Guantes de protección e higiene.',FALSE,'assets/productos/guantes-descartables.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (38,'Protector facial','FAR-PRO-002','proteccion',19.90,'Elemento de protección personal.',FALSE,'assets/productos/protector-facial.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (39,'Mascarillas desechables','FAR-PRO-003','proteccion',12.90,'Mascarillas de protección respiratoria.',FALSE,'assets/productos/mascarillas.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (40,'Termómetro digital','FAR-OTR-001','otros',25.90,'Dispositivo preciso para medición de temperatura.',FALSE,'assets/productos/termometro.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (41,'Tensiómetro digital de brazo','FAR-OTR-002','otros',68.90,'Monitoreo de la presión arterial.',FALSE,'assets/productos/tensiometro.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (42,'Oxímetro de pulso digital','FAR-OTR-003','otros',32.90,'Medidor de saturación de oxígeno en sangre.',FALSE,'assets/productos/oximetro.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (43,'Glucómetro digital con tiras de prueba','FAR-OTR-004','otros',54.90,'Kit para medición de glucosa en sangre.',FALSE,'assets/productos/glucometro.png',TRUE) on conflict (id) do nothing;
insert into public.farmasalud_products (id,nombre,codigo,categoria,precio,descripcion,receta,imagen,activo) values (44,'Pañales para adulto (Pack x 8)','FAR-OTR-005','otros',28.90,'Protección para incontinencia.',FALSE,'assets/productos/panales-adulto.png',TRUE) on conflict (id) do nothing;

-- Promociones iniciales (3).
insert into public.farmasalud_promotions (id,active,badge,title,description,button,image,price,original_price,categoria,receta) values ('p1',TRUE,'¡AHORRA 28%! - PACK BOTIQUÍN','PACK BOTIQUÍN FAMILIAR DE EMERGENCIA','Categoría: Primeros auxilios / Medicamentos. Incluye 1 Paracetamol 500 mg, 1 Alcohol en Gel, 1 Agua Oxigenada 250 ml, 1 caja de Curitas Adhesivas y 1 paquete de Gasas Estériles. Para heridas leves y alivio de fiebre o dolor en casa.','Agregar al carrito','assets/promociones/promocion-01.jpg',29.90,41.50,'primeros',FALSE) on conflict (id) do nothing;
insert into public.farmasalud_promotions (id,active,badge,title,description,button,image,price,original_price,categoria,receta) values ('p2',TRUE,'OFERTA DUO DEFENSAS','COMBO SALUD Y DEFENSAS (VITAMINA C + ZINC)','Categoría: Vitaminas. Incluye 1 frasco de Vitamina C y 1 frasco de Zinc. Combo para acompañar el cuidado del sistema inmunológico y las defensas de toda la familia durante resfriados y cambios de clima.','Agregar al carrito','assets/promociones/promocion-02.jpg',31.90,41.80,'vitaminas',FALSE) on conflict (id) do nothing;
insert into public.farmasalud_promotions (id,active,badge,title,description,button,image,price,original_price,categoria,receta) values ('p3',TRUE,'OFERTA ESPECIAL - KIT TU PIEL NOS IMPORTA','KIT TU PIEL NOS IMPORTA','Categoría: Cuidado personal. Incluye 1 Protector solar FPS 50+, 1 Gel limpiador facial y 1 Crema hidratante. Rutina completa para limpiar, hidratar y proteger la piel todos los días.','Agregar al carrito','assets/promociones/promocion-03.jpg',99.99,109.70,'cuidado',FALSE) on conflict (id) do nothing;

-- Fundadores iniciales (6). Agrega sus fotos en assets/fundadores/ o súbelas desde el panel.
insert into public.farmasalud_founders (id,name,role,bio,image,display_order) values ('f1','Contreras Mendoza, Camilo George','LÍDER, DIRECTOR Y TECNOLOGÍA (CEO & CTO)','Asume la máxima dirección estratégica y de liderazgo del emprendimiento. Además, dirige el desarrollo, mantenimiento, optimización y seguridad de la página web de delivery de Farma Salud, garantizando una plataforma rápida, intuitiva y segura para todos los usuarios.','assets/fundadores/fundador-01.png',1) on conflict (id) do nothing;
insert into public.farmasalud_founders (id,name,role,bio,image,display_order) values ('f2','Bellido Pacheco, Arturo Cristhian','OPERADOR DE LOGÍSTICA','Se encarga de la gestión operativa del servicio de entregas. Coordina la cadena de suministro con las farmacias aliadas, supervisa los tiempos de despacho y asegura que los medicamentos y productos lleguen a los hogares de manera puntual y segura.','assets/fundadores/fundador-02.png',2) on conflict (id) do nothing;
insert into public.farmasalud_founders (id,name,role,bio,image,display_order) values ('f3','Terrones Ramos, Carlos Andrés','DIRECTOR DE MARKETING','Diseña y ejecuta las estrategias de crecimiento, posicionamiento de marca y campañas publicitarias digitales para captar nuevos usuarios y dar a conocer la plataforma web en el mercado.','assets/fundadores/fundador-03.png',3) on conflict (id) do nothing;
insert into public.farmasalud_founders (id,name,role,bio,image,display_order) values ('f4','Tacury Robles, Fernando Rodrigo','DIRECTOR DE MARKETING','Se encarga de la gestión directa de los canales de difusión y redes sociales, creando contenido visual y dinámicas comerciales para conectar de forma activa con la comunidad y potenciar las ventas online.','assets/fundadores/fundador-04.png',4) on conflict (id) do nothing;
insert into public.farmasalud_founders (id,name,role,bio,image,display_order) values ('f5','Suasnabar Rojas, Jean Carlo','EXPERIENCIA DE CLIENTES','Supervisa la atención directa al usuario y la calidad del servicio post-venta. Se encarga de resolver incidencias, recopilar opiniones y asegurar que la experiencia de compra y recepción de los productos sea totalmente satisfactoria y confiable.','assets/fundadores/fundador-05.png',5) on conflict (id) do nothing;
insert into public.farmasalud_founders (id,name,role,bio,image,display_order) values ('f6','Martinez Janampa, Leonardo Hiroshi','DIRECTOR FINANCIERO','Administra los recursos económicos, el presupuesto, los costos operativos y la contabilidad general de la empresa, asegurando la sostenibilidad financiera y el crecimiento rentable del emprendimiento.','assets/fundadores/fundador-06.png',6) on conflict (id) do nothing;


-- DESPUÉS de crear al usuario administrador en Authentication > Users, ejecuta este bloque
-- reemplazando el email. No ejecutes con el texto de ejemplo tal cual.
-- insert into public.farmasalud_admins(user_id)
-- select id from auth.users where lower(email) = lower('TU_CORREO_ADMIN@EJEMPLO.COM')
-- on conflict (user_id) do nothing;
