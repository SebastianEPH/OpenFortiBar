# Cambios

## [1.4.1] - 2026-11-10

### Corregido
- **El panel se desordenaba al ocultar los logs.** Al desactivar «Mostrar logs en el panel», al abrir o cerrar la configuración o al expandir o contraer los logs, la ventana mantenía su alto anterior, así que el contenido quedaba cortado o con un espacio vacío. Ahora el panel recalcula su alto cada vez que cambia el contenido, manteniendo el borde superior pegado a la barra de menús.

### Agregado
- Nada.

### Cambiado
- El panel ajusta su alto a lo que muestra en cada momento: es más bajo sin logs y más alto en la configuración.

### Quitado
- Nada.

### Notas
- Actualiza desde el botón **Actualizar** del panel. No hace falta reinstalar el helper.

## [1.4.0] - 2026-11-10

### Agregado
- **Ícono por conexión**: cada perfil de `~/.config/openfortivpn` puede tener su propio ícono.
  - Se configura en ⚙︎ → **Ícono por conexión**, con un selector por cada conexión.
  - Al **seleccionar una conexión** en el panel, el ícono de la barra de menús y el del panel cambian enseguida, sin tener que conectarse.
  - Opción **«Igual que la app»** (por defecto): la conexión usa el ícono general.
  - Se pueden elegir los mismos 8 íconos (Escudo, UTP, Candado, Red, Llave, Túnel, Mundo y Personalizado, si ya elegiste una imagen).
  - Ejemplo: app con «Escudo» y la conexión `utp` con «UTP». Al elegir `utp` en el panel, la barra muestra el logo de la UTP; con otra conexión vuelve el escudo.

### Cambiado
- En la configuración, la sección «Ícono» ahora se llama **«Ícono de la app»**. Es el ícono por defecto, el que se usa cuando una conexión no tiene uno propio.

### Quitado
- Nada.

### Notas
- Los íconos por conexión se guardan en las preferencias de la app (clave `profileIcons`), no en los archivos `.conf`.
- Si renombras un archivo `.conf`, tendrás que volver a asignarle su ícono.
- No hace falta reinstalar el helper. Actualiza desde el botón **Actualizar** del panel.

## [1.3.0] - 2026-11-10

### Agregado
- **Botón de configuración (⚙︎)** en la parte inferior del panel, también con **⌘,**. Abre la pantalla «Configuración» dentro del mismo panel; la flecha ‹ vuelve al panel principal.
- **Elegir el ícono** de la barra de menús y del panel. Hay 8 opciones:
  | Opción | Tipo |
  |---|---|
  | Escudo | Logo de OpenForti Bar (por defecto) |
  | UTP | Logo a color incluido como recurso (`Resources/utp-logo.png`) |
  | Candado | Símbolo del sistema `lock.shield.fill` |
  | Red | Símbolo del sistema `network.badge.shield.half.filled` |
  | Llave | Símbolo del sistema `key.fill` |
  | Túnel | Símbolo del sistema `bolt.horizontal.circle.fill` |
  | Mundo | Símbolo del sistema `globe.americas.fill` |
  | Personalizado | Cualquier imagen PNG/JPEG/TIFF/HEIC elegida con «Elegir imagen…» |
  - Los símbolos del sistema toman el color de la barra de menús, así que se ven bien en modo claro y oscuro.
  - La imagen personalizada se copia a `~/Library/Application Support/OpenFortiBar/custom-icon.png`, así que puedes borrar o mover el archivo original.
  - El cambio se aplica al instante, sin reiniciar la app.
- Opción **«Atenuar el ícono cuando está desconectado»** (activada por defecto).
- Opción **«Mostrar logs en el panel»**: oculta por completo la sección de logs.
- Opción **«Buscar actualizaciones al abrir el panel»**: si la desactivas, solo se busca con el botón manual.
- Sección **Conexiones** en la configuración, con los botones «Abrir carpeta de perfiles» y «Copiar comando del helper» (copia el comando `sudo … install-helper.sh` al portapapeles).

### Cambiado
- «Abrir al iniciar sesión» ahora también está en la configuración; en el pie del panel sigue disponible el atajo.
- La sección de logs recuerda si estaba expandida o contraída, sin depender de si está visible.

### Quitado
- Nada.

### Notas
- No hace falta reinstalar el helper.
- Si vienes de la 1.2.0, usa el botón **Actualizar** del panel.

## [1.2.0] - 2026-11-10

### Agregado
- **Actualización automática desde GitHub**: al abrir el panel se consulta el último release y aparece la versión instalada (p. ej. `v1.2.0`) en la parte inferior.
  - Si hay una versión nueva se muestra «Nueva versión vX.Y.Z» y el botón **Actualizar**.
  - **Actualizar** descarga el `.zip` del release, desconecta la VPN si está activa, reemplaza la app en su ubicación actual y la vuelve a abrir.
  - Botón **Buscar actualizaciones** para consultar manualmente; indica «Estás en la última versión» o el error si GitHub no responde.

### Cambiado
- El botón **Salir** (⏻ / ⌘Q) y el actualizador comparten la misma lógica para cerrar el túnel antes de salir.

### Notas
- El helper no cambia: si ya lo instalaste con 1.1.0 no hace falta reinstalarlo.

## [1.1.0] - 2026-11-10

### Agregado
- Botón **Salir** (⏻) en la esquina inferior derecha del panel, también con **⌘Q**. Si la VPN está conectada, primero la desconecta y luego cierra la app, para no dejar el túnel abierto.

### Cambiado
- **Nuevo nombre: OpenForti Bar** (antes TunnelBar). Se renombraron:
  - La app: `TunnelBar.app` → `OpenFortiBar.app`, identificador `io.github.sebastianeph.openfortibar`.
  - El helper: `/Library/PrivilegedHelperTools/tunnelbar` → `/Library/PrivilegedHelperTools/openfortibar`, y la regla `/etc/sudoers.d/openfortibar`.
  - El script de terminal: `tunnelbar-cli` → `openforti-cli`.
  - Los archivos del release: `OpenFortiBar-X.Y.Z.dmg` / `.zip`.
  - El repositorio: `SebastianEPH/TunnelBar` → `SebastianEPH/OpenFortiBar` (el enlace viejo redirige).

### Quitado
- Todas las referencias a «TunnelBar».

### Notas
- **Hay que reinstalar el helper** porque cambió su ruta: `sudo /Applications/OpenFortiBar.app/Contents/Resources/install-helper.sh`.

## [1.0.0] - 2026-11-10

Primera versión pública.

### Agregado
- App de barra de menús para macOS 14+ que conecta a VPNs SSL de Fortinet con [openfortivpn](https://github.com/adrienverge/openfortivpn), como alternativa ligera a FortiClient.
- Login SAML/SSO: abre automáticamente la página de autenticación en el navegador y permite reabrirla.
- Varios perfiles de conexión desde `~/.config/openfortivpn/*.conf`, con selector en el panel.
- DNS dividido: los dominios de `# dns-domains:` en el perfil se resuelven con el DNS de la VPN.
- Helper root protegido y regla `sudo` limitada a `start <perfil>` y `stop`, para conectar sin pedir contraseña.
- Ícono con punto de estado (verde: conectado, naranja: en proceso), detalles de la conexión y visor de logs.
- Opción «Abrir al iniciar sesión» (la VPN nunca se conecta sola).
- Script de terminal `tunnelbar-cli [perfil]`.
- Compilación universal (Apple Silicon + Intel), `.dmg` y `.zip` generados por GitHub Actions con checksums SHA-256.
