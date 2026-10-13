# Puesta en marcha (10 minutos)

1. Creá un proyecto en https://supabase.com
2. SQL Editor > New query > pegá `supabase.sql` > Run
3. Authentication > Users > Add user (tu email y contraseña)
4. En el SQL Editor ejecutá (con tu email):
   insert into public.admins (user_id) select id from auth.users where email = 'TU-EMAIL';
5. Project Settings > API: copiá "Project URL" y "anon public key" dentro de `config.js`
6. Subí `index.html`, `admin.html` y `config.js` a la misma carpeta de tu hosting
   - Tienda: /index.html
   - Panel:  /admin.html  (ingresás con el usuario del paso 3)

Desde el panel: altas/bajas/edición de productos y categorías, fotos, pedidos con estados, y los textos de la portada.
