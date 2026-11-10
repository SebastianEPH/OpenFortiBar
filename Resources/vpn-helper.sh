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

run_tunnel() {
  local conf=$1
  trap '' HUP
  dns_clear
  local before=($(nameservers))

  $OPENFORTIVPN -c $conf --saml-login >> $LOG 2>&1 &
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
