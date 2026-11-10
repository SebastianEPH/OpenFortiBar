<p align="center"><img src="Resources/openfortibar-logo.png" width="128" alt="OpenForti Bar"></p>

# OpenForti Bar

**Una alternativa ligera a FortiClient para macOS.** OpenForti Bar es una app de barra de menús que conecta a VPNs SSL de Fortinet (FortiGate) usando [openfortivpn](https://github.com/adrienverge/openfortivpn), con login SSO/SAML en tu navegador.

Si en tu empresa todos usan FortiClient, OpenForti Bar hace lo mismo sin el peso: no tiene agente en segundo plano, telemetría ni extensiones del sistema. Es solo un ícono en la barra que se pone verde al conectarse.

> OpenForti Bar no está afiliado a Fortinet. "FortiClient" y "FortiGate" son marcas de Fortinet, Inc.

## Funciones

- Conectar y desconectar con un clic desde la barra de menús, con un punto de color para el estado
- Login SAML/SSO: abre automáticamente la página de autenticación en el navegador
- Carpeta personal `~/.openforti` (como `~/.ssh` o `~/.aws`) con tus perfiles, certificados e íconos, protegida con permisos 700/600
- Backup y restauración desde ⚙︎ (perfiles, certificados, íconos y preferencias en un `.zip`)
- DNS dividido: los dominios internos se resuelven con el DNS de la VPN (`# dns-domains:` en el perfil)
- No pide contraseña de administrador cada vez: un helper root mínimo y protegido, con una regla `sudo` limitada
- Configuración (⚙︎ / ⌘,): ocho íconos para elegir (Escudo, UTP, Candado, Red, Llave, Túnel, Mundo) o una imagen tuya, y un ícono distinto para cada conexión; logs, actualizaciones y más
- Botón **Actualizar** que instala el último release de GitHub
- Opción para abrirse al iniciar sesión. La VPN nunca se conecta sola
- CLI opcional: `openforti-cli [perfil]`

## Instalación

1. Instala openfortivpn:
   ```sh
   brew install openfortivpn
   ```
2. Descarga `OpenFortiBar-x.y.z.dmg` desde [Releases](../../releases) y arrastra la app a `/Applications`.
   La app no está notarizada, así que la primera vez haz clic derecho → **Abrir**, o ejecuta:
   ```sh
   xattr -dr com.apple.quarantine /Applications/OpenFortiBar.app
   ```
3. Crea un perfil en `~/.openforti/profiles/<nombre>.conf` (la app crea la carpeta al abrirse; si ya tenías perfiles en `~/.config/openfortivpn`, los copia sola):
   ```ini
   host = vpn.miempresa.com
   port = 443
   # trusted-cert = <sha256 del certificado si no es de una CA pública>
   # dns-domains: miempresa.local corp.miempresa.com
   ```
4. Instala el helper (una sola vez, y de nuevo cada vez que cambies perfiles o actualices openfortivpn):
   ```sh
   sudo /Applications/OpenFortiBar.app/Contents/Resources/install-helper.sh
   ```

## Carpeta `~/.openforti`

```
~/.openforti/              (700)
├── profiles/              perfiles *.conf y certificados *.pem (600)
├── icons/                 ícono personalizado
└── backups/               openforti-backup-AAAAMMDD-HHMMSS.zip
```

Un backup es un `.zip` con `profiles/`, `icons/` y `settings.json` (las preferencias de la app). Al restaurar uno, la app primero guarda el estado actual en `backups/antes-de-restaurar-….zip`.

## Compilar desde el código

Requiere Xcode Command Line Tools y macOS 14 o superior.

```sh
./build.sh 1.0.0     # genera build/OpenFortiBar.app (universal)
./install.sh         # compila, instala en /Applications y abre la app
```

## Releases

Los cambios de cada versión están en [CHANGELOG.md](CHANGELOG.md). La app se actualiza sola desde el panel con el botón **Actualizar**.

Cada push a `main` compila la app en GitHub Actions. Al subir un tag `vX.Y.Z` se publica un Release con el `.dmg`, el `.zip` y los checksums:

```sh
git tag v1.1.0 && git push origin v1.1.0
```

## Seguridad

- El helper vive en `/Library/PrivilegedHelperTools/openfortibar`, con dueño `root:wheel`, y solo ejecuta archivos de esa carpeta.
- `sudoers` solo permite `vpn-helper start <perfil>` y `vpn-helper stop`.
- Los perfiles `.conf` y certificados `.pem` nunca se suben al repo (están en `.gitignore`).

## Licencia

MIT
