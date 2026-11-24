# Cambios

## [1.9.0] - 2026-11-24

### Agregado
- **Isla en el notch**: al conectar, el notch se expande con un brillo verde y «Conectado». Mientras está conectado queda un punto verde con un candado junto al notch. Al reconectar muestra «Reconectando…» con un brillo naranja que late y un ícono que gira. Al desconectar o perder la conexión, muestra un aviso rojo por unos segundos. En pantallas sin notch aparece arriba al centro.
- Opciones en ⚙︎ → Personalización → «Isla en el notch»: activar los avisos y el indicador permanente.

## [1.8.0] - 2026-11-24

### Agregado
- **Reconexión tras suspender sin volver a iniciar sesión.** Antes de que la Mac se suspenda, el túnel se pausa **sin cerrar la sesión en el servidor**. Al despertar se reconecta con esa misma sesión (cookie `SVPNCOOKIE`), sin abrir el navegador. La cookie solo la puede leer root (`/Library/PrivilegedHelperTools/openfortibar/run/session`, 600), nunca aparece en el log y se borra al desconectar a mano o cuando el servidor la invalida.
- Si el servidor ya cerró la sesión (por ejemplo, tras una suspensión larga), se inicia sesión de nuevo en el navegador.
- **Ícono «cargando»**: mientras conecta o reconecta, el punto naranja del ícono parpadea y el panel dice «Reconectando…». El botón pasa a **Cancelar**.

### Nota
- Pulsa **Actualizar componente** en el panel (pide la contraseña de administrador una sola vez): el helper tiene las órdenes nuevas `suspend` y `resume`.

## [1.7.0] - 2026-11-24

### Agregado
- **Reconexión automática** si la VPN se corta estando conectada (por ejemplo, al suspender la Mac o por un corte de red): hasta 5 intentos (a los 3, 10, 20, 30 y 60 s). Al despertar, el intento pendiente se lanza a los 5 s. El panel muestra la cuenta regresiva con **Ahora** y **Cancelar**. Se puede desactivar en ⚙︎ → Conexión → «Suspensión y cortes».
- Opción **«Evitar que la Mac se suspenda sola mientras está conectada»** (desactivada por defecto). Cerrar la tapa o suspender a mano sigue suspendiendo.

## [1.6.2] - 2026-11-24

### Cambiado
- **Configuración separada en pestañas**: **General** (inicio, logs y actualizaciones), **Conexión** (perfil y navegador para el login), **Personalización** (ícono de la app e ícono por conexión) y **Backup**. La app recuerda la última pestaña abierta.

## [1.6.1] - 2026-11-24

### Agregado
- **Elegir el navegador para el login** en ⚙︎ Configuración → «Navegador para el login»: predeterminado del sistema, Safari, Chrome, Edge, Brave, Chromium, Vivaldi, Arc o Firefox (solo los instalados).
- **Elegir el perfil** en Chrome, Edge, Brave, Vivaldi y Chromium (se leen los perfiles del navegador con su nombre y cuenta). «Abrir de nuevo» también usa el navegador y perfil elegidos.
- Opción **«preguntar antes de abrirlo»** si el navegador no está abierto, con la alternativa de usar el predeterminado. Botón **Probar** para verificarlo.
- Estas preferencias se incluyen en los backups.

## [1.6.0] - 2026-11-23

### Cambiado
- **Editor de conexión con formulario**: Nombre, Servidor y puerto, Dominios y «Usar el DNS de la VPN». El texto completo del `.conf` queda en **Avanzado**.
- **Guardar con Touch ID**: los cambios se aplican con tu huella (o la contraseña de tu Mac si no hay huella), sin la ventana de administrador. El helper valida cada perfil y solo acepta opciones conocidas e inofensivas.
- **Certificados generados en cada conexión, en una carpeta temporal**: las raíces de confianza se toman del sistema (las mismas que Safari) y, si falta el certificado intermedio del servidor, se descarga en el momento. Todo se guarda en `/tmp/openfortibar.XXXXXX` (solo root) y se borra al desconectar. Ya no hace falta ningún `.pem` en el perfil.

