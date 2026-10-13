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
  imagenes     jsonb not null default '[]'::jsonb,   -- hasta 6 fotos (la primera es la principal)
  grupo_combinado text not null default '',          -- ej: 'Audio' → los tramos suman unidades entre productos del mismo grupo
  variantes    jsonb not null default '[]'::jsonb,   -- moda: [{"color":"Negro","talle":"M","stock":5}, ...]
  costo_usdt   numeric(12,2) not null default 0,     -- costo por unidad (para calcular la ganancia en Ventas)
  imeis        jsonb not null default '[]'::jsonb,   -- IMEIs / n° de serie disponibles: ["3569...", ...]
  sku          text not null default '',             -- código interno
  moneda       text not null default 'USD' check (moneda in ('USD','ARS')),  -- moneda del costo base: define cómo se guarda y se muestra el producto
  costo_ars    numeric(14,2),                        -- costo por unidad en pesos (solo si moneda = 'ARS')
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
alter table public.productos add column if not exists imagenes jsonb not null default '[]'::jsonb;
alter table public.productos add column if not exists grupo_combinado text not null default '';
alter table public.productos add column if not exists variantes jsonb not null default '[]'::jsonb;
alter table public.productos add column if not exists costo_usdt numeric(12,2) not null default 0;
alter table public.productos add column if not exists imeis jsonb not null default '[]'::jsonb;
alter table public.productos add column if not exists sku text not null default '';
alter table public.productos add column if not exists moneda text not null default 'USD';
alter table public.productos add column if not exists costo_ars numeric(14,2);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'productos_moneda_chk') then
    alter table public.productos add constraint productos_moneda_chk check (moneda in ('USD','ARS'));
  end if;
end $$;

-- Marcas y subcategorías guardadas por sección (para los selects del panel)
create table if not exists public.catalogo_opciones (
  id        uuid primary key default gen_random_uuid(),
  categoria text not null references public.categorias(slug) on update cascade on delete cascade,
  tipo      text not null check (tipo in ('marca','subcategoria')),
  valor     text not null,
  unique (categoria, tipo, valor)
);
create index if not exists productos_categoria_idx on public.productos(categoria);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists productos_touch on public.productos;
create trigger productos_touch before update on public.productos
  for each row execute function public.touch_updated_at();

-- ---------- 4. Clientes (CRM) ----------
create table if not exists public.clientes (
  id              uuid primary key default gen_random_uuid(),
  nombre          text not null,
  dni             text not null default '',
  tipo            text not null default 'minorista' check (tipo in ('minorista','mayorista')),
  telefono        text not null default '',
  codigo_postal   text not null default '',
  localidad       text not null default '',
  direccion       text not null default '',
  empresa_envio   text not null default '',
  email           text not null default '',
  recontacto      int  not null default 0 check (recontacto between 0 and 3),  -- 0 = Principal, 1..3 = recontactos
  ultimo_contacto timestamptz,
  ultima_compra   timestamptz,
  origen          text not null default 'manual',   -- manual | excel | tienda
  created_at      timestamptz not null default now()
);
create unique index if not exists clientes_dni_uq on public.clientes(dni) where dni <> '';

-- ---------- 5. Pedidos ----------
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
alter table public.pedidos add column if not exists empresa_envio text not null default '';
alter table public.pedidos add column if not exists dni           text not null default '';
alter table public.pedidos add column if not exists codigo_postal text not null default '';
alter table public.pedidos add column if not exists localidad     text not null default '';
alter table public.pedidos add column if not exists direccion     text not null default '';
alter table public.pedidos add column if not exists cliente_id    uuid references public.clientes(id) on delete set null;
create index if not exists pedidos_created_idx on public.pedidos(created_at desc);
create index if not exists pedidos_cliente_idx on public.pedidos(cliente_id);

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

-- ---------- 6. Ajustes de la tienda (portada, WhatsApp, cotización…) ----------
create table if not exists public.ajustes (
  clave text primary key,
  valor jsonb not null default '{}'::jsonb
);

