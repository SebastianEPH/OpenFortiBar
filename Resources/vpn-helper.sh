#!/bin/zsh
# Helper root de OpenForti Bar. Se instala en /Library/PrivilegedHelperTools/openfortibar (todo root:wheel)
# y se invoca sin contraseña con "sudo -n" gracias a /etc/sudoers.d/openfortibar.
#
# Uso: vpn-helper start <perfil>   conecta profiles/<perfil>.conf (login SSO en el navegador)
#      vpn-helper stop             cierra cualquier openfortivpn en curso
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

# El gateway puede no enviar su certificado intermedio (openfortivpn no lo descarga, los navegadores sí).
# Si la validación falla, se descarga el intermedio desde la URL AIA del propio certificado y se usa
# solo si lo firma una CA que ya está en el ca-file del perfil. Se hace en cada conexión, sin caché.
ca_with_chain() {
  local conf=$1 name=${1:t:r}
  local ca=$(conf_value ca-file $conf) host=$(conf_value host $conf) port=$(conf_value port $conf)
  port=${port:-443}
  local merged=$RUN/$name-ca.pem
  [[ -f $ca && -n $host ]] || { print $ca; return }
  # Cada conexión empieza de cero: nada de conexiones anteriores se reutiliza.
  rm -f $RUN/$name-aia-*.pem(N)
  cp $ca $merged

  # Se valida con "openssl verify" sobre el certificado descargado: el "Verify return code" de
  # s_client en LibreSSL dice "ok" aunque la cadena esté incompleta.
  local leaf=$RUN/$name-leaf.pem
  echo | openssl s_client -connect $host:$port -servername $host 2>/dev/null | openssl x509 > $leaf 2>/dev/null ||
    { rm -f $leaf; print $merged; return }
  if openssl verify -CAfile $merged $leaf >/dev/null 2>&1; then rm -f $leaf; print $merged; return; fi

  local url=$(openssl x509 -in $leaf -noout -text | sed -n 's/.*CA Issuers - URI:\(http[^ ,]*\).*/\1/p' | head -1)
  [[ -n $url ]] || { print $ca; return }
  local tmp=$RUN/$name-aia.tmp
  if curl -fsS --max-time 10 $url -o $tmp.der &&
     { openssl x509 -inform der -in $tmp.der -out $tmp 2>/dev/null || openssl x509 -in $tmp.der -out $tmp 2>/dev/null } &&
     openssl verify -CAfile $ca $tmp >/dev/null 2>&1 &&
     openssl verify -CAfile $ca -untrusted $tmp $leaf >/dev/null 2>&1; then
    cat $tmp >> $merged
    print "INFO:   Certificado intermedio descargado para esta conexión: $(openssl x509 -in $tmp -noout -subject)" >> $LOG
  else
    print "WARN:   No se pudo completar la cadena del certificado desde $url" >> $LOG
  fi
  rm -f $tmp $tmp.der $leaf
  print $merged
}

run_tunnel() {
  local conf=$1
  trap '' HUP
  dns_clear
  local before=($(nameservers))
  local ca=$(ca_with_chain $conf)

  $OPENFORTIVPN -c $conf ${ca:+--ca-file=$ca} --saml-login >> $LOG 2>&1 &
  local pid=$!
  trap 'kill -TERM $pid 2>/dev/null' TERM INT

  local dns_done=0
  while kill -0 $pid 2>/dev/null; do
    if (( !dns_done )) && grep -q "Tunnel is up and running" $LOG; then
      dns_done=1
      local after=($(nameservers))
      dns_set $conf ${after:|before}
    fi
    sleep 1
  done

  wait $pid
  dns_clear
  print "INFO:   Desconectado." >> $LOG
  rm -f $PIDFILE
}

case $1 in
  start)
    profile=$2
    if [[ ! $profile =~ '^[A-Za-z0-9_-]+$' || ! -f $BASE/profiles/$profile.conf ]]; then
      print -u2 "Perfil no encontrado: $profile"
      exit 2
    fi
    if runner_alive || pgrep -qx openfortivpn; then
      print -u2 "Ya hay una VPN activa."
      exit 1
    fi
    : > $LOG
    run_tunnel $BASE/profiles/$profile.conf </dev/null >/dev/null 2>&1 &!
    print $! > $PIDFILE   # $$ en el subshell sería el PID de este script, no el del túnel
    ;;
  stop)
    pkill -TERM -x openfortivpn
    exit 0
    ;;
  *)
    print -u2 "Uso: vpn-helper start <perfil> | vpn-helper stop"
    exit 64
    ;;
esac
