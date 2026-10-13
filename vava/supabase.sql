-- =====================================================================
--  CATÁLOGO MAYORISTA · Esquema Supabase
--  Pegalo completo en: Supabase > SQL Editor > New query > Run
--  Se puede ejecutar más de una vez sin romper nada.
-- =====================================================================

-- ---------- 1. Administradores ----------
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- 2. Categorías (Tendencia, Electrónica, Cosmética…) ----------
create table if not exists public.categorias (
  slug        text primary key,
  nombre      text not null,
  titulo_home text,                       -- título en la portada (ej: "Productos Tendencia")
  subtitulo   text not null default '',
  orden       int  not null default 0,
  activa      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- 3. Productos ----------
create table if not exists public.productos (
  id           uuid primary key default gen_random_uuid(),
  nombre       text not null,
  categoria    text not null references public.categorias(slug) on update cascade on delete restrict,
  marca        text not null default '',
  subcategoria text not null default '',
  imagen_url   text not null default '',
  precio_usdt  numeric(12,2) not null default 0 check (precio_usdt >= 0),
  precio_ars   numeric(14,0),             -- vacío = precio_usdt x cotización
  -- tramos mayoristas: [{"min":100,"usdt":7,"ars":11410}, ...]  (ars opcional)
  tramos       jsonb not null default '[]'::jsonb,
  stock        integer,                   -- vacío = sin control de stock
  stock_minimo integer not null default 5,
  activo       boolean not null default true,
  orden        int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists productos_categoria_idx on public.productos(categoria);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists productos_touch on public.productos;
create trigger productos_touch before update on public.productos
  for each row execute function public.touch_updated_at();

-- ---------- 4. Pedidos ----------
create table if not exists public.pedidos (
  id               uuid primary key default gen_random_uuid(),
  numero           bigint generated always as identity,
  cliente_nombre   text not null,
  cliente_telefono text not null default '',
  nota             text not null default '',
  total_usdt       numeric(14,2) not null default 0,
  total_ars        numeric(16,0) not null default 0,
  estado           text not null default 'pendiente'
                   check (estado in ('pendiente','confirmado','enviado','entregado','cancelado')),
  created_at       timestamptz not null default now()
);
create index if not exists pedidos_created_idx on public.pedidos(created_at desc);

create table if not exists public.pedido_items (
  id          uuid primary key default gen_random_uuid(),
  pedido_id   uuid not null references public.pedidos(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete set null,
  nombre      text not null,
  cantidad    int  not null check (cantidad > 0),
  precio_usdt numeric(12,2) not null,
  precio_ars  numeric(14,0) not null
);
create index if not exists pedido_items_pedido_idx on public.pedido_items(pedido_id);

-- ---------- 5. Ajustes de la tienda (portada, WhatsApp, cotización…) ----------
create table if not exists public.ajustes (
  clave text primary key,
  valor jsonb not null default '{}'::jsonb
);

-- ---------- 6. Crear pedido desde la tienda ----------
-- Los precios se recalculan acá (el navegador no puede manipularlos).
create or replace function public.crear_pedido(
  p_nombre text, p_telefono text, p_nota text, p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cot    numeric := coalesce((select (valor->>'cotizacion')::numeric from ajustes where clave = 'tienda'), 0);
  v_id     uuid;
  v_num    bigint;
  it       jsonb;
  tr       jsonb;
  prod     productos%rowtype;
  qty      int;
  u_usdt   numeric;
  u_ars    numeric;
  t_usdt   numeric := 0;
  t_ars    numeric := 0;
begin
  if coalesce(trim(p_nombre), '') = '' then raise exception 'Falta el nombre del cliente'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido está vacío';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'Demasiados productos'; end if;

  insert into pedidos (cliente_nombre, cliente_telefono, nota)
  values (left(trim(p_nombre), 120), left(coalesce(p_telefono, ''), 40), left(coalesce(p_nota, ''), 500))
  returning id, numero into v_id, v_num;

  for it in select e from jsonb_array_elements(p_items) as e loop
    qty := (it->>'cantidad')::int;
    if qty is null or qty <= 0 or qty > 100000 then raise exception 'Cantidad inválida'; end if;

    select * into prod from productos where id = (it->>'producto_id')::uuid and activo;
    if not found then raise exception 'Un producto del pedido ya no está disponible'; end if;

    u_usdt := prod.precio_usdt;
    u_ars  := prod.precio_ars;
    for tr in select t.v from jsonb_array_elements(prod.tramos) as t(v) order by (t.v->>'min')::int loop
      if qty >= (tr->>'min')::int then
        u_usdt := (tr->>'usdt')::numeric;
        u_ars  := nullif(tr->>'ars', '')::numeric;
      end if;
    end loop;
    u_ars := coalesce(u_ars, round(u_usdt * v_cot));

    insert into pedido_items (pedido_id, producto_id, nombre, cantidad, precio_usdt, precio_ars)
    values (v_id, prod.id, prod.nombre, qty, u_usdt, u_ars);

    t_usdt := t_usdt + u_usdt * qty;
    t_ars  := t_ars  + u_ars  * qty;
  end loop;

  update pedidos set total_usdt = t_usdt, total_ars = t_ars where id = v_id;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'total_usdt', t_usdt, 'total_ars', t_ars);
end $$;

revoke all on function public.crear_pedido(text, text, text, jsonb) from public;
grant execute on function public.crear_pedido(text, text, text, jsonb) to anon, authenticated;

-- ---------- 7. Seguridad (RLS) ----------
alter table public.admins       enable row level security;
alter table public.categorias   enable row level security;
alter table public.productos    enable row level security;
alter table public.pedidos      enable row level security;
alter table public.pedido_items enable row level security;
alter table public.ajustes      enable row level security;

drop policy if exists "admins: ver el propio"      on public.admins;
create policy "admins: ver el propio" on public.admins for select using (user_id = auth.uid());

drop policy if exists "categorias: lectura"        on public.categorias;
create policy "categorias: lectura" on public.categorias for select using (activa or public.is_admin());
drop policy if exists "categorias: admin escribe"  on public.categorias;
create policy "categorias: admin escribe" on public.categorias for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "productos: lectura"         on public.productos;
create policy "productos: lectura" on public.productos for select using (activo or public.is_admin());
drop policy if exists "productos: admin escribe"   on public.productos;
create policy "productos: admin escribe" on public.productos for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "ajustes: lectura"           on public.ajustes;
create policy "ajustes: lectura" on public.ajustes for select using (true);
drop policy if exists "ajustes: admin escribe"     on public.ajustes;
create policy "ajustes: admin escribe" on public.ajustes for all using (public.is_admin()) with check (public.is_admin());

-- pedidos: solo el admin los ve; los clientes crean pedidos únicamente con crear_pedido()
drop policy if exists "pedidos: admin"             on public.pedidos;
create policy "pedidos: admin" on public.pedidos for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "pedido_items: admin"        on public.pedido_items;
create policy "pedido_items: admin" on public.pedido_items for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 8. Imágenes (Storage) ----------
insert into storage.buckets (id, name, public) values ('productos', 'productos', true)
on conflict (id) do nothing;

drop policy if exists "imagenes: lectura publica" on storage.objects;
create policy "imagenes: lectura publica" on storage.objects for select using (bucket_id = 'productos');
drop policy if exists "imagenes: admin sube"      on storage.objects;
create policy "imagenes: admin sube"   on storage.objects for insert to authenticated
  with check (bucket_id = 'productos' and public.is_admin());
drop policy if exists "imagenes: admin edita"     on storage.objects;
create policy "imagenes: admin edita"  on storage.objects for update to authenticated
  using (bucket_id = 'productos' and public.is_admin());
drop policy if exists "imagenes: admin borra"     on storage.objects;
create policy "imagenes: admin borra"  on storage.objects for delete to authenticated
  using (bucket_id = 'productos' and public.is_admin());

-- ---------- 9. Datos iniciales ----------
insert into public.categorias (slug, nombre, titulo_home, subtitulo, orden) values
  ('tendencia',  'Tendencia',  'Productos Tendencia', 'Precios mayoristas por volumen', 1),
  ('electronica','Electrónica','Electrónica',         'Minorista y mayorista',          2),
  ('cosmetica',  'Cosmética',  'Cosmética',           'Minorista y mayorista',          3)
on conflict (slug) do nothing;

insert into public.ajustes (clave, valor) values ('tienda', '{
  "tienda": "Catálogo Mayorista",
  "titulo": "CATÁLOGO MAYORISTA",
  "avatar_url": "",
  "whatsapp": "5493765176960",
  "cotizacion": 1630,
  "combo_mensaje": "¡ESCRIBIME CUÁL ES TU PRESUPUESTO Y TE ARMO UN COMBO!",
  "combo_boton": "ARMAR COMBO",
  "combo_texto": "Decinos tu presupuesto y te armamos el combo ideal",
  "envios_titulo": "HACEMOS ENVÍOS A TODO EL PAÍS",
  "envios_detalle": "ANDREANI · VIA CARGO",
  "pagos_titulo": "MÉTODOS DE PAGO",
  "pagos_texto": "USDT o Cotización en pesos (+2% del valor del dolar Crypto)",
  "pagos_chips": ["Crypto / USDT", "Transferencia", "Dólar Blue", "Pesos"],
  "referencias": ["Instagram: @POSADAS.IMPORT", "Instagram Personal: @GASANCHEZS", "TikTok: @GASTONSANCHEZS"],
  "vendedores": [{"nombre": "GASTON", "telefono": "+54 3765 176960"}],
  "sitio": "GASANCHEZS.ONLINE",
  "sitio_url": "https://gasanchezs.online",
  "listas_pdf_url": "",
  "pie_aviso": "LOS PRECIOS REFLEJADOS SON POR UNIDAD",
  "pie_marca": "@POSADAS.IMPORT",
  "pie_autor": "by Gastón Sanchez"
}'::jsonb)
on conflict (clave) do nothing;

-- Productos de ejemplo (tomados de la captura). Podés borrarlos desde el panel.
insert into public.productos (nombre, categoria, precio_usdt, tramos, orden)
select * from (values
  ('AirPods Pro 2da Generación', 'tendencia',   7.00::numeric, '[{"min":100,"usdt":7,"ars":11410}]'::jsonb, 1),
  ('AirPods MAX',                'tendencia',  13.00::numeric, '[{"min":100,"usdt":13,"ars":21190}]'::jsonb, 2),
  ('Cargador Original 20W APPLE - PATA RECTA', 'tendencia', 10.85::numeric, '[{"min":100,"usdt":10.85,"ars":17690}]'::jsonb, 3),
  ('Realme C67 - 8GB RAM - Negro - 256GB',     'electronica', 176.00::numeric, '[]'::jsonb, 1),
  ('Realme C71 - 12 GB RAM - Verde - 128GB',   'electronica', 178.00::numeric, '[]'::jsonb, 2),
  ('Angham Second Song - Lattafa', 'cosmetica', 30.00::numeric, '[]'::jsonb, 1),
  ('Ansaam Gold - Lattafa Pride',  'cosmetica', 25.00::numeric, '[]'::jsonb, 2)
) as v(nombre, categoria, precio_usdt, tramos, orden)
where not exists (select 1 from public.productos);

-- =====================================================================
--  ÚLTIMO PASO (manual): crear tu usuario administrador
--   1) Supabase > Authentication > Users > Add user  (email + contraseña)
--   2) Ejecutá esto cambiando el email por el tuyo:
--
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'TU-EMAIL@ejemplo.com';
-- =====================================================================
