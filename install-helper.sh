#!/bin/zsh
# Instala el helper root de OpenForti Bar para conectar/desconectar sin contraseña.
# Ejecutar como root una vez, y de nuevo al actualizar openfortivpn o cambiar perfiles:
#   sudo ./install-helper.sh <usuario>
#
# Copia a /Library/PrivilegedHelperTools/openfortibar (root:wheel):
#   vpn-helper, bin/openfortivpn + lib/ (OpenSSL), profiles/ (desde ~/.config/openfortivpn)
# y crea /etc/sudoers.d/openfortibar permitiendo solo "vpn-helper start <perfil>" y "vpn-helper stop".
set -e
[[ $EUID == 0 ]] || { print -u2 "Ejecuta con sudo."; exit 1 }
USER_NAME=${1:-$SUDO_USER}
[[ -n $USER_NAME && $USER_NAME != root ]] || { print -u2 "Indica el usuario: sudo $0 <usuario>"; exit 1 }
USER_HOME=$(dscl . -read /Users/$USER_NAME NFSHomeDirectory | awk '{ print $2 }')

SRC=${0:A:h}
BASE=/Library/PrivilegedHelperTools/openfortibar
PROFILES_SRC=$USER_HOME/.config/openfortivpn

install -d -o root -g wheel -m 755 $BASE $BASE/bin $BASE/lib $BASE/profiles $BASE/run
HELPER_SRC=$SRC/vpn-helper.sh; [[ -f $HELPER_SRC ]] || HELPER_SRC=$SRC/Resources/vpn-helper.sh
install -o root -g wheel -m 755 $HELPER_SRC $BASE/vpn-helper

# openfortivpn y sus librerías de Homebrew, enlazadas a las copias protegidas
OFV=${$(readlink -f /opt/homebrew/bin/openfortivpn)}
install -o root -g wheel -m 755 $OFV $BASE/bin/openfortivpn
libs=($(otool -L $OFV | awk 'NR > 1 && $1 ~ /^\/opt\/homebrew\// { print $1 }'))
for lib in $libs; do
  install -o root -g wheel -m 644 $(readlink -f $lib) $BASE/lib/${lib:t}
done
for file in $BASE/bin/openfortivpn $BASE/lib/*.dylib; do
  [[ $file == *.dylib ]] && install_name_tool -id $BASE/lib/${file:t} $file
  for dep in $(otool -L $file | awk 'NR > 1 && $1 ~ /^\/opt\/homebrew\// { print $1 }'); do
    install_name_tool -change $dep $BASE/lib/${dep:t} $file
  done
  codesign --force --sign - $file 2>/dev/null
done

# Perfiles y certificados; ca-file pasa a apuntar a la copia protegida
rm -f $BASE/profiles/*(N)
for f in $PROFILES_SRC/*.(conf|pem)(N); do
  install -o root -g wheel -m 644 $f $BASE/profiles/${f:t}
done
for conf in $BASE/profiles/*.conf(N); do
  sed -i '' -E "s|^(ca-file *= *).*/([^/]+)$|\\1$BASE/profiles/\\2|" $conf
done

# Regla sudo: solo conectar y desconectar
SUDOERS=$(mktemp)
cat > $SUDOERS <<EOF
# OpenForti Bar: conectar/desconectar sin contraseña (solo el helper protegido)
$USER_NAME ALL=(root) NOPASSWD: $BASE/vpn-helper start *, $BASE/vpn-helper stop
EOF
visudo -cf $SUDOERS >/dev/null
install -o root -g wheel -m 440 $SUDOERS /etc/sudoers.d/openfortibar
rm -f $SUDOERS

print "Helper instalado en $BASE"
ls $BASE/profiles