-- ---------- 7. Crear pedido desde la tienda ----------
-- Los precios se recalculan acá (el navegador no puede manipularlos).
-- Los tramos mayoristas suman las unidades de todos los productos del mismo "grupo combinado".
-- También crea o actualiza el cliente (por DNI) y lo devuelve a la lista "Principal" del CRM.
drop function if exists public.crear_pedido(text, text, text, jsonb);
create or replace function public.crear_pedido(p_envio jsonb, p_nota text, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cot    numeric := coalesce(
             (select (valor->>'valor')::numeric from ajustes where clave = 'cotizacion'),
             (select (valor->>'cotizacion')::numeric from ajustes where clave = 'tienda'), 0);
  v_nombre text := left(trim(coalesce(p_envio->>'nombre', '')), 120);
  v_dni    text := left(regexp_replace(coalesce(p_envio->>'dni', ''), '\D', '', 'g'), 20);
  v_cp     text := left(trim(coalesce(p_envio->>'cp', '')), 20);
  v_loc    text := left(trim(coalesce(p_envio->>'localidad', '')), 120);
  v_dir    text := left(trim(coalesce(p_envio->>'direccion', '')), 250);
  v_emp    text := left(trim(coalesce(p_envio->>'empresa', '')), 80);
  v_cli    uuid;
  v_id     uuid;
  v_num    bigint;
  it       jsonb;
  tr       jsonb;
  prod     productos%rowtype;
  g        text;
  groups   jsonb := '{}'::jsonb;
  qty      int;
  tq       int;
  u_usdt   numeric;
  u_ars    numeric;
  t_usdt   numeric := 0;
  t_ars    numeric := 0;
begin
  if v_nombre = '' or v_dni = '' or v_cp = '' or v_loc = '' or v_dir = '' then
    raise exception 'Faltan datos de envío';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido está vacío';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'Demasiados productos'; end if;

  -- 1) totales por grupo combinado
  for it in select e from jsonb_array_elements(p_items) as e loop
    qty := (it->>'cantidad')::int;
    if qty is null or qty <= 0 or qty > 100000 then raise exception 'Cantidad inválida'; end if;
    select grupo_combinado into g from productos where id = (it->>'producto_id')::uuid and activo;
    if not found then raise exception 'Un producto del pedido ya no está disponible'; end if;
    if coalesce(g, '') <> '' then
      groups := jsonb_set(groups, array[g], to_jsonb(coalesce((groups->>g)::int, 0) + qty), true);
    end if;
  end loop;

  -- 2) cliente (por DNI)
  select id into v_cli from clientes where dni = v_dni limit 1;
  if v_cli is null then
    insert into clientes (nombre, dni, codigo_postal, localidad, direccion, empresa_envio, origen, ultima_compra)
    values (v_nombre, v_dni, v_cp, v_loc, v_dir, v_emp, 'tienda', now()) returning id into v_cli;
  else
    update clientes set codigo_postal = v_cp, localidad = v_loc, direccion = v_dir,
           empresa_envio = case when v_emp <> '' then v_emp else empresa_envio end,
           ultima_compra = now(), recontacto = 0 where id = v_cli;
  end if;

  -- 3) pedido
  insert into pedidos (cliente_nombre, nota, empresa_envio, dni, codigo_postal, localidad, direccion, cliente_id)
  values (v_nombre, left(coalesce(p_nota, ''), 500), v_emp, v_dni, v_cp, v_loc, v_dir, v_cli)
  returning id, numero into v_id, v_num;

  for it in select e from jsonb_array_elements(p_items) as e loop
    qty := (it->>'cantidad')::int;
    select * into prod from productos where id = (it->>'producto_id')::uuid and activo;
    tq := case when coalesce(prod.grupo_combinado, '') <> '' then (groups->>prod.grupo_combinado)::int else qty end;
    u_usdt := prod.precio_usdt;
    u_ars  := prod.precio_ars;
    for tr in select t.v from jsonb_array_elements(prod.tramos) as t(v) order by (t.v->>'min')::int loop
      if tq >= (tr->>'min')::int then
        u_usdt := (tr->>'usdt')::numeric;
        u_ars  := nullif(tr->>'ars', '')::numeric;
      end if;
    end loop;
    -- producto cuyo costo/precio está en pesos: el precio en pesos es el real y el USDT se deriva de la cotización
    if prod.moneda = 'ARS' and v_cot > 0 and u_ars is not null then u_usdt := round(u_ars / v_cot, 2); end if;
    u_ars := coalesce(u_ars, round(u_usdt * v_cot));

    insert into pedido_items (pedido_id, producto_id, nombre, cantidad, precio_usdt, precio_ars)
    values (v_id, prod.id, prod.nombre, qty, u_usdt, u_ars);
    t_usdt := t_usdt + u_usdt * qty;
    t_ars  := t_ars  + u_ars  * qty;
  end loop;

  update pedidos set total_usdt = t_usdt, total_ars = t_ars where id = v_id;
  return jsonb_build_object('id', v_id, 'numero', v_num, 'total_usdt', t_usdt, 'total_ars', t_ars);
