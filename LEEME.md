# Puesta en marcha (10 minutos)

1. Creá un proyecto en https://supabase.com
2. SQL Editor > New query > pegá `supabase.sql` > Run
   (si ya lo habías ejecutado antes, volvé a ejecutarlo completo: es seguro y agrega lo nuevo
   — clientes, 6 fotos, grupos combinados y datos de envío — sin borrar nada)
3. Authentication > Users > Add user (tu email y contraseña)
4. En el SQL Editor ejecutá (con tu email):
   insert into public.admins (user_id) select id from auth.users where email = 'TU-EMAIL';
5. Project Settings > API: copiá "Project URL" y "anon public key" dentro de `config.js`
6. Subí `index.html`, `admin.html` y `config.js` a la misma carpeta de tu hosting
   - Tienda: /index.html
   - Panel:  /admin.html  (ingresás con el usuario del paso 3)

## Cotización en vivo (barra superior del panel)
- Muestra el valor de COMPRA de Dólar (blue), USDT, Real y Euro (fuente: dolarapi.com).
- "Tienda ⇄ ARS" = cotización base elegida + el % de interés que escribas. Ese valor se usa
  para los precios en pesos de TODOS los productos que no tengan un precio en pesos fijo.
- "Auto" actualiza la tienda cada minuto mientras el panel esté abierto; el botón ⟳ lo hace al instante.

## Tramos combinados
En un producto, el campo "Grupo de tramos combinados" (ej: Audio) hace que las unidades de todos
los productos de ese grupo se sumen para alcanzar el tramo mayorista, en el carrito y en el servidor.

## Clientes
Panel > Clientes: alta manual, importación de Excel/CSV (columnas: Nombre, DNI, Teléfono,
Código Postal, Localidad, Dirección, Email, Empresa de envío, Tipo) y CRM de recontactos.
Los clientes que compran desde la tienda se crean/actualizan solos (por DNI).
