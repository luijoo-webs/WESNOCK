-- =============================================================================
-- WESNOCK — Migración 02: Ventas físicas, facturación (pre-factura), clientes de
-- mostrador, direcciones, entradas de inventario por lote y notificaciones admin.
-- -----------------------------------------------------------------------------
-- Requisito: haber ejecutado antes supabase/schema.sql.
-- Cómo usarlo: Supabase → SQL Editor → New query → pegar TODO → Run.
-- Es re-ejecutable y NO borra datos existentes (productos, stock, pedidos, usuarios).
--
-- IMPORTANTE (DIAN): las ventas físicas generan un "Documento interno / pre-factura".
-- Los campos fe_* (CUFE, QR, número autorizado…) quedan vacíos hasta que un proveedor
-- de facturación electrónica autorizado los devuelva. Nada aquí simula una validación DIAN.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. INVENTARIO: nuevos tipos de movimiento y vínculo con ventas físicas
-- -----------------------------------------------------------------------------
alter table public.inventory_movements drop constraint if exists inventory_movements_tipo_check;
alter table public.inventory_movements add constraint inventory_movements_tipo_check check (tipo in
  ('entrada','venta','venta_fisica','devolucion','ajuste','salida','cancelacion','reactivacion',
   'eliminacion_pedido','anulacion_venta','otro'));
alter table public.inventory_movements add column if not exists sale_id uuid;

-- El motivo del movimiento viaja en variables de transacción (set_config).
create or replace function public._mov(p_tipo text, p_order uuid, p_nota text)
returns void language sql as $$
  select set_config('wsk.mov_tipo', coalesce(p_tipo, ''), true),
         set_config('wsk.mov_order', coalesce(p_order::text, ''), true),
         set_config('wsk.mov_sale', '', true),
         set_config('wsk.mov_nota', coalesce(p_nota, ''), true);
$$;
create or replace function public._mov_sale(p_tipo text, p_sale uuid, p_nota text)
returns void language sql as $$
  select set_config('wsk.mov_tipo', coalesce(p_tipo, ''), true),
         set_config('wsk.mov_order', '', true),
         set_config('wsk.mov_sale', coalesce(p_sale::text, ''), true),
         set_config('wsk.mov_nota', coalesce(p_nota, ''), true);
$$;
revoke all on function public._mov(text, uuid, text) from public, anon, authenticated;
revoke all on function public._mov_sale(text, uuid, text) from public, anon, authenticated;

create or replace function public.log_stock_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old int := case when tg_op = 'UPDATE' then old.stock else null end;
  v_tipo text := nullif(current_setting('wsk.mov_tipo', true), '');
begin
  if new.stock is not distinct from v_old then return new; end if;
  if new.stock is null then return new; end if;
  insert into public.inventory_movements (variant_id, product_id, talla, color, tipo, cantidad, stock_anterior, stock_nuevo, order_id, sale_id, nota, created_by)
  values (new.id, new.product_id, new.talla, nullif(new.color, ''),
          coalesce(v_tipo, case when tg_op = 'INSERT' or v_old is null then 'entrada' else 'ajuste' end),
          new.stock - coalesce(v_old, 0), v_old, new.stock,
          nullif(current_setting('wsk.mov_order', true), '')::uuid,
          nullif(current_setting('wsk.mov_sale', true), '')::uuid,
          nullif(current_setting('wsk.mov_nota', true), ''),
          auth.uid());
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- 2. PERFIL: preferencias del cliente
-- -----------------------------------------------------------------------------
alter table public.profiles add column if not exists preferencias jsonb not null default '{}'::jsonb;
revoke update on public.profiles from anon, authenticated;
grant update (nombre, telefono, ciudad, direccion, barrio, info_adicional, preferencias) on public.profiles to authenticated;