end $$;

revoke all on function public.crear_pedido(jsonb, text, jsonb) from public;
grant execute on function public.crear_pedido(jsonb, text, jsonb) to anon, authenticated;

-- ---------- 8. Seguridad (RLS) ----------
alter table public.admins       enable row level security;
alter table public.categorias   enable row level security;
alter table public.productos    enable row level security;
alter table public.clientes     enable row level security;
alter table public.catalogo_opciones enable row level security;
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

drop policy if exists "catalogo_opciones: admin" on public.catalogo_opciones;
create policy "catalogo_opciones: admin" on public.catalogo_opciones for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "clientes: admin"            on public.clientes;
create policy "clientes: admin" on public.clientes for all using (public.is_admin()) with check (public.is_admin());

-- pedidos: solo el admin los ve; los clientes crean pedidos únicamente con crear_pedido()
drop policy if exists "pedidos: admin"             on public.pedidos;
create policy "pedidos: admin" on public.pedidos for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "pedido_items: admin"        on public.pedido_items;
create policy "pedido_items: admin" on public.pedido_items for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 9. Imágenes (Storage) ----------
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

-- ---------- 9b. Ventas (registro de ventas, vendedores y deudas) ----------
create table if not exists public.vendedores (
  id           uuid primary key default gen_random_uuid(),
  nombre       text not null,
  comision_pct numeric(5,2) not null default 0 check (comision_pct between 0 and 100),
  activo       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table if not exists public.ventas (
  id            uuid primary key default gen_random_uuid(),
  numero        bigint generated always as identity,
  fecha         date not null default current_date,
  cliente_id    uuid references public.clientes(id) on delete set null,
  cliente_nombre text not null default '',
  cliente_dni   text not null default '',
  metodo_pago   text not null default '',
  meta_ads      boolean not null default false,
  vendedor_id   uuid references public.vendedores(id) on delete set null,
  moneda        text not null default 'USD' check (moneda in ('USD','ARS')),
  cotizacion    numeric(14,2) not null default 0,     -- pesos por USDT al momento de la venta
  total_usdt    numeric(14,2) not null default 0,
  total_ars     numeric(16,0) not null default 0,
  costo_usdt    numeric(14,2) not null default 0,
  comision_usdt numeric(14,2) not null default 0,
  pagado_usdt   numeric(14,2) not null default 0,     -- lo cobrado hasta ahora (saldo = total - pagado)
  nota          text not null default '',
  enviado       boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists ventas_fecha_idx   on public.ventas(fecha desc);
create index if not exists ventas_cliente_idx on public.ventas(cliente_id);

create table if not exists public.venta_items (
  id          uuid primary key default gen_random_uuid(),
  venta_id    uuid not null references public.ventas(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete set null,
  nombre      text not null,
  cantidad    int  not null check (cantidad > 0),
  precio_usdt numeric(14,4) not null default 0,
  precio_ars  numeric(16,2) not null default 0,
  costo_usdt  numeric(14,4) not null default 0,
  variante    jsonb,                                  -- {"color":"Negro","talle":"M"} si es un producto con variantes
  imeis       jsonb not null default '[]'::jsonb,
  manual      boolean not null default false
);
create index if not exists venta_items_venta_idx on public.venta_items(venta_id);

alter table public.vendedores  enable row level security;
alter table public.ventas      enable row level security;
alter table public.venta_items enable row level security;
drop policy if exists "vendedores: admin"  on public.vendedores;
create policy "vendedores: admin"  on public.vendedores  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "ventas: admin"      on public.ventas;
create policy "ventas: admin"      on public.ventas      for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "venta_items: admin" on public.venta_items;
create policy "venta_items: admin" on public.venta_items for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 9c. Herramientas: gastos, deudas manuales y préstamos ----------
-- Gastos sueltos (se guardan en USDT con la cotización del momento)
create table if not exists public.gastos (
  id          uuid primary key default gen_random_uuid(),
  concepto    text not null,
  monto       numeric(14,2) not null check (monto > 0),
  moneda      text not null default 'ARS' check (moneda in ('ARS','USD')),
  monto_usdt  numeric(14,2) not null default 0,
  cotizacion  numeric(14,2) not null default 0,
  categoria   text not null default 'otros',
  fecha       date not null default current_date,
  created_at  timestamptz not null default now()
);
create index if not exists gastos_fecha_idx on public.gastos(fecha desc);

-- Gastos fijos: recurrentes, se generan solos todos los meses desde "desde_mes" hasta "baja_mes" (YYYY-MM)
create table if not exists public.gastos_fijos (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  monto      numeric(14,2) not null check (monto > 0),
  moneda     text not null default 'ARS' check (moneda in ('ARS','USD')),
  categoria  text not null default 'otros',
  dia        int check (dia between 1 and 31),         -- día de vencimiento (opcional)
  desde_mes  text not null,
  baja_mes   text,
  created_at timestamptz not null default now()
);
-- Qué fijos ya se pagaron en cada mes
create table if not exists public.gastos_fijos_pagos (
  id        uuid primary key default gen_random_uuid(),
  fijo_id   uuid not null references public.gastos_fijos(id) on delete cascade,
  mes       text not null,
  pagado_en timestamptz not null default now(),
  unique (fijo_id, mes)
);

-- Deudas manuales (lo que te deben fuera de las ventas), con interés mensual simple opcional
create table if not exists public.deudas (
  id              uuid primary key default gen_random_uuid(),
  cliente_id      uuid references public.clientes(id) on delete set null,
  cliente_nombre  text not null,
  cliente_dni     text not null default '',
  monto_usdt      numeric(14,2) not null check (monto_usdt > 0),
  interes_mensual numeric(6,2) not null default 0,
  concepto        text not null default '',
  fecha           date not null default current_date,
  pagado_usdt     numeric(14,2) not null default 0,
  created_at      timestamptz not null default now()
);
create table if not exists public.deuda_pagos (
  id         uuid primary key default gen_random_uuid(),
  deuda_id   uuid not null references public.deudas(id) on delete cascade,
  monto_usdt numeric(14,2) not null,
  nota       text not null default '',
  fecha      timestamptz not null default now()
);

-- Préstamos que recibiste (a quién le debés, con qué interés mensual)
create table if not exists public.prestamos (
  id              uuid primary key default gen_random_uuid(),
  acreedor        text not null,
  capital         numeric(14,2) not null check (capital > 0),
  moneda          text not null default 'USD' check (moneda in ('ARS','USD')),
  interes_mensual numeric(6,2) not null default 0,
  fecha_inicio    date not null default current_date,
  nota            text not null default '',
  capital_pagado  numeric(14,2) not null default 0,
  created_at      timestamptz not null default now()
);
create table if not exists public.prestamo_pagos (
  id          uuid primary key default gen_random_uuid(),
  prestamo_id uuid not null references public.prestamos(id) on delete cascade,
  tipo        text not null check (tipo in ('interes','capital')),
  monto       numeric(14,2) not null check (monto > 0),
  fecha       timestamptz not null default now()
);

alter table public.gastos             enable row level security;
alter table public.gastos_fijos       enable row level security;
alter table public.gastos_fijos_pagos enable row level security;
alter table public.deudas             enable row level security;
alter table public.deuda_pagos        enable row level security;
alter table public.prestamos          enable row level security;
alter table public.prestamo_pagos     enable row level security;
drop policy if exists "gastos: admin"             on public.gastos;
create policy "gastos: admin"             on public.gastos             for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "gastos_fijos: admin"       on public.gastos_fijos;
create policy "gastos_fijos: admin"       on public.gastos_fijos       for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "gastos_fijos_pagos: admin" on public.gastos_fijos_pagos;
create policy "gastos_fijos_pagos: admin" on public.gastos_fijos_pagos for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "deudas: admin"             on public.deudas;
create policy "deudas: admin"             on public.deudas             for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "deuda_pagos: admin"        on public.deuda_pagos;
create policy "deuda_pagos: admin"        on public.deuda_pagos        for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "prestamos: admin"          on public.prestamos;
create policy "prestamos: admin"          on public.prestamos          for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "prestamo_pagos: admin"     on public.prestamo_pagos;
create policy "prestamo_pagos: admin"     on public.prestamo_pagos     for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 9d. Usuarios del panel, roles y comisiones ----------
-- Roles: 'vendedor' · 'vendedor_comision' (premium) · 'admin'.
-- Los usuarios se crean con un nombre de usuario (ej: juanperez) y entran con él en el login del panel
-- (internamente es juanperez@panel.local). Solo un administrador puede crearlos, cambiarles la clave o eliminarlos.
create extension if not exists pgcrypto with schema extensions;

alter table public.vendedores add column if not exists cargo text not null default 'Vendedor Premium';
alter table public.ventas add column if not exists created_by uuid default auth.uid() references auth.users(id) on delete set null;

create table if not exists public.usuarios_panel (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  nombre      text not null,
  usuario     text not null unique,
  rol         text not null default 'vendedor' check (rol in ('vendedor','vendedor_comision','admin')),
  ver_ventas  text not null default 'propias' check (ver_ventas in ('propias','todas')),  -- propias = solo las que registra él
  vendedor_id uuid references public.vendedores(id) on delete set null,                    -- perfil de comisión (rol vendedor_comision)
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Movimientos de comisiones: extras (+), restas (−) y pagos al vendedor
create table if not exists public.comision_movimientos (
  id          uuid primary key default gen_random_uuid(),
  vendedor_id uuid not null references public.vendedores(id) on delete cascade,
  tipo        text not null check (tipo in ('extra','resta','pago')),
  monto_usdt  numeric(14,2) not null check (monto_usdt > 0),
  nota        text not null default '',
  fecha       date not null default current_date,
  created_at  timestamptz not null default now()
);
create index if not exists comision_mov_vend_idx  on public.comision_movimientos(vendedor_id, fecha desc);

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.usuarios_panel where user_id = auth.uid() and activo);
$$;

create or replace function public.ve_todas_las_ventas()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.usuarios_panel where user_id = auth.uid() and activo and ver_ventas = 'todas');
$$;

-- Perfil del usuario que está logueado (null = no tiene acceso al panel)
create or replace function public.panel_mi_perfil()
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare u public.usuarios_panel%rowtype; v_email text;
begin
  select * into u from usuarios_panel where user_id = auth.uid() and activo;
  if is_admin() then
    select email into v_email from auth.users where id = auth.uid();
    return jsonb_build_object('rol','admin','nombre',coalesce(u.nombre, split_part(v_email,'@',1)),'ver_ventas','todas');
  end if;
  if u.user_id is null then return null; end if;
  return jsonb_build_object('rol', case when u.rol = 'admin' then 'vendedor' else u.rol end,
                            'nombre', u.nombre, 'ver_ventas', u.ver_ventas, 'vendedor_id', u.vendedor_id);
end $$;

-- Lista de usuarios (admins existentes + usuarios creados desde el panel)
create or replace function public.panel_listar_usuarios()
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb; v_principal uuid;
begin
  if not is_admin() then raise exception 'Solo un administrador puede ver los usuarios'; end if;
  select user_id into v_principal from admins order by created_at, user_id limit 1;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.principal desc, t.created_at), '[]'::jsonb) into r from (
    select a.user_id,
           coalesce(p.nombre, split_part(au.email,'@',1)) as nombre,
           coalesce(p.usuario, split_part(au.email,'@',1)) as usuario,
           'admin'::text as rol, coalesce(p.ver_ventas,'todas') as ver_ventas, p.vendedor_id,
           coalesce(p.activo,true) as activo, (a.user_id = v_principal) as principal,
           (p.user_id is not null) as tiene_perfil, a.created_at
    from admins a join auth.users au on au.id = a.user_id left join usuarios_panel p on p.user_id = a.user_id
    union all
    select p.user_id, p.nombre, p.usuario, p.rol, p.ver_ventas, p.vendedor_id, p.activo, false, true, p.created_at
    from usuarios_panel p where not exists (select 1 from admins a where a.user_id = p.user_id)
  ) t;
  return r;