### Nota
- La primera vez tras actualizar, pulsa **Actualizar componente** en el panel (pide la contraseña de administrador una sola vez).

## [1.5.3] - 2026-11-23

### Cambiado
- **Instalar o actualizar el componente de conexión con un botón**: en lugar de mostrar un comando para Terminal, el panel muestra **Instalar componente** / **Actualizar componente**, que pide tu contraseña con la ventana de macOS y lo hace solo.

## [1.5.2] - 2026-11-23

### Agregado
- **Editor de conexión en ⚙︎ Configuración → Conexión**: elige el perfil, ve y modifica su `.conf` y pulsa **Guardar y aplicar**. macOS pide tu contraseña y el cambio se copia al helper; ya no hace falta abrir Terminal.

### Quitado
- Botón ⓘ junto al selector de conexión (lo reemplaza el editor).

## [1.5.1] - 2026-11-23

### Corregido
- **La VPN ya no falla cuando el servidor renueva su certificado.** Si el gateway no envía su certificado intermedio (como pasó con la UTP el 12/11/2026), el helper lo descarga en cada conexión desde la URL del propio certificado (AIA), igual que un navegador. Solo lo usa si lo firma una CA que ya está en el `ca-file` del perfil, y no guarda nada entre conexiones.

### Agregado
- **Botón ⓘ junto al selector de conexión**: muestra el comando de conexión y el `.conf` que se usa realmente (contraseñas ocultas), avisa si tu copia en `~/.openforti/profiles` es distinta y permite editarla o copiarla.
- **Aviso de helper desactualizado**: después de actualizar la app, si el helper instalado es de una versión anterior, el panel muestra el comando para reinstalarlo.

## [1.5.0] - 2026-11-10

### Agregado
- **Carpeta personal `~/.openforti`**, como `~/.ssh` o `~/.aws`. Ahí viven todos tus datos de OpenForti Bar:
  | Ruta | Contenido |
  |---|---|
  | `~/.openforti/profiles/` | Perfiles `*.conf` y certificados `*.pem` |
  | `~/.openforti/icons/` | Ícono personalizado (`custom-icon.png`) |
  | `~/.openforti/backups/` | Backups `.zip` |
  - **Permisos como `~/.ssh`**: carpetas `700` y archivos `600`, así que solo tu usuario puede leerlos. Se aplican al abrir la app y después de restaurar un backup.
  - **Migración automática**: al abrir la app, si `~/.openforti/profiles` está vacía, se copian los perfiles y certificados de `~/.config/openfortivpn`. La ruta `ca-file` de cada perfil se actualiza a la carpeta nueva. El ícono personalizado se copia desde `~/Library/Application Support/OpenFortiBar`.
- **Sección «Backup»** en ⚙︎ Configuración:
  - **Crear backup**: guarda un `.zip` en `~/.openforti/backups/openforti-backup-AAAAMMDD-HHMMSS.zip`.
  - **Guardar en…**: igual, pero eliges dónde guardarlo (por ejemplo iCloud Drive o una USB).
  - **Restaurar…**: elige un backup y reemplaza perfiles, certificados, íconos y preferencias. **Antes de restaurar se guarda automáticamente** el estado actual en `backups/antes-de-restaurar-….zip`, por si te equivocas de archivo.
  - Botón 📁 para abrir `~/.openforti` en Finder.
  - Debajo se ve cuántos backups hay y cuál es el último, o el resultado de la última acción (en verde si salió bien, en rojo si hubo error).
  - **Qué incluye un backup**: `profiles/`, `icons/` y `settings.json` con la versión de la app, la fecha y las preferencias (ícono de la app, íconos por conexión, atenuar ícono, mostrar logs, buscar actualizaciones y conexión seleccionada).
  - Se valida que el `.zip` sea un backup de OpenForti Bar antes de tocar nada.

