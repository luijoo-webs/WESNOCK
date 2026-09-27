# WESNOCK — Puesta en marcha con Supabase

Proyecto: `https://owwimeyflveldcqeboiq.supabase.co` (ya conectado en `index.html` con la clave **publishable**, que es pública).
Nunca pongas la `service_role` key en el frontend.

## 1. Crear la base de datos (una sola vez)
1. Supabase → **SQL Editor** → **New query**.
2. Pega todo `supabase/schema.sql` → **Run**. Debe terminar sin errores (se puede volver a ejecutar).

Crea: `store_settings`, `categories`, `profiles`, `products`, `product_costs`, `product_variants`,
`orders`, `order_items`, `order_status_history`, `inventory_movements`, `favorites`, `coupons`, `expenses`,
la vista `customer_stats`, el bucket de Storage `productos`, las políticas RLS, las funciones RPC y Realtime.

## 2. Configurar Auth
Authentication → **URL Configuration**:
- **Site URL**: la URL de GitHub Pages, p. ej. `https://TU_USUARIO.github.io/TU_REPO/`
- **Redirect URLs**: agrega la misma URL (y `http://localhost:PUERTO/` si pruebas en local).

Authentication → Providers → Email: deja **Confirm email** activado.
El correo integrado de Supabase tiene un límite bajo de envíos por hora; para producción configura SMTP propio
(Authentication → Emails → SMTP Settings).

## 3. Crear el administrador
1. Authentication → **Users** → **Add user** → **Create new user**: tu correo + contraseña, marca **Auto Confirm User**.
2. SQL Editor:
   ```sql
   update public.profiles set role = 'admin' where email = 'TU_CORREO';
   ```

## 4. Cargar el catálogo
Abre la tienda en `#/admin` → inicia sesión → **Productos** → **Cargar catálogo original**
(importa los 278 productos del ZIP desde `catalogo/catalogo.json`).

Luego en **Inventario** registra el stock real (una por una o "Asignar a variantes sin registrar").
Mientras una variante no tenga stock registrado se vende sin control de inventario.

## 5. Publicar en GitHub Pages
Sube `index.html`, la carpeta `catalogo/` completa y (opcional) `supabase/`. Todas las rutas son relativas.

## 6. Pruebas recomendadas
- **Pedido desde el celular → panel del computador**: abre `#/admin` en el computador; compra desde el
  celular (como invitado); el pedido aparece en segundos (indicador "En vivo") o al recargar.
- **Ganancia histórica**: pon precio y costo a un producto, véndelo, cambia el costo y revisa el pedido en
  Admin → Pedidos: la ganancia de ese pedido no cambia (se guardó `costo_unitario` al vender).
- **Última unidad**: pon stock 1 en una variante e intenta comprarla desde dos dispositivos a la vez:
  solo uno lo logra (función `create_order` con bloqueo de fila).