end $$;

create or replace function public.panel_crear_usuario(p_nombre text, p_usuario text, p_clave text, p_rol text, p_ver text default 'propias')
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare
  v_uid   uuid := gen_random_uuid();
  v_u     text := lower(regexp_replace(coalesce(p_usuario,''), '\s', '', 'g'));
  v_email text;
  v_vend  uuid;
begin
  if not is_admin() then raise exception 'Solo un administrador puede crear usuarios'; end if;
  if length(trim(coalesce(p_nombre,''))) = 0 then raise exception 'Falta el nombre completo'; end if;
  if v_u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuario inválido (3 a 30 caracteres: letras, números, punto, guion)'; end if;
  if length(coalesce(p_clave,'')) < 6 then raise exception 'La clave debe tener mínimo 6 caracteres'; end if;
  if p_rol not in ('vendedor','vendedor_comision','admin') then raise exception 'Rol inválido'; end if;
  v_email := v_u || '@panel.local';
  if exists (select 1 from auth.users where lower(email) = v_email) or exists (select 1 from usuarios_panel where usuario = v_u) then
    raise exception 'Ese usuario ya existe';
  end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
          crypt(p_clave, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid, v_uid::text,
          jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true), 'email', now(), now(), now());

  if p_rol = 'vendedor_comision' then
    insert into vendedores (nombre, comision_pct) values (trim(p_nombre), 0) returning id into v_vend;
  end if;
  insert into usuarios_panel (user_id, nombre, usuario, rol, ver_ventas, vendedor_id)
  values (v_uid, trim(p_nombre), v_u, p_rol,
          case when p_rol = 'admin' or p_ver = 'todas' then 'todas' else 'propias' end, v_vend);
  if p_rol = 'admin' then insert into admins (user_id) values (v_uid) on conflict do nothing; end if;
  return jsonb_build_object('user_id', v_uid, 'usuario', v_u);
