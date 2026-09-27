-- =============================================================================
-- WESNOCK — Esquema de base de datos para Supabase
-- -----------------------------------------------------------------------------
-- Cómo usarlo: Supabase → SQL Editor → New query → pegar TODO este archivo → Run.
-- Es re-ejecutable: puedes volver a correrlo sin perder datos.
--
-- Contenido
--   1. Tablas            (configuración, categorías, perfiles, productos, costos,
--                         variantes/stock, pedidos, líneas, historial, inventario,
--                         favoritos, cupones y gastos preparados para el futuro)
--   2. Funciones base    (is_admin, updated_at, perfiles automáticos, log de stock)
--   3. RPC de negocio    (create_order atómico, estados, eliminar pedido, stock,
--                         guardar/importar productos, eliminar cliente, mis pedidos)
--   4. Seguridad RLS     (roles admin / client)
--   5. Storage, Realtime y datos iniciales
--
-- Seguridad: el frontend solo usa la clave pública (publishable/anon). Toda
-- operación sensible (stock, pedidos, costos) se valida aquí, en el servidor.
-- =============================================================================

create extension if not exists pgcrypto;

-- =============================================================================
-- 1. TABLAS
-- =============================================================================

-- Configuración pública de la tienda (WhatsApp, envíos, pagos, inventario…)
create table if not exists public.store_settings (
  key         text primary key,
  value       jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

create table if not exists public.categories (
  slug    text primary key,
  nombre  text not null,
  grupo   text not null check (grupo in ('ropa','calzado','accesorios')),
  orden   int  not null default 0
);

-- Perfil de cada usuario de Supabase Auth. role: 'admin' | 'client'
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  role            text not null default 'client' check (role in ('admin','client')),
  email           text,
  nombre          text not null default '',
  telefono        text not null default '',
  ciudad          text not null default '',
  direccion       text not null default '',
  barrio          text not null default '',
  info_adicional  text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table if not exists public.products (
  id               text primary key,
  ref              text not null unique,
  nombre           text not null,
  slug             text not null unique,
  categoria        text not null references public.categories(slug) on update cascade,
  linea            text,
  genero           text check (genero in ('hombre','mujer','nino')),
  precio           numeric(12,0) check (precio >= 0),           -- null = precio a confirmar
  precio_anterior  numeric(12,0) check (precio_anterior >= 0),
  descripcion      text not null default '',
  imagenes         jsonb not null default '[]'::jsonb,           -- [{src, color}]
  colores          jsonb not null default '[]'::jsonb,           -- [{nombre, hex}]
  guia_tallas      text,
  visible          boolean not null default true,                -- visibilidad manual
  destacado        boolean not null default false,
  en_oferta        boolean not null default false,
  orden            int not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Costo del producto: tabla aparte para que NUNCA sea visible para clientes.
create table if not exists public.product_costs (
  product_id  text primary key references public.products(id) on delete cascade,
  costo       numeric(12,0) check (costo >= 0),                  -- null = costo no registrado
  updated_at  timestamptz not null default now()
);

-- Variantes (talla × color) con stock propio.
-- stock null = inventario aún no registrado (no se controla ni se descuenta).
create table if not exists public.product_variants (
  id          bigint generated always as identity primary key,
  product_id  text not null references public.products(id) on delete cascade,
  talla       text not null,
  color       text not null default '',                          -- '' = sin color
  stock       int check (stock >= 0),
  precio      numeric(12,0) check (precio >= 0),                 -- precio propio opcional
  unique (product_id, talla, color)
);
create index if not exists product_variants_product_idx on public.product_variants(product_id);

create sequence if not exists public.order_number_seq;

create table if not exists public.orders (
  id                uuid primary key default gen_random_uuid(),
  numero            text not null unique,
  user_id           uuid references auth.users(id) on delete set null,
  cliente           jsonb not null,               -- copia (snapshot) de los datos del cliente
  metodo_pago       text not null,
  estado            text not null default 'nuevo'
                    check (estado in ('nuevo','confirmado','pago_pendiente','pagado','preparando','enviado','entregado','cancelado')),
  subtotal          numeric(12,0) not null default 0,
  descuento         numeric(12,0) not null default 0,   -- preparado para cupones/promociones
  cupon_codigo      text,
  envio             numeric(12,0),                      -- null = a coordinar
  total             numeric(12,0) not null default 0,
  items_sin_precio  int not null default 0,
  nota_admin        text not null default '',
  canal             text not null default 'web',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists orders_user_idx on public.orders(user_id);
create index if not exists orders_created_idx on public.orders(created_at desc);

-- Líneas del pedido: guardan precio y COSTO del momento de la venta.
create table if not exists public.order_items (
  id                bigint generated always as identity primary key,
  order_id          uuid not null references public.orders(id) on delete cascade,
  product_id        text references public.products(id) on delete set null,
  variant_id        bigint references public.product_variants(id) on delete set null,
  ref               text,
  nombre            text not null,
  talla             text not null,
  color             text,
  cantidad          int not null check (cantidad > 0),
  precio_unitario   numeric(12,0),                  -- precio de venta de esa unidad
  costo_unitario    numeric(12,0),                  -- costo al momento de la venta (null = no registrado)
  subtotal          numeric(12,0) generated always as (precio_unitario * cantidad) stored,
  costo_total       numeric(12,0) generated always as (costo_unitario * cantidad) stored,
  ganancia_bruta    numeric(12,0) generated always as ((precio_unitario - costo_unitario) * cantidad) stored,
  imagen            text,
  stock_descontado  int not null default 0          -- unidades actualmente descontadas del inventario
);
create index if not exists order_items_order_idx on public.order_items(order_id);
create index if not exists order_items_product_idx on public.order_items(product_id);

create table if not exists public.order_status_history (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references public.orders(id) on delete cascade,
  estado      text not null,
  por         text not null default 'sistema',
  created_at  timestamptz not null default now()
);
create index if not exists order_history_order_idx on public.order_status_history(order_id);

-- Historial de movimientos de inventario (se llena automáticamente por trigger).
create table if not exists public.inventory_movements (
  id              bigint generated always as identity primary key,
  variant_id      bigint references public.product_variants(id) on delete set null,
  product_id      text,
  talla           text,
  color           text,
  tipo            text not null check (tipo in ('entrada','venta','devolucion','ajuste','cancelacion','reactivacion','eliminacion_pedido','otro')),
  cantidad        int not null,                    -- positivo = entra, negativo = sale
  stock_anterior  int,
  stock_nuevo     int,
  order_id        uuid,
  nota            text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);
create index if not exists inventory_movements_created_idx on public.inventory_movements(created_at desc);

create table if not exists public.favorites (
  user_id     uuid not null references auth.users(id) on delete cascade,
  product_id  text not null references public.products(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, product_id)
);

-- PREPARADO PARA EL FUTURO: cupones / descuentos / beneficios (aún sin reglas).
create table if not exists public.coupons (
  id                 bigint generated always as identity primary key,
  codigo             text not null unique,
  tipo               text not null check (tipo in ('porcentaje','monto_fijo','cantidad','envio_gratis','personalizado')),
  valor              numeric(12,2) not null default 0,
  minimo_compra      numeric(12,0),
  max_usos           int,
  usos               int not null default 0,
  solo_registrados   boolean not null default false,
  user_id            uuid references auth.users(id) on delete cascade,   -- cupón personal
  condiciones        jsonb not null default '{}'::jsonb,                  -- p.ej. {"min_pedidos": 5}
  activo             boolean not null default false,
  inicia             timestamptz,
  termina            timestamptz,
  created_at         timestamptz not null default now()
);

-- PREPARADO PARA EL FUTURO: gastos operativos (para calcular utilidad neta).
create table if not exists public.expenses (
  id           bigint generated always as identity primary key,
  fecha        date not null default current_date,
  categoria    text not null check (categoria in ('envio','publicidad','comision','impuesto','salario','otro')),
  monto        numeric(12,0) not null check (monto >= 0),
  descripcion  text not null default '',
  order_id     uuid references public.orders(id) on delete set null,
  created_at   timestamptz not null default now()
);

-- =============================================================================
-- 2. FUNCIONES BASE Y TRIGGERS
-- =============================================================================

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists products_touch on public.products;
create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();

-- Crear perfil automáticamente al registrarse un usuario
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, nombre, telefono)
  values (new.id, new.email,
          left(coalesce(new.raw_user_meta_data->>'nombre', ''), 120),
          left(coalesce(new.raw_user_meta_data->>'telefono', ''), 30))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.sync_user_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end $$;
drop trigger if exists on_auth_user_email on auth.users;
create trigger on_auth_user_email after update of email on auth.users for each row execute function public.sync_user_email();

-- Un cliente no puede convertirse en admin (el rol solo se cambia desde el SQL Editor)
create or replace function public.protect_profile_role()
returns trigger language plpgsql as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null and not public.is_admin() then
    raise exception 'NO_AUTORIZADO';
  end if;
  return new;
end $$;
drop trigger if exists profiles_protect_role on public.profiles;
create trigger profiles_protect_role before update on public.profiles for each row execute function public.protect_profile_role();

-- Registrar TODO cambio de stock en inventory_movements.
-- Las funciones RPC indican el motivo con set_config('wsk.mov_tipo', ...).
create or replace function public.log_stock_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old int := case when tg_op = 'UPDATE' then old.stock else null end;
  v_tipo text := nullif(current_setting('wsk.mov_tipo', true), '');
begin
  if new.stock is not distinct from v_old then return new; end if;
  if new.stock is null then return new; end if;  -- se deja de controlar inventario
  insert into public.inventory_movements (variant_id, product_id, talla, color, tipo, cantidad, stock_anterior, stock_nuevo, order_id, nota, created_by)
  values (new.id, new.product_id, new.talla, nullif(new.color, ''),
          coalesce(v_tipo, case when tg_op = 'INSERT' or v_old is null then 'entrada' else 'ajuste' end),
          new.stock - coalesce(v_old, 0), v_old, new.stock,
          nullif(current_setting('wsk.mov_order', true), '')::uuid,
          nullif(current_setting('wsk.mov_nota', true), ''),
          auth.uid());
  return new;
end $$;
drop trigger if exists variants_log_stock on public.product_variants;
create trigger variants_log_stock after insert or update of stock on public.product_variants
  for each row execute function public.log_stock_change();

create or replace function public._mov(p_tipo text, p_order uuid, p_nota text)
returns void language sql as $$
  select set_config('wsk.mov_tipo', coalesce(p_tipo, ''), true),
         set_config('wsk.mov_order', coalesce(p_order::text, ''), true),
         set_config('wsk.mov_nota', coalesce(p_nota, ''), true);
$$;

-- =============================================================================
-- 3. RPC DE NEGOCIO
-- =============================================================================

-- Punto de extensión para cupones, clientes frecuentes y promociones.
-- Hoy no aplica ninguna regla: devuelve 0. Implementar aquí cuando se definan.
create or replace function public.order_discount(p_user uuid, p_subtotal numeric, p_cupon text)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  return 0;
end $$;

-- CREAR PEDIDO — atómico: valida, bloquea variantes, descuenta stock y crea el pedido
-- en una sola transacción. Precios y costos se toman del servidor, nunca del navegador.
-- p_items: [{"variant_id": 123, "cantidad": 2}, …]
create or replace function public.create_order(p_items jsonb, p_cliente jsonb, p_metodo_pago text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pagos    jsonb := coalesce((select value from store_settings where key = 'pagos'), '{}'::jsonb);
  v_ped      jsonb := coalesce((select value from store_settings where key = 'pedidos'), '{}'::jsonb);
  v_cat      jsonb := coalesce((select value from store_settings where key = 'catalogo'), '{}'::jsonb);
  v_order    uuid := gen_random_uuid();
  v_seq      text;
  v_digits   int := coalesce((v_ped->>'digitos')::int, 4);
  v_numero   text;
  v_cli      jsonb;
  r          record;
  v          record;
  v_price    numeric;
  v_img      text;
  v_sub      numeric := 0;
  v_pending  int := 0;
  v_envio    numeric := (v_ped->>'costoEnvio')::numeric;
  v_desc     numeric := 0;
begin
  if p_metodo_pago is null or coalesce((v_pagos->p_metodo_pago->>'activo')::boolean, false) = false then
    raise exception 'METODO_PAGO_INVALIDO';
  end if;

  v_cli := jsonb_build_object(
    'nombre',         left(btrim(coalesce(p_cliente->>'nombre', '')), 120),
    'telefono',       left(btrim(coalesce(p_cliente->>'telefono', '')), 30),
    'email',          left(lower(btrim(coalesce(p_cliente->>'email', ''))), 160),
    'ciudad',         left(btrim(coalesce(p_cliente->>'ciudad', '')), 80),
    'direccion',      left(btrim(coalesce(p_cliente->>'direccion', '')), 200),
    'barrio',         left(btrim(coalesce(p_cliente->>'barrio', '')), 80),
    'info_adicional', left(btrim(coalesce(p_cliente->>'info_adicional', '')), 500));
  if v_cli->>'nombre' = '' or v_cli->>'ciudad' = '' or v_cli->>'direccion' = '' or v_cli->>'barrio' = '' then
    raise exception 'DATOS_INCOMPLETOS';
  end if;
  if length(regexp_replace(v_cli->>'telefono', '\D', '', 'g')) < 7 then
    raise exception 'TELEFONO_INVALIDO';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'CARRITO_VACIO';
  end if;
  if jsonb_array_length(p_items) > 60 then raise exception 'CARRITO_DEMASIADO_GRANDE'; end if;

  -- Número de pedido correlativo
  v_seq := nextval('public.order_number_seq')::text;
  v_numero := coalesce(v_ped->>'prefijo', 'WES-') || case when length(v_seq) >= v_digits then v_seq else lpad(v_seq, v_digits, '0') end;

  insert into orders (id, numero, user_id, cliente, metodo_pago, estado)
  values (v_order, v_numero, auth.uid(), v_cli, p_metodo_pago, 'nuevo');

  -- Recorrer variantes en orden de id (evita bloqueos cruzados) y bloquearlas (FOR UPDATE)
  for r in
    select (e->>'variant_id')::bigint as vid, sum((e->>'cantidad')::int)::int as qty
    from jsonb_array_elements(p_items) e group by 1 order by 1
  loop
    if r.qty is null or r.qty < 1 or r.qty > 99 then raise exception 'CANTIDAD_INVALIDA'; end if;

    select pv.id, pv.product_id, pv.talla, pv.color, pv.stock, pv.precio as v_precio,
           p.nombre, p.ref, p.precio as p_precio, p.visible, p.imagenes, pc.costo
      into v
      from product_variants pv
      join products p on p.id = pv.product_id
      left join product_costs pc on pc.product_id = p.id
     where pv.id = r.vid
       for update of pv;

    if not found then raise exception 'VARIANTE_NO_EXISTE'; end if;
    if not v.visible then raise exception 'PRODUCTO_NO_DISPONIBLE:%', v.nombre; end if;
    if v.stock is not null and v.stock < r.qty then
      raise exception 'STOCK_INSUFICIENTE:% · talla %|%', v.nombre, v.talla, v.stock;
    end if;

    v_price := coalesce(v.v_precio, v.p_precio);
    if v_price is null and coalesce((v_cat->>'permitirSinPrecio')::boolean, true) = false then
      raise exception 'PRECIO_NO_DISPONIBLE:%', v.nombre;
    end if;
    if v_price is null then v_pending := v_pending + 1; else v_sub := v_sub + v_price * r.qty; end if;

    select coalesce(
             (select e->>'src' from jsonb_array_elements(v.imagenes) e where coalesce(e->>'color', '') = v.color and v.color <> '' limit 1),
             v.imagenes->0->>'src')
      into v_img;

    if v.stock is not null then
      perform _mov('venta', v_order, v_numero);
      update product_variants set stock = stock - r.qty where id = v.id;
    end if;

    insert into order_items (order_id, product_id, variant_id, ref, nombre, talla, color, cantidad,
                             precio_unitario, costo_unitario, imagen, stock_descontado)
    values (v_order, v.product_id, v.id, v.ref, v.nombre, v.talla, nullif(v.color, ''), r.qty,
            v_price, v.costo, v_img, case when v.stock is not null then r.qty else 0 end);
  end loop;

  v_desc := least(v_sub, greatest(0, coalesce(order_discount(auth.uid(), v_sub, null), 0)));

  update orders set subtotal = v_sub, descuento = v_desc, envio = v_envio,
                    total = v_sub - v_desc + coalesce(v_envio, 0), items_sin_precio = v_pending
   where id = v_order;
  insert into order_status_history (order_id, estado, por) values (v_order, 'nuevo', case when auth.uid() is null then 'cliente invitado' else 'cliente' end);

  -- Respuesta para la página de confirmación (sin costos)
  return (
    select jsonb_build_object(
      'id', o.id, 'numero', o.numero, 'created_at', o.created_at, 'estado', o.estado,
      'cliente', o.cliente, 'metodo_pago', o.metodo_pago, 'subtotal', o.subtotal,
      'descuento', o.descuento, 'envio', o.envio, 'total', o.total, 'items_sin_precio', o.items_sin_precio,
      'items', (select jsonb_agg(jsonb_build_object('ref', i.ref, 'nombre', i.nombre, 'talla', i.talla, 'color', i.color,
                                   'cantidad', i.cantidad, 'precio_unitario', i.precio_unitario, 'subtotal', i.subtotal, 'imagen', i.imagen) order by i.id)
                from order_items i where i.order_id = o.id))
    from orders o where o.id = v_order);
end $$;

-- Devolver al inventario lo descontado por un pedido (uso interno)
create or replace function public._restock_order(p_order uuid, p_tipo text, p_numero text)
returns void language plpgsql security definer set search_path = public as $$
declare it record;
begin
  for it in select i.id, i.variant_id, i.stock_descontado from order_items i
             where i.order_id = p_order and i.stock_descontado > 0 and i.variant_id is not null
             order by i.variant_id
  loop
    perform 1 from product_variants where id = it.variant_id for update;
    perform _mov(p_tipo, p_order, p_numero);
    update product_variants set stock = stock + it.stock_descontado where id = it.variant_id and stock is not null;
    update order_items set stock_descontado = 0 where id = it.id;
  end loop;
end $$;

-- Volver a descontar stock (cuando un pedido cancelado se reactiva) (uso interno)
create or replace function public._deduct_order(p_order uuid, p_tipo text, p_numero text)
returns void language plpgsql security definer set search_path = public as $$
declare it record; s int;
begin
  for it in select i.id, i.variant_id, i.cantidad, i.nombre, i.talla from order_items i
             where i.order_id = p_order and i.stock_descontado = 0 and i.variant_id is not null
             order by i.variant_id
  loop
    select stock into s from product_variants where id = it.variant_id for update;
    if s is null then continue; end if;
    if s < it.cantidad then raise exception 'STOCK_INSUFICIENTE:% · talla %|%', it.nombre, it.talla, s; end if;
    perform _mov(p_tipo, p_order, p_numero);
    update product_variants set stock = stock - it.cantidad where id = it.variant_id;
    update order_items set stock_descontado = it.cantidad where id = it.id;
  end loop;
end $$;

revoke all on function public._restock_order(uuid, text, text) from public, anon, authenticated;
revoke all on function public._deduct_order(uuid, text, text) from public, anon, authenticated;
revoke all on function public._mov(text, uuid, text) from public, anon, authenticated;

-- CAMBIAR ESTADO (admin). Cancelar devuelve stock; reactivar lo vuelve a descontar.
create or replace function public.admin_set_order_status(p_order_id uuid, p_estado text)
returns text language plpgsql security definer set search_path = public as $$
declare o record; v_flow text[]; v_email text;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  select * into o from orders where id = p_order_id for update;
  if not found then raise exception 'PEDIDO_NO_EXISTE'; end if;
  v_flow := case when o.metodo_pago = 'transferencia'
                 then array['nuevo','confirmado','pago_pendiente','pagado','preparando','enviado','entregado']
                 else array['nuevo','confirmado','preparando','enviado','entregado'] end;
  if not (p_estado = any (v_flow) or p_estado = 'cancelado') then raise exception 'ESTADO_INVALIDO'; end if;
  if o.estado = p_estado then return o.estado; end if;

  if p_estado = 'cancelado' then
    perform _restock_order(o.id, 'cancelacion', o.numero);
  elsif o.estado = 'cancelado' then
    perform _deduct_order(o.id, 'reactivacion', o.numero);
  end if;

  select email into v_email from profiles where id = auth.uid();
  update orders set estado = p_estado where id = o.id;
  insert into order_status_history (order_id, estado, por) values (o.id, p_estado, 'admin ' || coalesce(v_email, ''));
  return p_estado;
end $$;

-- ELIMINAR PEDIDO (admin). Si p_restock, devuelve al inventario lo que siga descontado.
create or replace function public.admin_delete_order(p_order_id uuid, p_restock boolean default true)
returns text language plpgsql security definer set search_path = public as $$
declare o record;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  select * into o from orders where id = p_order_id for update;
  if not found then raise exception 'PEDIDO_NO_EXISTE'; end if;
  if p_restock then perform _restock_order(o.id, 'eliminacion_pedido', o.numero); end if;
  delete from orders where id = o.id;
  return o.numero;
end $$;

create or replace function public.admin_update_order_note(p_order_id uuid, p_nota text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  update orders set nota_admin = left(coalesce(p_nota, ''), 2000) where id = p_order_id;
end $$;

-- AJUSTAR STOCK de una variante (admin). p_tipo: entrada | ajuste | devolucion | otro
create or replace function public.admin_set_stock(p_variant_id bigint, p_stock int, p_tipo text default 'ajuste', p_nota text default null)
returns int language plpgsql security definer set search_path = public as $$
declare s int;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  if p_stock is not null and p_stock < 0 then raise exception 'STOCK_NEGATIVO'; end if;
  if p_tipo not in ('entrada','ajuste','devolucion','otro') then raise exception 'TIPO_INVALIDO'; end if;
  select stock into s from product_variants where id = p_variant_id for update;
  if not found then raise exception 'VARIANTE_NO_EXISTE'; end if;
  perform _mov(p_tipo, null, p_nota);
  update product_variants set stock = p_stock where id = p_variant_id;
  return p_stock;
end $$;

-- Asignar stock a todas las variantes que aún no tienen inventario registrado (admin)
create or replace function public.admin_init_unset_stock(p_stock int, p_categoria text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  if p_stock is null or p_stock < 0 then raise exception 'STOCK_NEGATIVO'; end if;
  perform _mov('entrada', null, 'Registro inicial de inventario');
  update product_variants pv set stock = p_stock
   where pv.stock is null
     and (p_categoria is null or exists (select 1 from products p where p.id = pv.product_id and p.categoria = p_categoria));
  get diagnostics n = row_count;
  return n;
end $$;

-- GUARDAR PRODUCTO (admin): producto + costo + variantes en una sola transacción.
-- Para variantes existentes se envía stock_original (el valor que vio el admin):
-- si mientras tanto hubo ventas, se aplica solo la DIFERENCIA para no pisar el stock.
create or replace function public.admin_save_product(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_id text := coalesce(nullif(p->>'id', ''), 'p_' || replace(gen_random_uuid()::text, '-', ''));
  e jsonb; cur int; v_new int; v_desired int; v_orig int; v_keep bigint[]; v_vid bigint;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  if coalesce(btrim(p->>'nombre'), '') = '' then raise exception 'NOMBRE_REQUERIDO'; end if;
  if jsonb_typeof(p->'variantes') <> 'array' or jsonb_array_length(p->'variantes') = 0 then raise exception 'VARIANTES_REQUERIDAS'; end if;

  insert into products (id, ref, nombre, slug, categoria, linea, genero, precio, precio_anterior, descripcion,
                        imagenes, colores, guia_tallas, visible, destacado, en_oferta, orden)
  values (v_id, coalesce(nullif(p->>'ref', ''), v_id), btrim(p->>'nombre'), coalesce(nullif(p->>'slug', ''), v_id), p->>'categoria',
          nullif(p->>'linea', ''), nullif(p->>'genero', ''), (p->>'precio')::numeric, (p->>'precio_anterior')::numeric,
          coalesce(p->>'descripcion', ''), coalesce(p->'imagenes', '[]'::jsonb), coalesce(p->'colores', '[]'::jsonb),
          nullif(p->>'guia_tallas', ''), coalesce((p->>'visible')::boolean, true), coalesce((p->>'destacado')::boolean, false),
          coalesce((p->>'en_oferta')::boolean, false),
          coalesce((p->>'orden')::int, (select coalesce(max(orden), 0) + 1 from products)))
  on conflict (id) do update set
    ref = excluded.ref, nombre = excluded.nombre, slug = excluded.slug, categoria = excluded.categoria, linea = excluded.linea,
    genero = excluded.genero, precio = excluded.precio, precio_anterior = excluded.precio_anterior, descripcion = excluded.descripcion,
    imagenes = excluded.imagenes, colores = excluded.colores, guia_tallas = excluded.guia_tallas, visible = excluded.visible,
    destacado = excluded.destacado, en_oferta = excluded.en_oferta,
    orden = case when p ? 'orden' then excluded.orden else products.orden end;

  if p ? 'costo' then
    insert into product_costs (product_id, costo, updated_at) values (v_id, (p->>'costo')::numeric, now())
    on conflict (product_id) do update set costo = excluded.costo, updated_at = now();
  end if;

  -- Cada variante se identifica por id o, si no trae id (importación), por talla + color.
  -- Así una reimportación actualiza la variante existente sin romper su historial ni sus pedidos.
  select coalesce(array_agg(x.vid), '{}') into v_keep from (
    select coalesce(nullif(e2->>'id', '')::bigint,
             (select pv.id from product_variants pv where pv.product_id = v_id
                 and pv.talla = btrim(e2->>'talla') and pv.color = coalesce(e2->>'color', ''))) as vid
      from jsonb_array_elements(p->'variantes') e2) x
   where x.vid is not null;
  delete from product_variants where product_id = v_id and not (id = any (v_keep));

  for e in select * from jsonb_array_elements(p->'variantes') loop
    v_desired := (e->>'stock')::int;
    if v_desired is not null and v_desired < 0 then raise exception 'STOCK_NEGATIVO'; end if;
    v_vid := coalesce(nullif(e->>'id', '')::bigint,
               (select pv.id from product_variants pv where pv.product_id = v_id
                   and pv.talla = btrim(e->>'talla') and pv.color = coalesce(e->>'color', '')));
    if v_vid is not null then
      select stock into cur from product_variants where id = v_vid and product_id = v_id for update;
      if not found then continue; end if;
      v_orig := (e->>'stock_original')::int;
      v_new := case when v_desired is null then null
                    when cur is not null and v_orig is not null then greatest(0, cur + (v_desired - v_orig))
                    else v_desired end;
      perform _mov('ajuste', null, 'Edición del producto');
      update product_variants
         set talla = btrim(e->>'talla'), color = coalesce(e->>'color', ''), precio = (e->>'precio')::numeric, stock = v_new
       where id = v_vid;
    else
      perform _mov('entrada', null, 'Nueva variante');
      insert into product_variants (product_id, talla, color, stock, precio)
      values (v_id, btrim(e->>'talla'), coalesce(e->>'color', ''), v_desired, (e->>'precio')::numeric)
      on conflict (product_id, talla, color) do update set stock = excluded.stock, precio = excluded.precio;
    end if;
  end loop;
  return v_id;
end $$;

create or replace function public.admin_delete_product(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  delete from products where id = p_id;   -- los pedidos conservan su copia (snapshot)
end $$;

-- Importación masiva (admin): [{producto con variantes}, …]
create or replace function public.admin_import_products(p_items jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare e jsonb; n int := 0;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  for e in select * from jsonb_array_elements(p_items) loop
    perform admin_save_product(e);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ELIMINAR CLIENTE (admin). Sus pedidos se conservan con la copia de datos (user_id pasa a null).
create or replace function public.admin_delete_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  if p_user_id = auth.uid() then raise exception 'NO_PUEDES_ELIMINARTE'; end if;
  if exists (select 1 from public.profiles where id = p_user_id and role = 'admin') then raise exception 'NO_SE_ELIMINAN_ADMINS'; end if;
  delete from auth.users where id = p_user_id;
end $$;

-- Pedidos del cliente autenticado (sin costos internos)
create or replace function public.my_orders()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', o.id, 'numero', o.numero, 'created_at', o.created_at, 'estado', o.estado, 'metodo_pago', o.metodo_pago,
      'cliente', o.cliente, 'subtotal', o.subtotal, 'descuento', o.descuento, 'envio', o.envio, 'total', o.total,
      'items_sin_precio', o.items_sin_precio,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('ref', i.ref, 'nombre', i.nombre, 'talla', i.talla, 'color', i.color,
                  'cantidad', i.cantidad, 'precio_unitario', i.precio_unitario, 'subtotal', i.subtotal, 'imagen', i.imagen, 'product_id', i.product_id) order by i.id), '[]'::jsonb)
                from order_items i where i.order_id = o.id),
      'historial', (select coalesce(jsonb_agg(jsonb_build_object('estado', h.estado, 'fecha', h.created_at) order by h.created_at), '[]'::jsonb)
                from order_status_history h where h.order_id = o.id)) as x
    from orders o where o.user_id = auth.uid() and auth.uid() is not null
  ) t;
$$;

-- Asociar pedidos hechos como invitado al crear/confirmar la cuenta.
-- Solo si el correo de la cuenta está CONFIRMADO y coincide con el del pedido.
create or replace function public.link_guest_orders()
returns int language plpgsql security definer set search_path = public, auth as $$
declare v_email text; n int := 0;
begin
  select email into v_email from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if v_email is null then return 0; end if;
  update public.orders set user_id = auth.uid()
   where user_id is null and lower(cliente->>'email') = lower(v_email) and coalesce(cliente->>'email', '') <> '';
  get diagnostics n = row_count;
  return n;
end $$;

-- Base para beneficios de clientes frecuentes (lectura según RLS de orders)
create or replace view public.customer_stats with (security_invoker = true) as
  select user_id,
         count(*) filter (where estado <> 'cancelado')                   as pedidos,
         coalesce(sum(total) filter (where estado <> 'cancelado'), 0)    as total_comprado,
         max(created_at)                                                 as ultimo_pedido
    from public.orders where user_id is not null group by user_id;

-- =============================================================================
-- 4. SEGURIDAD — ROW LEVEL SECURITY
-- =============================================================================
alter table public.store_settings        enable row level security;
alter table public.categories            enable row level security;
alter table public.profiles              enable row level security;
alter table public.products              enable row level security;
alter table public.product_costs         enable row level security;
alter table public.product_variants      enable row level security;
alter table public.orders                enable row level security;
alter table public.order_items           enable row level security;
alter table public.order_status_history  enable row level security;
alter table public.inventory_movements   enable row level security;
alter table public.favorites             enable row level security;
alter table public.coupons               enable row level security;
alter table public.expenses              enable row level security;

-- Configuración: lectura pública, escritura admin
drop policy if exists "settings_read" on public.store_settings;
create policy "settings_read" on public.store_settings for select using (true);
drop policy if exists "settings_admin" on public.store_settings;
create policy "settings_admin" on public.store_settings for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "categories_read" on public.categories;
create policy "categories_read" on public.categories for select using (true);
drop policy if exists "categories_admin" on public.categories;
create policy "categories_admin" on public.categories for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Perfiles: cada cliente ve y edita el suyo; admin ve todos
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles for select to authenticated using (id = (select auth.uid()) or (select public.is_admin()));
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
revoke update on public.profiles from anon, authenticated;
grant update (nombre, telefono, ciudad, direccion, barrio, info_adicional) on public.profiles to authenticated;

-- Productos: públicos si están visibles; admin ve y gestiona todo (vía RPC)
drop policy if exists "products_read" on public.products;
create policy "products_read" on public.products for select using (visible or (select public.is_admin()));
drop policy if exists "products_admin" on public.products;
create policy "products_admin" on public.products for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "variants_read" on public.product_variants;
create policy "variants_read" on public.product_variants for select using (true);
drop policy if exists "variants_admin" on public.product_variants;
create policy "variants_admin" on public.product_variants for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Costos: SOLO admin
drop policy if exists "costs_admin" on public.product_costs;
create policy "costs_admin" on public.product_costs for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Pedidos: el cliente ve los suyos; admin ve todos. Se crean/modifican solo por RPC.
drop policy if exists "orders_select" on public.orders;
create policy "orders_select" on public.orders for select to authenticated using (user_id = (select auth.uid()) or (select public.is_admin()));
drop policy if exists "order_items_admin" on public.order_items;
create policy "order_items_admin" on public.order_items for select to authenticated using ((select public.is_admin()));
drop policy if exists "order_history_select" on public.order_status_history;
create policy "order_history_select" on public.order_status_history for select to authenticated using (
  (select public.is_admin()) or exists (select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid())));

drop policy if exists "inventory_admin" on public.inventory_movements;
create policy "inventory_admin" on public.inventory_movements for select to authenticated using ((select public.is_admin()));

-- Favoritos: cada usuario los suyos
drop policy if exists "favorites_own" on public.favorites;
create policy "favorites_own" on public.favorites for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists "coupons_admin" on public.coupons;
create policy "coupons_admin" on public.coupons for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
drop policy if exists "expenses_admin" on public.expenses;
create policy "expenses_admin" on public.expenses for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Permisos de ejecución de RPC
grant execute on function public.create_order(jsonb, jsonb, text) to anon, authenticated;
grant execute on function public.my_orders() to authenticated;
grant execute on function public.link_guest_orders() to authenticated;
revoke execute on function public.my_orders() from anon;
revoke execute on function public.link_guest_orders() from anon;
revoke execute on function public.admin_set_order_status(uuid, text) from anon;
revoke execute on function public.admin_delete_order(uuid, boolean) from anon;
revoke execute on function public.admin_update_order_note(uuid, text) from anon;
revoke execute on function public.admin_set_stock(bigint, int, text, text) from anon;
revoke execute on function public.admin_init_unset_stock(int, text) from anon;
revoke execute on function public.admin_save_product(jsonb) from anon;
revoke execute on function public.admin_delete_product(text) from anon;
revoke execute on function public.admin_import_products(jsonb) from anon;
revoke execute on function public.admin_delete_user(uuid) from anon;

-- =============================================================================
-- 5. STORAGE (fotos subidas desde el panel), REALTIME y DATOS INICIALES
-- =============================================================================
insert into storage.buckets (id, name, public) values ('productos', 'productos', true)
on conflict (id) do nothing;

drop policy if exists "productos_public_read" on storage.objects;
create policy "productos_public_read" on storage.objects for select using (bucket_id = 'productos');
drop policy if exists "productos_admin_insert" on storage.objects;
create policy "productos_admin_insert" on storage.objects for insert to authenticated with check (bucket_id = 'productos' and (select public.is_admin()));
drop policy if exists "productos_admin_update" on storage.objects;
create policy "productos_admin_update" on storage.objects for update to authenticated using (bucket_id = 'productos' and (select public.is_admin()));
drop policy if exists "productos_admin_delete" on storage.objects;
create policy "productos_admin_delete" on storage.objects for delete to authenticated using (bucket_id = 'productos' and (select public.is_admin()));

-- Realtime: pedidos, stock y productos se reflejan en otros dispositivos
do $$
declare t text;
begin
  foreach t in array array['orders','order_items','product_variants','products','store_settings'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- Configuración inicial (solo si no existe)
insert into public.store_settings (key, value) values
  ('tienda',     '{"nombre":"WESNOCK","eslogan":"Believe in your dreams.","direccion":"Calle 5D # 21a - 03, Valledupar, Cesar","instagram":"https://www.instagram.com/wesnock_/","moneda":"COP","locale":"es-CO","logo":""}'),
  ('whatsapp',   '{"numero":"573128043151","mensajeGeneral":"Hola WESNOCK, quiero información."}'),
  ('catalogo',   '{"permitirSinPrecio":true,"porPagina":24}'),
  ('pagos',      '{"contraentrega":{"activo":true,"nombre":"Pago contra entrega","descripcion":"Pagas al recibir tu pedido."},"transferencia":{"activo":true,"nombre":"Transferencia bancaria","descripcion":"Te enviaremos los datos para transferir al confirmar."}}'),
  ('pedidos',    '{"prefijo":"WES-","digitos":4,"costoEnvio":null,"textoEnvio":"El costo y tiempo de envío se coordinan contigo por WhatsApp al confirmar el pedido.","politicaCambios":""}'),
  ('inventario', '{"umbralStockBajo":3}')
on conflict (key) do nothing;

insert into public.categories (slug, nombre, grupo, orden) values
  ('camisetas','Camisetas','ropa',1), ('polos','Polos','ropa',2), ('jeans','Jeans','ropa',3),
  ('bermudas-de-jean','Bermudas de jean','ropa',4), ('pantalonetas','Pantalonetas','ropa',5),
  ('camisillas','Camisillas tipo original','ropa',6), ('camisetas-colombia','Camisetas Colombia','ropa',7),
  ('camisetas-dama','Camisetas dama','ropa',8), ('ninos','Niños','ropa',9),
  ('zapatos','Zapatos','calzado',10), ('sandalias','Sandalias','calzado',11),
  ('gorras','Gorras','accesorios',12), ('gafas','Gafas','accesorios',13), ('billeteras','Billeteras','accesorios',14),
  ('canguros-y-carrieles','Canguros y carrieles','accesorios',15), ('correas','Correas','accesorios',16),
  ('manillas','Manillas','accesorios',17), ('relojes','Relojes','accesorios',18), ('perfumeria','Perfumería','accesorios',19),
  ('bolsos-dama','Bolsos dama','accesorios',20)
on conflict (slug) do nothing;

-- =============================================================================
-- FIN. Siguiente paso: crear tu usuario admin (ver instrucciones) y ejecutar:
--   update public.profiles set role = 'admin' where email = 'TU_CORREO';
-- =============================================================================
