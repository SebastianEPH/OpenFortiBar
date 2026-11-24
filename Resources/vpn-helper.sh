#!/bin/zsh
# Helper root de OpenForti Bar. Se instala en /Library/PrivilegedHelperTools/openfortibar (todo root:wheel)
# y se invoca sin contraseña con "sudo -n" gracias a /etc/sudoers.d/openfortibar.
#
# Uso: vpn-helper start <perfil>   conecta profiles/<perfil>.conf (login SSO en el navegador)
#      vpn-helper stop             cierra cualquier openfortivpn en curso (y cierra la sesión en el servidor)
#      vpn-helper suspend          antes de suspender: corta el túnel SIN cerrar la sesión en el servidor
#      vpn-helper resume           al despertar: reconecta con la sesión guardada, sin volver a iniciar sesión
#      vpn-helper import           copia y valida ~/.openforti/profiles en la carpeta protegida
#
# Solo ejecuta archivos de esta carpeta protegida; nada editable por el usuario corre como root.

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# Evita que OpenSSL cargue configuración o módulos desde rutas de Homebrew (editables por el usuario)
export OPENSSL_CONF=/dev/null OPENSSL_MODULES=/var/empty OPENSSL_ENGINES=/var/empty
umask 022

BASE=/Library/PrivilegedHelperTools/openfortibar
RUN=$BASE/run
LOG=$RUN/vpn.log
PIDFILE=$RUN/runner.pid
# Sesión de la última conexión (cookie SVPNCOOKIE): solo root puede leerla. Se borra cuando el servidor
# la invalida (logout o autenticación rechazada) y al desconectar a mano.
SESSION=$RUN/session
PROFILE_FILE=$RUN/profile
SUSPENDED=$RUN/suspended
OPENFORTIVPN=$BASE/bin/openfortivpn
DNS_KEY=State:/Network/Service/openfortibar/DNS

runner_alive() { [[ -f $PIDFILE ]] && kill -0 $(<$PIDFILE) 2>/dev/null }

nameservers() { awk '/^nameserver/ { print $2 }' /etc/resolv.conf }

dns_clear() { print "remove $DNS_KEY" | scutil }

# Envía los dominios "# dns-domains:" del perfil a los DNS que agregó la VPN
dns_set() {
  local conf=$1; shift
  local servers=("$@")
  local domains=(${=$(sed -n 's/^# *dns-domains *[:=] *//p' $conf)})
  (( ${#servers} && ${#domains} )) || return 0
  scutil <<EOF
d.init
d.add ServerAddresses * ${servers[*]}
d.add SupplementalMatchDomains * ${domains[*]}
set $DNS_KEY
EOF
  print "INFO:   DNS de la VPN (${servers[*]}) para: ${domains[*]}" >> $LOG
}

conf_value() { sed -n "s/^ *$1 *= *//p" $2 | head -1 }

# Arma, para esta conexión, el archivo de CAs que usa openfortivpn y devuelve su carpeta temporal:
#   - raíces de confianza del sistema (las mismas que Safari) + el ca-file del perfil, si tiene;
#   - si el gateway no envía su certificado intermedio (openfortivpn no lo descarga, los navegadores sí),
#     se descarga desde la URL AIA del propio certificado y se usa solo si lo firma una de esas raíces.
# Todo vive en /tmp/openfortibar.XXXXXX (solo root) y se borra al desconectar; nada se reutiliza.
build_ca() {
  local conf=$1
  local ca=$(conf_value ca-file $conf) host=$(conf_value host $conf) port=$(conf_value port $conf)
  port=${port:-443}
  local dir=$(mktemp -d /tmp/openfortibar.XXXXXX) || return
  chmod 700 $dir
  local roots=$dir/ca.pem leaf=$dir/leaf.pem aia=$dir/aia.pem
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain > $roots 2>/dev/null
  [[ -f $ca ]] && cat $ca >> $roots
  print $dir
  [[ -n $host ]] || return

  # "openssl verify" sobre el certificado descargado: el "Verify return code" de s_client en LibreSSL
  # dice "ok" aunque la cadena esté incompleta.
  echo | openssl s_client -connect $host:$port -servername $host 2>/dev/null | openssl x509 > $leaf 2>/dev/null || return
  openssl verify -CAfile $roots $leaf >/dev/null 2>&1 && return

  local url=$(openssl x509 -in $leaf -noout -text | sed -n 's/.*CA Issuers - URI:\(http[^ ,]*\).*/\1/p' | head -1)
  if [[ -n $url ]] && curl -fsS --max-time 10 $url -o $aia.der &&
     { openssl x509 -inform der -in $aia.der -out $aia 2>/dev/null || openssl x509 -in $aia.der -out $aia 2>/dev/null } &&
     openssl verify -CAfile $roots -untrusted $aia $leaf >/dev/null 2>&1; then
    cat $aia >> $roots
    print "INFO:   Certificado intermedio descargado para esta conexión: $(openssl x509 -in $aia -noout -subject)" >> $LOG
  else
    print "WARN:   No se pudo completar la cadena del certificado del servidor${url:+ desde $url}" >> $LOG
  fi
}

# Copia la salida de openfortivpn al log. La línea "Cookie:" (solo sale con -v) se guarda en $SESSION
# y nunca llega al log; el resto de líneas DEBUG se descartan.
filter_log() {
  local line
  while IFS= read -r line; do
    case $line in
      DEBUG:*Cookie:\ SVPNCOOKIE=*)
        ( umask 077; print -rn -- "${line#*Cookie: }" > $SESSION.tmp && mv -f $SESSION.tmp $SESSION ) ;;
      DEBUG:*) ;;
      *) print -r -- "$line" >> $LOG ;;
    esac
  done
}