end $$;

create or replace function public.panel_cambiar_clave(p_user uuid, p_clave text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  if not is_admin() then raise exception 'Solo un administrador puede cambiar claves'; end if;
  if length(coalesce(p_clave,'')) < 6 then raise exception 'La clave debe tener mínimo 6 caracteres'; end if;
  update auth.users set encrypted_password = crypt(p_clave, gen_salt('bf')), updated_at = now() where id = p_user;
  if not found then raise exception 'Usuario inexistente'; end if;
end $$;

create or replace function public.panel_cambiar_usuario(p_user uuid, p_usuario text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_u text := lower(regexp_replace(coalesce(p_usuario,''), '\s', '', 'g')); v_email text;
begin
  if not is_admin() then raise exception 'Solo un administrador puede cambiar usuarios'; end if;
  if v_u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuario inválido (3 a 30 caracteres: letras, números, punto, guion)'; end if;
  if not exists (select 1 from usuarios_panel where user_id = p_user) then raise exception 'Este usuario no se puede renombrar'; end if;
  v_email := v_u || '@panel.local';
  if exists (select 1 from auth.users where lower(email) = v_email and id <> p_user)
     or exists (select 1 from usuarios_panel where usuario = v_u and user_id <> p_user) then
    raise exception 'Ese usuario ya existe';
  end if;
  update auth.users set email = v_email, updated_at = now() where id = p_user;
  update auth.identities set identity_data = identity_data || jsonb_build_object('email', v_email), updated_at = now() where user_id = p_user and provider = 'email';
  update usuarios_panel set usuario = v_u where user_id = p_user;
end $$;

create or replace function public.panel_eliminar_usuario(p_user uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Solo un administrador puede eliminar usuarios'; end if;
  if p_user = auth.uid() then raise exception 'No podés eliminar tu propia cuenta'; end if;
  if p_user = (select user_id from admins order by created_at, user_id limit 1) then raise exception 'No se puede eliminar la cuenta principal'; end if;
  update vendedores set activo = false where id = (select vendedor_id from usuarios_panel where user_id = p_user);
  delete from auth.users where id = p_user;   -- borra en cascada su perfil y su permiso de admin
end $$;

-- "Verificar en la nube": revisa que cada usuario tenga su acceso completo y repara lo que falte
create or replace function public.panel_verificar_usuarios()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare p record; v_tot int := 0; v_fix jsonb := '[]'::jsonb; v_vend uuid;
begin
  if not is_admin() then raise exception 'Solo un administrador puede verificar usuarios'; end if;
  for p in select * from usuarios_panel loop
    v_tot := v_tot + 1;
    if p.rol = 'admin' and not exists (select 1 from admins where user_id = p.user_id) then
      insert into admins (user_id) values (p.user_id) on conflict do nothing;
      v_fix := v_fix || to_jsonb(p.usuario || ': permisos de administrador restaurados');
    end if;
    if p.rol = 'vendedor_comision' and (p.vendedor_id is null or not exists (select 1 from vendedores where id = p.vendedor_id)) then
      insert into vendedores (nombre, comision_pct) values (p.nombre, 0) returning id into v_vend;
      update usuarios_panel set vendedor_id = v_vend where user_id = p.user_id;
      v_fix := v_fix || to_jsonb(p.usuario || ': perfil de comisión recreado');
    end if;
    update auth.users set email_confirmed_at = now() where id = p.user_id and email_confirmed_at is null;
  end loop;
  return jsonb_build_object('total', v_tot, 'admins', (select count(*) from admins), 'arreglos', v_fix);
end $$;

-- Descontar / devolver stock al vender (lo usan también los vendedores, que no pueden editar productos)
create or replace function public.panel_ajustar_stock(p_id uuid, p_stock int, p_variantes jsonb, p_imeis jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Sin permiso'; end if;
  update productos set stock = p_stock, variantes = coalesce(p_variantes, variantes), imeis = coalesce(p_imeis, imeis) where id = p_id;
end $$;

revoke all on function public.panel_crear_usuario(text,text,text,text,text) from public, anon;
revoke all on function public.panel_cambiar_clave(uuid,text) from public, anon;
revoke all on function public.panel_cambiar_usuario(uuid,text) from public, anon;
revoke all on function public.panel_eliminar_usuario(uuid) from public, anon;
revoke all on function public.panel_listar_usuarios() from public, anon;
revoke all on function public.panel_verificar_usuarios() from public, anon;
revoke all on function public.panel_ajustar_stock(uuid,int,jsonb,jsonb) from public, anon;
revoke all on function public.panel_mi_perfil() from public, anon;
grant execute on function public.panel_crear_usuario(text,text,text,text,text) to authenticated;
grant execute on function public.panel_cambiar_clave(uuid,text) to authenticated;
grant execute on function public.panel_cambiar_usuario(uuid,text) to authenticated;
grant execute on function public.panel_eliminar_usuario(uuid) to authenticated;
grant execute on function public.panel_listar_usuarios() to authenticated;
grant execute on function public.panel_verificar_usuarios() to authenticated;
grant execute on function public.panel_ajustar_stock(uuid,int,jsonb,jsonb) to authenticated;
grant execute on function public.panel_mi_perfil() to authenticated;

alter table public.usuarios_panel        enable row level security;
alter table public.comision_movimientos  enable row level security;
drop policy if exists "usuarios_panel: admin"  on public.usuarios_panel;
create policy "usuarios_panel: admin"  on public.usuarios_panel for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "usuarios_panel: propio" on public.usuarios_panel;
create policy "usuarios_panel: propio" on public.usuarios_panel for select using (user_id = auth.uid());
drop policy if exists "comision_mov: admin"    on public.comision_movimientos;
create policy "comision_mov: admin"    on public.comision_movimientos for all using (public.is_admin()) with check (public.is_admin());

-- Permisos de los vendedores (staff): registran ventas y clientes, y ven solo lo que les corresponde.
-- No ven pedidos, gastos, deudores, préstamos, inventario ni ajustes.
drop policy if exists "clientes: staff leer"   on public.clientes;
create policy "clientes: staff leer"   on public.clientes for select using (public.is_staff());
drop policy if exists "clientes: staff crea"   on public.clientes;
create policy "clientes: staff crea"   on public.clientes for insert with check (public.is_staff());
drop policy if exists "clientes: staff edita"  on public.clientes;
create policy "clientes: staff edita"  on public.clientes for update using (public.is_staff()) with check (public.is_staff());
drop policy if exists "vendedores: staff leer" on public.vendedores;
create policy "vendedores: staff leer" on public.vendedores for select using (public.is_staff());
drop policy if exists "ventas: staff leer"     on public.ventas;
create policy "ventas: staff leer"     on public.ventas for select
  using (public.is_staff() and (public.ve_todas_las_ventas() or created_by = auth.uid()));
drop policy if exists "ventas: staff crea"     on public.ventas;
create policy "ventas: staff crea"     on public.ventas for insert with check (public.is_staff() and created_by = auth.uid());
drop policy if exists "venta_items: staff leer" on public.venta_items;
create policy "venta_items: staff leer" on public.venta_items for select
  using (public.is_staff() and exists (select 1 from public.ventas v where v.id = venta_id));
drop policy if exists "venta_items: staff crea" on public.venta_items;
create policy "venta_items: staff crea" on public.venta_items for insert
  with check (public.is_staff() and exists (select 1 from public.ventas v where v.id = venta_id and v.created_by = auth.uid()));

-- ---------- 10. Datos iniciales ----------
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

-- Cotización de la tienda (la actualiza el panel con el valor en vivo + el % de interés)
insert into public.ajustes (clave, valor) values ('cotizacion',
  '{"base":"cripto","interes":1.5,"valor":1630,"auto":true,"manual":"","respaldo":1500}'::jsonb)
on conflict (clave) do nothing;
-- Instalaciones anteriores: agrega los campos nuevos (cotización manual y dólar de respaldo)
update public.ajustes set valor = valor || '{"respaldo":1500}'::jsonb where clave = 'cotizacion' and not (valor ? 'respaldo');
update public.ajustes set valor = valor || '{"manual":""}'::jsonb   where clave = 'cotizacion' and not (valor ? 'manual');

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

-- ---------- 9e. Catálogo conectado con el inventario + reglas de precio ----------
-- Un producto del catálogo (lo que ve la tienda) puede vincularse a un producto del
-- inventario: el stock, las variantes, los IMEIs y el costo se sincronizan solos
-- en los dos sentidos. El producto de inventario vinculado deja de mostrarse en la tienda.
alter table public.productos add column if not exists descripcion text not null default '';
alter table public.productos add column if not exists precio_mentoria numeric(12,2);
alter table public.productos add column if not exists sin_stock boolean not null default false;
alter table public.productos add column if not exists solo_inventario boolean not null default false;
alter table public.productos add column if not exists inventario_id uuid references public.productos(id) on delete set null;
create index if not exists productos_inventario_idx on public.productos (inventario_id);

create or replace function public.productos_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- evita rebotes entre filas vinculadas

  -- cambió el vínculo con el inventario
  if TG_OP = 'INSERT' or NEW.inventario_id is distinct from OLD.inventario_id then
    if NEW.inventario_id is not null then
      update productos set solo_inventario = true where id = NEW.inventario_id and not solo_inventario;
      update productos c set stock = i.stock, variantes = i.variantes, imeis = i.imeis,
             costo_usdt = i.costo_usdt, costo_ars = i.costo_ars
        from productos i where c.id = NEW.id and i.id = NEW.inventario_id;
    end if;
    if TG_OP = 'UPDATE' and OLD.inventario_id is not null then
      update productos set solo_inventario = exists (select 1 from productos x where x.inventario_id = OLD.inventario_id)
       where id = OLD.inventario_id;
    end if;
    return null;
  end if;

  -- cambió stock / variantes / IMEIs / costo
  if NEW.stock is distinct from OLD.stock or NEW.variantes is distinct from OLD.variantes
     or NEW.imeis is distinct from OLD.imeis or NEW.costo_usdt is distinct from OLD.costo_usdt
     or NEW.costo_ars is distinct from OLD.costo_ars then
    if NEW.inventario_id is not null then      -- la tienda vendió: baja el inventario
      update productos set stock = NEW.stock, variantes = NEW.variantes, imeis = NEW.imeis
       where id = NEW.inventario_id
         and (stock is distinct from NEW.stock or variantes is distinct from NEW.variantes or imeis is distinct from NEW.imeis);
    end if;
    update productos set stock = NEW.stock, variantes = NEW.variantes, imeis = NEW.imeis,
           costo_usdt = NEW.costo_usdt, costo_ars = NEW.costo_ars
     where inventario_id = NEW.id;             -- el inventario cambió: se actualiza el catálogo
  end if;
  return null;
end $$;

drop trigger if exists productos_sync on public.productos;
create trigger productos_sync after insert or update on public.productos
  for each row execute function public.productos_sync();

-- la tienda no muestra los productos que sólo sirven de inventario
drop policy if exists "productos: lectura" on public.productos;
create policy "productos: lectura" on public.productos for select
  using ((activo and not solo_inventario) or public.is_admin());

-- reglas de ganancia (clave 'reglas_precio'): solo las ve el administrador
insert into public.ajustes (clave, valor) values ('reglas_precio', '{}'::jsonb) on conflict (clave) do nothing;
drop policy if exists "ajustes: lectura" on public.ajustes;
create policy "ajustes: lectura" on public.ajustes for select using (clave <> 'reglas_precio' or public.is_admin());


-- =====================================================================
--  ÚLTIMO PASO (manual): crear tu usuario administrador
--   1) Supabase > Authentication > Users > Add user  (email + contraseña)
--   2) Ejecutá esto cambiando el email por el tuyo:
--
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'TU-EMAIL@ejemplo.com';
-- =====================================================================