-- -----------------------------------------------------------------------------
-- 3. DIRECCIONES de clientes registrados
-- -----------------------------------------------------------------------------
create table if not exists public.addresses (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  etiqueta        text not null default '',
  destinatario    text not null,
  telefono        text not null default '',
  ciudad          text not null,
  direccion       text not null,
  barrio          text not null default '',
  info_adicional  text not null default '',
  predeterminada  boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists addresses_user_idx on public.addresses(user_id);
drop trigger if exists addresses_touch on public.addresses;
create trigger addresses_touch before update on public.addresses for each row execute function public.touch_updated_at();

-- Solo una dirección predeterminada por usuario
create or replace function public.addresses_single_default()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.predeterminada then
    update public.addresses set predeterminada = false where user_id = new.user_id and id <> new.id and predeterminada;
  end if;
  return new;
end $$;
drop trigger if exists addresses_default on public.addresses;
create trigger addresses_default after insert or update of predeterminada on public.addresses
  for each row when (new.predeterminada) execute function public.addresses_single_default();

-- Migrar la dirección que ya estaba en el perfil (una sola vez)
insert into public.addresses (user_id, etiqueta, destinatario, telefono, ciudad, direccion, barrio, info_adicional, predeterminada)
select p.id, 'Principal', coalesce(nullif(p.nombre, ''), 'Destinatario'), p.telefono, p.ciudad, p.direccion, p.barrio, p.info_adicional, true
  from public.profiles p
 where p.direccion <> '' and p.ciudad <> ''
   and not exists (select 1 from public.addresses a where a.user_id = p.id);

-- -----------------------------------------------------------------------------
-- 4. CLIENTES DE MOSTRADOR (ventas físicas; pueden no tener cuenta)
-- -----------------------------------------------------------------------------
create table if not exists public.store_customers (
  id                uuid primary key default gen_random_uuid(),
  tipo_documento    text not null default 'CC' check (tipo_documento in ('CC','CE','NIT','TI','PP','PPT','RC','OTRO','NINGUNO')),
  numero_documento  text not null default '',
  nombre            text not null,
  telefono          text not null default '',
  email             text not null default '',
  direccion         text not null default '',
  ciudad            text not null default '',
  user_id           uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index if not exists store_customers_doc_uq on public.store_customers(tipo_documento, numero_documento) where numero_documento <> '';
drop trigger if exists store_customers_touch on public.store_customers;
create trigger store_customers_touch before update on public.store_customers for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 5. VENTAS FÍSICAS (mismo inventario que la tienda online)
-- -----------------------------------------------------------------------------
create sequence if not exists public.sale_number_seq;

create table if not exists public.sales (
  id                    uuid primary key default gen_random_uuid(),
  numero                text not null unique,
  customer_id           uuid references public.store_customers(id) on delete set null,
  user_id               uuid references auth.users(id) on delete set null,
  cliente               jsonb not null,                         -- copia de los datos del cliente
  metodo_pago           text not null check (metodo_pago in ('efectivo','transferencia','tarjeta_debito','tarjeta_credito','nequi','otro')),
  forma_pago            text not null default 'contado' check (forma_pago in ('contado','credito')),
  subtotal              numeric(12,0) not null default 0,       -- antes de descuentos
  descuento             numeric(12,0) not null default 0,
  impuestos             numeric(12,0) not null default 0,
  total                 numeric(12,0) not null default 0,
  iva_tarifa            numeric(5,2),                           -- copia de la configuración al vender
  precios_incluyen_iva  boolean,
  estado                text not null default 'completada' check (estado in ('completada','anulada')),
  notas                 text not null default '',
  created_by            uuid references auth.users(id) on delete set null,
  created_by_email      text,
  email_destino         text,
  email_enviado_at      timestamptz,
  -- Documento: hoy SIEMPRE pre-factura interna. Los campos fe_* solo los llena una integración real.
  documento_tipo        text not null default 'pre_factura' check (documento_tipo in ('pre_factura','factura_electronica')),
  fe_estado             text not null default 'no_integrada' check (fe_estado in ('no_integrada','pendiente','enviada','aceptada','rechazada','error')),
  fe_proveedor          text,
  fe_prefijo            text,
  fe_numero             text,
  fe_cufe               text,
  fe_qr                 text,
  fe_fecha_validacion   timestamptz,
  fe_respuesta          jsonb,
  anulada_at            timestamptz,
  anulada_por           text,
  motivo_anulacion      text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index if not exists sales_created_idx on public.sales(created_at desc);
create index if not exists sales_customer_idx on public.sales(customer_id);
drop trigger if exists sales_touch on public.sales;
create trigger sales_touch before update on public.sales for each row execute function public.touch_updated_at();

create table if not exists public.sale_items (
  id                bigint generated always as identity primary key,
  sale_id           uuid not null references public.sales(id) on delete cascade,
  product_id        text references public.products(id) on delete set null,
  variant_id        bigint references public.product_variants(id) on delete set null,
  ref               text,
  nombre            text not null,
  talla             text not null,
  color             text,
  cantidad          int not null check (cantidad > 0),
  precio_unitario   numeric(12,0) not null check (precio_unitario >= 0),
  descuento         numeric(12,0) not null default 0 check (descuento >= 0),   -- descuento total de la línea
  costo_unitario    numeric(12,0),                                            -- costo al momento de la venta
  subtotal          numeric(12,0) generated always as (precio_unitario * cantidad - descuento) stored,
  costo_total       numeric(12,0) generated always as (costo_unitario * cantidad) stored,
  ganancia_bruta    numeric(12,0) generated always as (precio_unitario * cantidad - descuento - costo_unitario * cantidad) stored,
  imagen            text,
  stock_descontado  int not null default 0
);
create index if not exists sale_items_sale_idx on public.sale_items(sale_id);
create index if not exists sale_items_product_idx on public.sale_items(product_id);

-- -----------------------------------------------------------------------------
-- 6. NOTIFICACIONES DEL ADMINISTRADOR
-- -----------------------------------------------------------------------------
create table if not exists public.admin_notifications (
  id           bigint generated always as identity primary key,
  categoria    text not null check (categoria in ('pedidos','inventario','ventas','clientes','sistema')),
  tipo         text not null,
  titulo       text not null,
  mensaje      text not null default '',
  entidad      text,              -- pedido | venta | producto | cliente
  entidad_id   text,              -- número de pedido/venta, id de producto o cliente
  datos        jsonb not null default '{}'::jsonb,
  leida        boolean not null default false,
  archivada    boolean not null default false,
  destinatario uuid references auth.users(id) on delete cascade,   -- null = todos los administradores
  created_at   timestamptz not null default now(),
  leida_at     timestamptz
);
create index if not exists admin_notifications_created_idx on public.admin_notifications(created_at desc);

create or replace function public.notify_admin(p_categoria text, p_tipo text, p_titulo text, p_mensaje text,
                                               p_entidad text, p_entidad_id text, p_datos jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.admin_notifications (categoria, tipo, titulo, mensaje, entidad, entidad_id, datos)
  values (p_categoria, p_tipo, p_titulo, coalesce(p_mensaje, ''), p_entidad, p_entidad_id, coalesce(p_datos, '{}'::jsonb));
$$;
revoke all on function public.notify_admin(text, text, text, text, text, text, jsonb) from public, anon, authenticated;

-- Pedidos: nuevo / actualizado / pago registrado (se dispara al registrar el estado)
create or replace function public.trg_notify_order_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select numero, cliente, total, metodo_pago, items_sin_precio into o from public.orders where id = new.order_id;
  if not found then return new; end if;
  if new.estado = 'nuevo' then
    perform notify_admin('pedidos', 'nuevo_pedido', 'Nuevo pedido ' || o.numero,
      coalesce(o.cliente->>'nombre', '') || ' · ' || coalesce(o.cliente->>'ciudad', ''),
      'pedido', o.numero,
      jsonb_build_object('cliente', o.cliente->>'nombre', 'total', o.total, 'estado', new.estado, 'metodo_pago', o.metodo_pago, 'items_sin_precio', o.items_sin_precio));
  else
    perform notify_admin('pedidos', case when new.estado = 'pagado' then 'pago_registrado' else 'pedido_actualizado' end,
      case when new.estado = 'pagado' then 'Pago registrado · ' || o.numero else 'Pedido actualizado · ' || o.numero end,
      'Nuevo estado: ' || new.estado,
      'pedido', o.numero,
      jsonb_build_object('cliente', o.cliente->>'nombre', 'total', o.total, 'estado', new.estado));
  end if;
  return new;
end $$;
drop trigger if exists order_status_notify on public.order_status_history;
create trigger order_status_notify after insert on public.order_status_history for each row execute function public.trg_notify_order_status();

-- Inventario: avisa solo al CRUZAR el umbral (sin repetir en cada cambio)
create or replace function public.trg_notify_stock()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_umbral int := coalesce((select (value->>'umbralStockBajo')::int from public.store_settings where key = 'inventario'), 3);
  v_nombre text; v_desc text;
begin
  if new.stock is null or new.stock is not distinct from old.stock then return new; end if;
  select nombre into v_nombre from public.products where id = new.product_id;
  v_desc := coalesce(v_nombre, new.product_id) || ' — talla ' || new.talla || case when new.color <> '' then ' — color ' || new.color else '' end;
  if new.stock = 0 and coalesce(old.stock, 1) > 0 then
    perform notify_admin('inventario', 'agotado', 'Producto agotado', v_desc, 'producto', new.product_id,
      jsonb_build_object('variant_id', new.id, 'talla', new.talla, 'color', nullif(new.color, ''), 'stock', 0));
  elsif new.stock > 0 and new.stock <= v_umbral and new.stock < coalesce(old.stock, v_umbral + 1) and (old.stock is null or old.stock > v_umbral) then
    perform notify_admin('inventario', 'stock_bajo', 'Stock bajo', v_desc || ' — ' || new.stock || ' unidad' || case when new.stock = 1 then '' else 'es' end,
      'producto', new.product_id, jsonb_build_object('variant_id', new.id, 'talla', new.talla, 'color', nullif(new.color, ''), 'stock', new.stock));
  end if;
  return new;
end $$;
drop trigger if exists variants_notify_stock on public.product_variants;
create trigger variants_notify_stock after update of stock on public.product_variants for each row execute function public.trg_notify_stock();

-- Clientes nuevos
create or replace function public.trg_notify_new_client()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role = 'client' then
    perform notify_admin('clientes', 'cliente_nuevo', 'Cliente nuevo', coalesce(nullif(new.nombre, ''), new.email, ''), 'cliente', new.id::text,
      jsonb_build_object('email', new.email));
  end if;
  return new;
end $$;
drop trigger if exists profiles_notify_new on public.profiles;
create trigger profiles_notify_new after insert on public.profiles for each row execute function public.trg_notify_new_client();

-- -----------------------------------------------------------------------------
-- 7. RPC: ENTRADAS / SALIDAS / AJUSTES DE INVENTARIO POR LOTE (admin)
-- p_tipo: entrada | devolucion | salida | ajuste (cantidad con signo) | conteo (fija el valor)
-- p_items: [{"variant_id":123,"cantidad":10}] o [{"talla":"XXL","color":"Negro","cantidad":5}] (crea la talla)
-- -----------------------------------------------------------------------------
create or replace function public.admin_stock_entry(p_product_id text, p_items jsonb, p_tipo text, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e jsonb; v record; v_vid bigint; v_qty int; v_new int; v_total int := 0; v_n int := 0;
  v_detalle text := ''; v_nombre text; v_mov text;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  if p_tipo not in ('entrada','devolucion','salida','ajuste','conteo') then raise exception 'TIPO_INVALIDO'; end if;
  select nombre into v_nombre from products where id = p_product_id;
  if v_nombre is null then raise exception 'PRODUCTO_NO_EXISTE'; end if;
  v_mov := case p_tipo when 'conteo' then 'ajuste' else p_tipo end;

  for e in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_qty := (e->>'cantidad')::int;
    if v_qty is null or (v_qty = 0 and p_tipo <> 'conteo') then continue; end if;
    if p_tipo in ('entrada','devolucion','salida') and v_qty < 0 then raise exception 'CANTIDAD_INVALIDA'; end if;
    if p_tipo = 'conteo' and v_qty < 0 then raise exception 'STOCK_NEGATIVO'; end if;

    v_vid := nullif(e->>'variant_id', '')::bigint;
    if v_vid is null then
      if coalesce(btrim(e->>'talla'), '') = '' then raise exception 'TALLA_REQUERIDA'; end if;
      select id into v_vid from product_variants where product_id = p_product_id and talla = btrim(e->>'talla') and color = coalesce(e->>'color', '');
      if v_vid is null then
        if p_tipo not in ('entrada','conteo') then raise exception 'VARIANTE_NO_EXISTE'; end if;
        perform _mov(v_mov, null, coalesce(p_nota, 'Nueva talla'));
        insert into product_variants (product_id, talla, color, stock) values (p_product_id, btrim(e->>'talla'), coalesce(e->>'color', ''), 0)
        returning id into v_vid;
      end if;
    end if;

    select id, talla, color, stock into v from product_variants where id = v_vid and product_id = p_product_id for update;
    if not found then raise exception 'VARIANTE_NO_EXISTE'; end if;
    v_new := case p_tipo
               when 'conteo' then v_qty
               when 'salida' then coalesce(v.stock, 0) - v_qty
               when 'ajuste' then coalesce(v.stock, 0) + v_qty
               else coalesce(v.stock, 0) + v_qty end;
    if v_new < 0 then raise exception 'STOCK_NEGATIVO:% talla %|%', v_nombre, v.talla, coalesce(v.stock, 0); end if;
    perform _mov(v_mov, null, p_nota);
    update product_variants set stock = v_new where id = v.id;
    v_total := v_total + (v_new - coalesce(v.stock, 0)); v_n := v_n + 1;
    v_detalle := v_detalle || case when v_detalle = '' then '' else ', ' end || v.talla || case when v.color <> '' then ' ' || v.color else '' end ||
                 ' ' || case when p_tipo = 'conteo' then '= ' || v_new else (case when v_new - coalesce(v.stock, 0) >= 0 then '+' else '' end) || (v_new - coalesce(v.stock, 0)) end;
  end loop;

  if v_n = 0 then raise exception 'SIN_CANTIDADES'; end if;
  perform notify_admin('inventario', 'entrada_inventario',
    case p_tipo when 'entrada' then 'Entrada de inventario registrada' when 'devolucion' then 'Devolución registrada'
                when 'salida' then 'Salida de inventario registrada' else 'Ajuste de inventario registrado' end,
    v_nombre || ' — ' || v_detalle, 'producto', p_product_id, jsonb_build_object('tipo', p_tipo, 'variantes', v_n, 'unidades', v_total));
  return jsonb_build_object('variantes', v_n, 'unidades', v_total);
end $$;

-- -----------------------------------------------------------------------------
-- 8. RPC: CREAR VENTA FÍSICA (admin) — atómica, mismo inventario que la tienda
-- p_items: [{"variant_id":1,"cantidad":2,"precio_unitario":80000,"descuento":0}]
-- p_cliente: {id?, user_id?, tipo_documento, numero_documento, nombre, telefono, email, direccion, ciudad}
-- p_descuento: descuento global (se reparte proporcionalmente entre las líneas)
-- -----------------------------------------------------------------------------
create or replace function public.admin_create_sale(p_items jsonb, p_cliente jsonb, p_metodo_pago text,
                                                    p_forma_pago text default 'contado', p_descuento numeric default 0, p_notas text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_fac     jsonb := coalesce((select value from store_settings where key = 'facturacion'), '{}'::jsonb);
  v_sale    uuid := gen_random_uuid();
  v_seq     text; v_numero text;
  v_cust    uuid := nullif(p_cliente->>'id', '')::uuid;
  v_cli     jsonb; v_tipo_doc text; v_num_doc text; v_nombre text;
  r record; v record; v_price numeric; v_img text;
  v_bruto   numeric := 0; v_desc_lineas numeric := 0; v_global numeric := greatest(0, round(coalesce(p_descuento, 0)));
  v_neto numeric; v_iva numeric := nullif(v_fac->>'ivaTarifa', '')::numeric; v_incl boolean := coalesce((v_fac->>'preciosIncluyenIva')::boolean, true);
  v_imp numeric := 0; v_total numeric; v_email text; v_admin_email text; v_rest numeric; v_line record; v_i int := 0; v_n int; v_part numeric;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  if p_metodo_pago not in ('efectivo','transferencia','tarjeta_debito','tarjeta_credito','nequi','otro') then raise exception 'METODO_PAGO_INVALIDO'; end if;
  if coalesce(p_forma_pago, 'contado') not in ('contado','credito') then raise exception 'FORMA_PAGO_INVALIDA'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'CARRITO_VACIO'; end if;

  -- Cliente (se guarda/actualiza en store_customers y se copia en la venta)
  v_tipo_doc := coalesce(nullif(p_cliente->>'tipo_documento', ''), 'CC');
  if v_tipo_doc not in ('CC','CE','NIT','TI','PP','PPT','RC','OTRO','NINGUNO') then v_tipo_doc := 'OTRO'; end if;
  v_num_doc := left(btrim(coalesce(p_cliente->>'numero_documento', '')), 30);
  v_nombre := left(coalesce(nullif(btrim(p_cliente->>'nombre'), ''), 'Consumidor final'), 160);
  v_email := left(lower(btrim(coalesce(p_cliente->>'email', ''))), 160);
  if v_cust is not null then
    update store_customers set tipo_documento = case when v_num_doc = '' then 'NINGUNO' else v_tipo_doc end, numero_documento = v_num_doc, nombre = v_nombre,
           telefono = coalesce(p_cliente->>'telefono', ''), email = v_email, direccion = coalesce(p_cliente->>'direccion', ''),
           ciudad = coalesce(p_cliente->>'ciudad', ''), user_id = coalesce(nullif(p_cliente->>'user_id', '')::uuid, user_id)
     where id = v_cust;
    if not found then v_cust := null; end if;
  end if;
  if v_cust is null and v_num_doc <> '' then
    insert into store_customers (tipo_documento, numero_documento, nombre, telefono, email, direccion, ciudad, user_id)
    values (v_tipo_doc, v_num_doc, v_nombre, coalesce(p_cliente->>'telefono', ''), v_email, coalesce(p_cliente->>'direccion', ''),
            coalesce(p_cliente->>'ciudad', ''), nullif(p_cliente->>'user_id', '')::uuid)
    on conflict (tipo_documento, numero_documento) where numero_documento <> '' do update set
      nombre = excluded.nombre, telefono = excluded.telefono, email = excluded.email, direccion = excluded.direccion,
      ciudad = excluded.ciudad, user_id = coalesce(excluded.user_id, store_customers.user_id)
    returning id into v_cust;
  elsif v_cust is null and v_nombre <> 'Consumidor final' then
    insert into store_customers (tipo_documento, numero_documento, nombre, telefono, email, direccion, ciudad, user_id)
    values ('NINGUNO', '', v_nombre, coalesce(p_cliente->>'telefono', ''), v_email, coalesce(p_cliente->>'direccion', ''),
            coalesce(p_cliente->>'ciudad', ''), nullif(p_cliente->>'user_id', '')::uuid)
    returning id into v_cust;
  end if;
  v_cli := jsonb_build_object('nombre', v_nombre, 'tipo_documento', case when v_num_doc = '' then 'NINGUNO' else v_tipo_doc end,
    'numero_documento', v_num_doc, 'telefono', left(coalesce(p_cliente->>'telefono', ''), 30), 'email', v_email,
    'direccion', left(coalesce(p_cliente->>'direccion', ''), 200), 'ciudad', left(coalesce(p_cliente->>'ciudad', ''), 80));

  v_seq := nextval('public.sale_number_seq')::text;
  v_numero := coalesce(nullif(v_fac->>'prefijoInterno', ''), 'VF-') || case when length(v_seq) >= 4 then v_seq else lpad(v_seq, 4, '0') end;
  select email into v_admin_email from profiles where id = auth.uid();

  insert into sales (id, numero, customer_id, user_id, cliente, metodo_pago, forma_pago, notas, created_by, created_by_email, email_destino, iva_tarifa, precios_incluyen_iva)
  values (v_sale, v_numero, v_cust, nullif(p_cliente->>'user_id', '')::uuid, v_cli, p_metodo_pago, coalesce(p_forma_pago, 'contado'),
          left(coalesce(p_notas, ''), 1000), auth.uid(), v_admin_email, nullif(v_email, ''), v_iva, v_incl);

  -- Líneas: bloquea cada variante (FOR UPDATE) en orden de id → sin doble venta de la última unidad
  for r in
    select (e->>'variant_id')::bigint as vid, sum((e->>'cantidad')::int)::int as qty,
           max(nullif(e->>'precio_unitario', '')::numeric) as precio, sum(coalesce(nullif(e->>'descuento', '')::numeric, 0)) as descu
      from jsonb_array_elements(p_items) e group by 1 order by 1
  loop
    if r.qty is null or r.qty < 1 or r.qty > 999 then raise exception 'CANTIDAD_INVALIDA'; end if;
    select pv.id, pv.product_id, pv.talla, pv.color, pv.stock, pv.precio as v_precio,
           p.nombre, p.ref, p.precio as p_precio, p.imagenes, pc.costo
      into v
      from product_variants pv join products p on p.id = pv.product_id
      left join product_costs pc on pc.product_id = p.id
     where pv.id = r.vid for update of pv;
    if not found then raise exception 'VARIANTE_NO_EXISTE'; end if;
    if v.stock is not null and v.stock < r.qty then raise exception 'STOCK_INSUFICIENTE:% · talla %|%', v.nombre, v.talla, v.stock; end if;
    v_price := coalesce(r.precio, v.v_precio, v.p_precio);
    if v_price is null then raise exception 'PRECIO_REQUERIDO:%', v.nombre; end if;
    if v_price < 0 or r.descu < 0 or r.descu > v_price * r.qty then raise exception 'DESCUENTO_INVALIDO:%', v.nombre; end if;

    select coalesce((select x->>'src' from jsonb_array_elements(v.imagenes) x where coalesce(x->>'color', '') = v.color and v.color <> '' limit 1), v.imagenes->0->>'src') into v_img;
    if v.stock is not null then
      perform _mov_sale('venta_fisica', v_sale, v_numero);
      update product_variants set stock = stock - r.qty where id = v.id;
    end if;
    insert into sale_items (sale_id, product_id, variant_id, ref, nombre, talla, color, cantidad, precio_unitario, descuento, costo_unitario, imagen, stock_descontado)
    values (v_sale, v.product_id, v.id, v.ref, v.nombre, v.talla, nullif(v.color, ''), r.qty, round(v_price), round(r.descu), v.costo, v_img,
            case when v.stock is not null then r.qty else 0 end);
    v_bruto := v_bruto + round(v_price) * r.qty;
    v_desc_lineas := v_desc_lineas + round(r.descu);
  end loop;

  -- Descuento global repartido proporcionalmente (la última línea toma el residuo)
  if v_global > 0 then
    if v_global > v_bruto - v_desc_lineas then raise exception 'DESCUENTO_INVALIDO:venta'; end if;
    v_rest := v_global;
    select count(*) into v_n from sale_items where sale_id = v_sale;
    for v_line in select id, subtotal from sale_items where sale_id = v_sale order by id loop
      v_i := v_i + 1;
      v_part := case when v_i = v_n then v_rest else least(v_rest, round(v_global * v_line.subtotal / nullif(v_bruto - v_desc_lineas, 0))) end;
      update sale_items set descuento = descuento + v_part where id = v_line.id;
      v_rest := v_rest - v_part;
    end loop;
  end if;

  select sum(subtotal) into v_neto from sale_items where sale_id = v_sale;
  -- IVA: solo si el administrador configuró la tarifa en Facturación
  if v_iva is not null and v_iva > 0 then
    if v_incl then v_imp := round(v_neto - v_neto / (1 + v_iva / 100)); v_total := v_neto;
    else v_imp := round(v_neto * v_iva / 100); v_total := v_neto + v_imp; end if;
  else v_total := v_neto; end if;

  update sales set subtotal = v_bruto, descuento = v_bruto - v_neto, impuestos = v_imp, total = v_total where id = v_sale;
  perform notify_admin('ventas', 'venta_fisica', 'Nueva venta física ' || v_numero, v_nombre, 'venta', v_numero,
    jsonb_build_object('cliente', v_nombre, 'total', v_total, 'metodo_pago', p_metodo_pago));

  return (select to_jsonb(s) || jsonb_build_object('items',
            (select jsonb_agg(to_jsonb(i) order by i.id) from sale_items i where i.sale_id = s.id))
            from sales s where s.id = v_sale);
end $$;

-- ANULAR VENTA FÍSICA (admin): devuelve el stock descontado
create or replace function public.admin_void_sale(p_sale_id uuid, p_motivo text)
returns text language plpgsql security definer set search_path = public as $$
declare s record; it record; v_email text;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  select * into s from sales where id = p_sale_id for update;
  if not found then raise exception 'VENTA_NO_EXISTE'; end if;
  if s.estado = 'anulada' then return s.numero; end if;
  if coalesce(btrim(p_motivo), '') = '' then raise exception 'MOTIVO_REQUERIDO'; end if;
  for it in select i.id, i.variant_id, i.stock_descontado from sale_items i
             where i.sale_id = s.id and i.stock_descontado > 0 and i.variant_id is not null order by i.variant_id loop
    perform 1 from product_variants where id = it.variant_id for update;
    perform _mov_sale('anulacion_venta', s.id, s.numero);
    update product_variants set stock = stock + it.stock_descontado where id = it.variant_id and stock is not null;
    update sale_items set stock_descontado = 0 where id = it.id;
  end loop;
  select email into v_email from profiles where id = auth.uid();
  update sales set estado = 'anulada', anulada_at = now(), anulada_por = v_email, motivo_anulacion = left(p_motivo, 500) where id = s.id;
  perform notify_admin('ventas', 'venta_anulada', 'Venta anulada ' || s.numero, left(p_motivo, 200), 'venta', s.numero, '{}'::jsonb);
  return s.numero;
end $$;

-- Marcar notificaciones (admin). p_ids null = todas.
create or replace function public.admin_mark_notifications(p_ids bigint[], p_leida boolean default true, p_archivar boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception 'NO_AUTORIZADO'; end if;
  update admin_notifications set leida = case when p_archivar then true else p_leida end,
         leida_at = case when p_leida or p_archivar then coalesce(leida_at, now()) else null end,
         archivada = archivada or p_archivar
   where (p_ids is null or id = any (p_ids)) and (destinatario is null or destinatario = auth.uid());
  get diagnostics n = row_count; return n;
end $$;

revoke execute on function public.admin_stock_entry(text, jsonb, text, text) from anon;
revoke execute on function public.admin_create_sale(jsonb, jsonb, text, text, numeric, text) from anon;
revoke execute on function public.admin_void_sale(uuid, text) from anon;
revoke execute on function public.admin_mark_notifications(bigint[], boolean, boolean) from anon;

-- -----------------------------------------------------------------------------
-- 9. RLS
-- -----------------------------------------------------------------------------
alter table public.addresses            enable row level security;
alter table public.store_customers      enable row level security;
alter table public.sales                enable row level security;
alter table public.sale_items           enable row level security;
alter table public.admin_notifications  enable row level security;

drop policy if exists "addresses_own" on public.addresses;
create policy "addresses_own" on public.addresses for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "addresses_admin_read" on public.addresses;
create policy "addresses_admin_read" on public.addresses for select to authenticated using ((select public.is_admin()));

drop policy if exists "store_customers_admin" on public.store_customers;
create policy "store_customers_admin" on public.store_customers for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Ventas: SOLO admin (se crean/anulan por RPC)
drop policy if exists "sales_admin_read" on public.sales;
create policy "sales_admin_read" on public.sales for select to authenticated using ((select public.is_admin()));
drop policy if exists "sale_items_admin_read" on public.sale_items;
create policy "sale_items_admin_read" on public.sale_items for select to authenticated using ((select public.is_admin()));

drop policy if exists "notifications_admin_read" on public.admin_notifications;
create policy "notifications_admin_read" on public.admin_notifications for select to authenticated
  using ((select public.is_admin()) and (destinatario is null or destinatario = (select auth.uid())));
drop policy if exists "notifications_admin_delete" on public.admin_notifications;
create policy "notifications_admin_delete" on public.admin_notifications for delete to authenticated using ((select public.is_admin()));

-- -----------------------------------------------------------------------------
-- 10. REALTIME + CONFIGURACIÓN INICIAL
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['admin_notifications','sales','store_customers'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

-- Facturación: vacío hasta que el negocio lo configure (NO se inventan datos tributarios)
insert into public.store_settings (key, value) values ('facturacion', '{
  "razonSocial":"", "nombreComercial":"WESNOCK", "nit":"", "dv":"", "direccion":"", "ciudad":"", "telefono":"", "correo":"", "logo":"",
  "regimen":"", "responsabilidades":"", "prefijoInterno":"VF-",
  "prefijoDian":"", "numeracionDesde":null, "numeracionHasta":null, "resolucionNumero":"", "resolucionFecha":"", "resolucionVigenciaHasta":"",
  "proveedor":{"nombre":"", "ambiente":"pruebas", "estado":"no_configurado", "notas":""},
  "estadoIntegracion":"no_integrada",
  "ivaTarifa":null, "preciosIncluyenIva":true,
  "notaLegal":"", "textoPie":"Gracias por tu compra.", "enviarCorreoAlVender":true
}'::jsonb)
on conflict (key) do nothing;

-- =============================================================================
-- FIN migración 02.
-- Para enviar el comprobante por correo, despliega además la Edge Function
-- supabase/functions/enviar-documento-venta (ver INSTRUCCIONES.md).
-- =============================================================================