# Servidores DNS que entregó el gateway en esta conexión ("Got addresses: [...], ns [a, b]").
vpn_nameservers() {
  tail -n +$(( $1 + 1 )) $LOG | sed -n 's/.*Got addresses:.*ns \[\(.*\)\].*/\1/p' | tail -1 | tr -d ' ' | tr ',' ' '
}

run_tunnel() {
  local conf=$1 mode=$2
  trap '' HUP
  dns_clear
  local before=($(nameservers))
  local tmpdir=$(build_ca $conf)
  local mark=$(wc -l < $LOG)

  if [[ $mode == resume ]]; then
    print "INFO:   Reconectando con la sesión guardada (sin volver a iniciar sesión)…" >> $LOG
    $OPENFORTIVPN -c $conf ${tmpdir:+--ca-file=$tmpdir/ca.pem} -v --cookie-on-stdin < $SESSION > >(filter_log) 2>&1 &
  else
    $OPENFORTIVPN -c $conf ${tmpdir:+--ca-file=$tmpdir/ca.pem} -v --saml-login < /dev/null > >(filter_log) 2>&1 &
  fi
  local pid=$!
  trap 'kill -TERM $pid 2>/dev/null' TERM INT

  local dns_done=0
  while kill -0 $pid 2>/dev/null; do
    if (( !dns_done )) && tail -n +$(( mark + 1 )) $LOG | grep -q "Tunnel is up and running"; then
      dns_done=1
      local servers=(${=$(vpn_nameservers $mark)})
      if (( ! ${#servers} )); then local after=($(nameservers)); servers=(${after:|before}); fi
      dns_set $conf $servers
    fi
    sleep 1
  done

  wait $pid
  sleep 0.3   # deja que filter_log termine de escribir
  [[ $tmpdir == /tmp/openfortibar.* ]] && rm -rf $tmpdir
  dns_clear
  # Si el servidor cerró o rechazó la sesión, ya no sirve para reconectar.
  if [[ ! -f $SUSPENDED ]] && tail -n +$(( mark + 1 )) $LOG | grep -q -E "Logged out\.|Could not authenticate"; then
    rm -f $SESSION
  fi
  if [[ -f $SUSPENDED ]]; then
    print "INFO:   Túnel en pausa por suspensión; la sesión se mantiene para reconectar al despertar." >> $LOG
  else
    print "INFO:   Desconectado." >> $LOG
  fi
  rm -f $PIDFILE
}

openfortivpn_running() { pgrep -qx openfortivpn }

# Copia los perfiles del usuario (~/.openforti/profiles) a la carpeta protegida, sin contraseña.
# Como openfortivpn corre como root, solo se aceptan opciones conocidas e inofensivas: nada que
# ejecute programas (pinentry, pppd-plugin, ...) ni escriba archivos. Los .pem se copian junto al perfil.
ALLOWED=(host port realm username set-dns set-routes pppd-use-peerdns half-internet-routes
         ca-file user-cert user-key trusted-cert cipher-list min-tls seclevel-1 sni persistent no-ftm-push
         otp-prompt otp-delay)
import_profiles() {
  local user=${SUDO_USER:?}
  local home=$(dscl . -read /Users/$user NFSHomeDirectory | awk '{ print $2 }')
  local src=$home/.openforti/profiles
  [[ -d $src ]] || { print -u2 "No existe $src"; exit 2 }
  local staging=$(mktemp -d /tmp/openfortibar-import.XXXXXX)
  local f line key value
  for f in $src/*.conf(N); do
    [[ ${f:t:r} =~ '^[A-Za-z0-9_-]+$' && ! -L $f ]] || continue
    : > $staging/${f:t}
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line == \#* || -z ${line// } ]]; then print -r -- $line >> $staging/${f:t}; continue; fi
      key=${${line%%=*}// }; value=$(print -r -- "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      (( ${ALLOWED[(Ie)$key]} )) || { print -u2 "Opción no permitida en ${f:t}: $key"; rm -rf $staging; exit 3 }
      if [[ $key == (ca-file|user-cert|user-key) ]]; then
        local pem=$src/${value:t}
        [[ -f $pem && ! -L $pem && ${value:t} == *.pem ]] || { print -u2 "No se encontró ${value:t} en $src"; rm -rf $staging; exit 3 }
        cp $pem $staging/${value:t}
        value=$BASE/profiles/${value:t}
      fi
      print -r -- "$key = $value" >> $staging/${f:t}
    done < $f
  done
  rm -f $BASE/profiles/*(N)
  for f in $staging/*(N); do install -o root -g wheel -m 644 $f $BASE/profiles/${f:t}; done
  rm -rf $staging
}

case $1 in
  start)
    profile=$2
    if [[ ! $profile =~ '^[A-Za-z0-9_-]+$' || ! -f $BASE/profiles/$profile.conf ]]; then
      print -u2 "Perfil no encontrado: $profile"
      exit 2
    fi
    if runner_alive || openfortivpn_running; then
      print -u2 "Ya hay una VPN activa."
      exit 1
    fi
    rm -f $SESSION $SUSPENDED
    print -r -- $profile > $PROFILE_FILE
    : > $LOG
    run_tunnel $BASE/profiles/$profile.conf saml </dev/null >/dev/null 2>&1 &!
    print $! > $PIDFILE   # $$ en el subshell sería el PID de este script, no el del túnel
    ;;
  stop)
    rm -f $SESSION $SUSPENDED
    pkill -TERM -x openfortivpn
    exit 0
    ;;
  suspend)
    # SIGKILL: openfortivpn no alcanza a hacer logout, así la sesión sigue válida en el servidor.
    # pppd se cierra solo al perder su pty (y se le avisa igual); las rutas de ppp0 desaparecen con la interfaz.
    [[ -f $SESSION ]] && openfortivpn_running || { print -u2 "No hay una sesión activa para pausar."; exit 4 }
    touch $SUSPENDED
    ofv=($(pgrep -x openfortivpn)) ppp=()
    for p in $ofv; do ppp+=($(pgrep -P $p -x pppd)); done
    kill -KILL $ofv 2>/dev/null
    (( ${#ppp} )) && kill -TERM $ppp 2>/dev/null
    for i in {1..20}; do runner_alive || break; sleep 0.1; done
    exit 0
    ;;
  resume)
    profile=$(<$PROFILE_FILE 2>/dev/null)
    if [[ ! -f $SESSION || ! $profile =~ '^[A-Za-z0-9_-]+$' || ! -f $BASE/profiles/$profile.conf ]]; then
      rm -f $SUSPENDED
      print -u2 "No hay una sesión guardada."
      exit 4
    fi
    if runner_alive || openfortivpn_running; then
      print -u2 "Ya hay una VPN activa."
      exit 1
    fi
    rm -f $SUSPENDED
    run_tunnel $BASE/profiles/$profile.conf resume </dev/null >/dev/null 2>&1 &!
    print $! > $PIDFILE
    ;;
  import)
    import_profiles
    ;;
  *)
    print -u2 "Uso: vpn-helper start <perfil> | stop | suspend | resume | import"
    exit 64
    ;;
esac