### Cambiado
- La app y el instalador del helper ahora leen los perfiles de **`~/.openforti/profiles`**. Si esa carpeta no existe, `install-helper.sh` sigue usando `~/.config/openfortivpn`.
- El botón «Abrir carpeta de perfiles» y los textos de ayuda apuntan a `~/.openforti/profiles`.
- El ícono personalizado se guarda en `~/.openforti/icons/` en lugar de `~/Library/Application Support/OpenFortiBar/`.

### Quitado
- Nada se borra: `~/.config/openfortivpn` y el ícono anterior quedan donde estaban. Puedes eliminarlos a mano cuando confirmes que todo funciona.

### QA
- Migración: los 3 archivos (`utp.conf` y 2 certificados `.pem`) se copiaron con permisos `600`, las carpetas quedaron en `700` y `ca-file` apunta a `~/.openforti/profiles`.
- Backup → restaurar: se creó un backup, se restauró, se generó el respaldo previo automático y las preferencias quedaron idénticas a las de antes.
- Revisión visual de la pantalla de configuración con la nueva sección.
- Para desarrolladores: `OPENFORTIBAR_QA_BACKUP=1` repite la prueba de backup y restauración.

### Notas
- Después de editar o restaurar perfiles, ejecuta el comando del helper (⚙︎ → «Copiar comando del helper») para que la VPN use los cambios.

## [1.4.3] - 2026-11-10

### Corregido
- **El panel quedaba con un espacio vacío o se estiraba** al entrar y salir de ⚙︎ Configuración, o al mostrar u ocultar los logs. El arreglo de 1.4.1 no alcanzaba: la ventana de `MenuBarExtra` no se adapta bien cuando cambia el alto del contenido, y forzar su tamaño desde fuera hacía que se estirara.

### Cambiado
- **Nueva forma de mostrar el panel**: se reemplazó `MenuBarExtra` de SwiftUI por un ícono `NSStatusItem` con un `NSPopover` nativo de macOS. El popover toma el tamaño exacto de su contenido en todo momento:
  - Pantalla principal → Configuración → volver: el panel crece y vuelve a su alto original, siempre pegado a la barra.
  - Con o sin logs: el panel se ajusta al instante.
- El panel ahora tiene la flecha de popover que apunta al ícono, y se cierra al hacer clic fuera.
- Al cerrar el panel estando en Configuración, la próxima vez se abre en la pantalla principal.
- El tooltip del ícono («OpenForti Bar — Conectado», etc.) se asigna directamente al botón de la barra, sin buscarlo entre las ventanas.

### Quitado
- El código que reajustaba a mano la ventana de `MenuBarExtra` (agregado en 1.4.1), que ya no hace falta.

### QA
- Se probó con capturas en cada paso: abrir → Configuración → volver → ocultar logs → Configuración → volver → mostrar logs. En todos los pasos el panel quedó del alto correcto, sin huecos ni estiramiento.
- Para desarrolladores: con `OPENFORTIBAR_QA=1` la app recorre esa secuencia sola, para repetir la prueba.

### Notas
- Actualiza desde ⚙︎ → Actualizaciones. No hace falta reinstalar el helper.

## [1.4.2] - 2026-11-10

### Cambiado
- **Las actualizaciones ahora están en la configuración (⚙︎)**, en una sección nueva llamada **«Actualizaciones»**, y ya no en el panel principal. La sección muestra:
  - La versión instalada.
  - El estado: «Buscando…», «Estás en la última versión», «Nueva versión vX.Y.Z» o el error.
  - El botón **Buscar actualizaciones** o, si hay una versión nueva, **Actualizar ahora**.
  - La opción «Buscar actualizaciones al abrir el panel», que antes estaba en «General».
- El panel principal queda más limpio: estado, conexión, logs y pie.

### Agregado
- **Aviso en el engranaje**: cuando hay una versión nueva, el botón ⚙︎ muestra un punto naranja, y al pasar el mouse dice qué versión está disponible.

### Quitado
- La fila de versión y actualizaciones que estaba encima del pie del panel principal.

### Notas
- La búsqueda automática sigue funcionando igual: se hace al abrir el panel, si está activada.

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
