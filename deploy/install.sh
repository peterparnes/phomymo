#!/usr/bin/env bash
# Publishes Pho (Phomymo) on Apache at https://phomymo.parnes.com.
set -Eeuo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# build.sh and apache.conf come from the checkout, not from beside this script: the server
# dashboard runs a root-owned copy of it from elsewhere, with REPO_DIR set to the checkout.
HERE="$REPO_DIR/deploy"
PUBLIC_HOST="${PUBLIC_HOST:-phomymo.parnes.com}"
DOCUMENT_ROOT="${DOCUMENT_ROOT:-/local/1/httpd/$PUBLIC_HOST}"
SITE_FILE="${SITE_FILE:-/etc/apache2/sites-available/$PUBLIC_HOST.conf}"
SNIPPET_FILE="${SNIPPET_FILE:-/etc/apache2/pho.conf}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ALLOW_INDEX="${ALLOW_INDEX:-0}"
# Address in <VirtualHost ADDR:port>. "auto" uses the IP the other vhosts are bound to
# (on nuc they are written <VirtualHost www.parnes.com:443>, which resolves to 192.168.2.80).
# Apache always prefers vhosts bound to an IP over *:port ones, so a *:443 vhost would never
# be chosen there.
VHOST_ADDR="${VHOST_ADDR:-auto}"
CHECK_ONLY=false
ROLLBACK=false
SKIP_APACHE=false

usage() {
  cat <<'USAGE'
Publicerar Pho (Phomymo) på Apache.

Användning:
  sudo ./deploy/install.sh [--check] [--rollback] [--skip-apache]

  --check        kontrollera förutsättningarna, ändra ingenting
  --rollback     byt tillbaka till föregående publicerade version
  --skip-apache  publicera bara filerna, rör inte Apache-konfigurationen

Standardvärden:
  publik adress  https://phomymo.parnes.com
  DocumentRoot   /local/1/httpd/phomymo.parnes.com
  vhost (port 80) /etc/apache2/sites-available/phomymo.parnes.com.conf
  HTTPS-vhost    skapas av certbot första gången (…-le-ssl.conf)

Alla värden kan ändras med miljövariablerna högst upp i skriptet, till exempel
  sudo CERTBOT_EMAIL=du@example.com ./deploy/install.sh
USAGE
}

while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=true ;;
    --rollback) ROLLBACK=true ;;
    --skip-apache) SKIP_APACHE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Okänt argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

die() { echo "FEL: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "VARNING: $*" >&2; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "Kommandot saknas: $1"; }

PUBLIC_URL="https://$PUBLIC_HOST"
NEW_DIR="$DOCUMENT_ROOT.new"
PREV_DIR="$DOCUMENT_ROOT.prev"
MARKER=".pho-deploy"

# Enabled vhosts that answer for PUBLIC_HOST.
host_vhosts() {
  local f
  for f in /etc/apache2/sites-enabled/*.conf; do
    [[ -e "$f" ]] || continue
    if grep -Eiq "^[[:space:]]*Server(Name|Alias)([[:space:]]+[^[:space:]]+)*[[:space:]]+${PUBLIC_HOST//./\\.}(:[0-9]+)?([[:space:]]|$)" "$f"; then
      readlink -f "$f"
    fi
  done | sort -u
  return 0
}
# The IPv4 address other name-based vhosts are bound to, or * if they use *:port.
detect_vhost_addr() {
  local addr
  addr="$(apache2ctl -S 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:(443|80)$/ { sub(/:[0-9]+$/, "", $1); print $1; exit }')" || true
  echo "${addr:-*}"
}
ssl_vhost_exists() {
  local f
  for f in $(host_vhosts); do grep -Eq '<VirtualHost[^>]*:443' "$f" && return 0; done
  return 1
}

validate() {
  [[ "$PUBLIC_HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "PUBLIC_HOST är inte ett giltigt värdnamn: $PUBLIC_HOST"
  [[ "$DOCUMENT_ROOT" == /* && "$DOCUMENT_ROOT" != "/" && "$DOCUMENT_ROOT" != */ ]] || die "DOCUMENT_ROOT måste vara en absolut sökväg utan avslutande snedstreck."
  # The path is written into Apache config and sed expressions: keep it to plain characters.
  [[ "$DOCUMENT_ROOT" =~ ^(/[A-Za-z0-9._-]+)+$ && "/$DOCUMENT_ROOT/" != */../* && "/$DOCUMENT_ROOT/" != */./* ]] \
    || die "DOCUMENT_ROOT får bara innehålla A-Z, a-z, 0-9, punkt, bindestreck, understreck och snedstreck."
  [[ "$SITE_FILE" =~ ^/etc/apache2/sites-available/[A-Za-z0-9._-]+\.conf$ ]] || die "SITE_FILE måste vara en fil direkt i /etc/apache2/sites-available/ och sluta på .conf."
  [[ "$SNIPPET_FILE" =~ ^/etc/apache2/[A-Za-z0-9._-]+$ ]] || die "SNIPPET_FILE måste vara en fil direkt i /etc/apache2/."
  if ! $SKIP_APACHE && command -v apache2ctl >/dev/null 2>&1 && [[ "$VHOST_ADDR" == auto ]]; then
    VHOST_ADDR="$(detect_vhost_addr)"
  fi
  [[ "$VHOST_ADDR" == "*" || "$VHOST_ADDR" == auto || "$VHOST_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VHOST_ADDR måste vara *, auto eller en IPv4-adress."
  [[ -f "$REPO_DIR/src/web/index.html" ]] || die "Hittar inte Pho i $REPO_DIR (src/web/index.html saknas)."
  [[ -x "$HERE/build.sh" ]] || die "deploy/build.sh saknas eller är inte körbar."
  [[ -d "$(dirname "$DOCUMENT_ROOT")" ]] || die "Katalogen för DocumentRoot saknas: $(dirname "$DOCUMENT_ROOT")"
  # Never replace or delete a directory someone else put there.
  local d
  for d in "$DOCUMENT_ROOT" "$NEW_DIR" "$PREV_DIR"; do
    if [[ -L "$d" ]] || [[ -e "$d" && ! -d "$d" ]]; then
      die "$d är inte en vanlig katalog. Flytta undan den."
    fi
    if [[ -d "$d" && ! -f "$d/$MARKER" && -n "$(ls -A "$d")" ]]; then
      die "$d finns redan och har inte publicerats av detta skript. Flytta undan den eller ange DOCUMENT_ROOT=..."
    fi
  done
  BUILD_USER="$(stat -c %U "$REPO_DIR")"
  need_command runuser
  need_command stat
  need_command curl
  need_command sed
  need_command find
  if ! $SKIP_APACHE; then
    need_command apache2ctl
    need_command a2enmod
    need_command a2ensite
    need_command systemctl
    if ! ssl_vhost_exists; then
      need_command certbot
      if ! getent ahosts "$PUBLIC_HOST" >/dev/null; then
        die "$PUBLIC_HOST går inte att slå upp i DNS. Lägg in A/AAAA-posten mot servern först (certbot behöver den)."
      fi
    fi
  fi
}

verify() {
  local base="$1" body ip=127.0.0.1
  [[ "$VHOST_ADDR" =~ ^[0-9.]+$ ]] && ip="$VHOST_ADDR"
  body="$(curl -fsS --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:$ip" "$base/")" || return 1
  grep -q '<title>Phomymo' <<<"$body" || return 1
  curl -fsS --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:$ip" "$base/printers.json" | head -c 1 | grep -q '[{[]' || return 1
  # The security snippet must be active for this vhost: its headers are present and the deploy
  # marker (a dotfile) is denied.
  curl -fsS -o /dev/null -D - --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:$ip" "$base/" \
    | grep -qi '^X-Content-Type-Options: nosniff' || { echo "säkerhetshuvudena saknas" >&2; return 1; }
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:$ip" "$base/$MARKER")" == 403 ]] \
    || { echo "dolda filer nekas inte" >&2; return 1; }
  curl -fsS --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:$ip" "$base/version.json"
}

if [[ $EUID -ne 0 ]] && ! $CHECK_ONLY; then die "Kör med sudo."; fi
validate

if $CHECK_ONLY; then
  info "Repo:          $REPO_DIR"
  info "Publik adress: $PUBLIC_URL"
  info "DocumentRoot:  $DOCUMENT_ROOT"
  $SKIP_APACHE || info "Vhost-adress:  $VHOST_ADDR"
  if ! $SKIP_APACHE; then
    vhosts="$(host_vhosts)"
    if [[ -n "$vhosts" ]]; then info "Befintliga vhostar för $PUBLIC_HOST:"; while read -r v; do echo "      $v"; done <<<"$vhosts"
      # shellcheck disable=SC2086 # one file per word
      if [[ "$VHOST_ADDR" != "*" ]] && grep -Eq '<VirtualHost \*:(80|443)>' $vhosts; then
        info "Vhostarna använder *:port och flyttas till $VHOST_ADDR vid installationen."
      fi
    else info "Ingen vhost för $PUBLIC_HOST ännu; skapas i $SITE_FILE och certbot hämtar certifikat."
    fi
  fi
  info "Kontrollen gick igenom. Inget har ändrats."
  exit 0
fi

# --- Files -----------------------------------------------------------------------------------
if $ROLLBACK; then
  [[ -f "$PREV_DIR/$MARKER" ]] || die "Det finns ingen föregående version i $PREV_DIR."
  [[ ! -e "$NEW_DIR" ]] || rm -rf "$NEW_DIR"   # validate() checked it is ours
  info "Byter tillbaka till föregående version"
  mv "$DOCUMENT_ROOT" "$NEW_DIR"
  mv "$PREV_DIR" "$DOCUMENT_ROOT"
  mv "$NEW_DIR" "$PREV_DIR"
  info "Publicerad nu: $(cat "$DOCUMENT_ROOT/version.json" 2>/dev/null || echo okänd)"
  exit 0
fi

# The build runs as the checkout owner, not as root: it reads only what that user can read, and
# nothing in the checkout (merged from upstream) can make root read or write other files.
info "Bygger Pho som $BUILD_USER"
build_tmp="$(runuser -u "$BUILD_USER" -- mktemp -d)"
trap 'rm -rf "$build_tmp"' EXIT
runuser -u "$BUILD_USER" -- env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$build_tmp" LANG=C.UTF-8 \
  REPO_DIR="$REPO_DIR" ALLOW_INDEX="$ALLOW_INDEX" "$HERE/build.sh" "$build_tmp/out" "$PUBLIC_URL"
bad="$(find "$build_tmp/out" -mindepth 1 ! -type f ! -type d -print -quit)"
[[ -z "$bad" ]] || die "Bygget innehåller något annat än vanliga filer: $bad"
rm -rf "$NEW_DIR"   # validate() checked it is ours
mkdir -m 755 "$NEW_DIR"
cp -R --no-preserve=all "$build_tmp/out/." "$NEW_DIR/"
touch "$NEW_DIR/$MARKER"
chown -R root:root "$NEW_DIR"
find "$NEW_DIR" -type d -exec chmod 755 {} +
find "$NEW_DIR" -type f -exec chmod 644 {} +

info "Publicerar till $DOCUMENT_ROOT (föregående version sparas i $PREV_DIR)"
if [[ -d "$DOCUMENT_ROOT" ]]; then
  rm -rf "$PREV_DIR"
  mv "$DOCUMENT_ROOT" "$PREV_DIR"
fi
mv "$NEW_DIR" "$DOCUMENT_ROOT"

# --- Apache ----------------------------------------------------------------------------------
if ! $SKIP_APACHE; then
  backup_root="$(mktemp -d /root/pho-apache-backup.XXXXXX)"
  created_site=false
  restore_apache() {
    warn "Apache-konfigurationen godtogs inte; återställer från $backup_root"
    local meta
    for meta in "$backup_root"/*.path; do
      [[ -e "$meta" ]] && cp -a "${meta%.path}" "$(cat "$meta")"
    done
    [[ -f "$backup_root/snippet.absent" ]] && rm -f "$SNIPPET_FILE"
    if $created_site; then a2dissite "$(basename "$SITE_FILE" .conf)" >/dev/null || true; rm -f "$SITE_FILE"; fi
    apache2ctl configtest || true
  }
  backup() {
    local name; name="$(echo "$1" | tr / _)"
    cp -a "$1" "$backup_root/$name"; echo "$1" >"$backup_root/$name.path"
  }

  if [[ -f "$SNIPPET_FILE" ]]; then backup "$SNIPPET_FILE"; else touch "$backup_root/snippet.absent"; fi
  robots_header='Header always set X-Robots-Tag "noindex, nofollow"'
  [[ "$ALLOW_INDEX" == 1 ]] && robots_header='# Indexing allowed (ALLOW_INDEX=1).'
  sed -e "s#@TARGET@#$DOCUMENT_ROOT#g" -e "s#@ROBOTS_HEADER@#$robots_header#" "$HERE/apache.conf" >"$SNIPPET_FILE"
  chmod 644 "$SNIPPET_FILE"

  apache2ctl -M 2>/dev/null | grep -q 'headers_module' || { info "Aktiverar mod_headers"; a2enmod headers >/dev/null; }

  include_line="Include $SNIPPET_FILE"
  if [[ -z "$(host_vhosts)" ]]; then
    info "Skapar vhost $SITE_FILE"
    cat >"$SITE_FILE" <<EOF
# Pho (Phomymo). Written by deploy/install.sh. certbot adds the HTTPS copy
# ($(basename "${SITE_FILE%.conf}")-le-ssl.conf) and the redirect from http.
<VirtualHost $VHOST_ADDR:80>
    ServerName $PUBLIC_HOST
    DocumentRoot $DOCUMENT_ROOT
    $include_line
    ErrorLog \${APACHE_LOG_DIR}/$PUBLIC_HOST-error.log
    CustomLog \${APACHE_LOG_DIR}/$PUBLIC_HOST-access.log combined
</VirtualHost>
EOF
    created_site=true
    a2ensite "$(basename "$SITE_FILE" .conf)" >/dev/null
  fi

  # Every vhost for the host includes the snippet (also ones made earlier by hand) and is bound
  # to the same address as the server's other vhosts.
  for f in $(host_vhosts); do
    # Edits below work on the whole file, so the file must hold only this site's vhost.
    if (( $(grep -Eic '^[[:space:]]*<VirtualHost[[:space:]]' "$f") != 1 )); then
      restore_apache
      die "$f innehåller flera <VirtualHost>-block. Lägg vhosten för $PUBLIC_HOST i en egen fil."
    fi
    if ! grep -Eq "^[[:space:]]*Include[[:space:]]+${SNIPPET_FILE//./\\.}[[:space:]]*$" "$f"; then
      info "Lägger till '$include_line' i $f"
      [[ -e "$backup_root/$(echo "$f" | tr / _)" ]] || backup "$f"
      sed -i "0,/<\/VirtualHost>/s##    $include_line\n</VirtualHost>#" "$f"
    fi
    if [[ "$VHOST_ADDR" != "*" ]] && grep -Eq '<VirtualHost \*:(80|443)>' "$f"; then
      info "Binder vhosten i $f till $VHOST_ADDR (som serverns övriga vhostar)"
      [[ -e "$backup_root/$(echo "$f" | tr / _)" ]] || backup "$f"
      sed -Ei "s#<VirtualHost \*:(80|443)>#<VirtualHost $VHOST_ADDR:\1>#" "$f"
    fi
  done

  if ! apache2ctl configtest; then restore_apache; die "apache2ctl configtest misslyckades."; fi
  systemctl reload apache2

  if ! ssl_vhost_exists; then
    info "Hämtar certifikat för $PUBLIC_HOST med certbot"
    certbot_args=(--apache -d "$PUBLIC_HOST" --redirect --non-interactive --agree-tos)
    [[ -n "$CERTBOT_EMAIL" ]] && certbot_args+=(-m "$CERTBOT_EMAIL")
    certbot "${certbot_args[@]}" || die "certbot misslyckades. Sajten finns på http; kör skriptet igen när felet är åtgärdat."
    ssl_vhost_exists || die "certbot skapade ingen HTTPS-vhost för $PUBLIC_HOST."
  fi
  rm -rf "$backup_root"
fi

# --- Check -----------------------------------------------------------------------------------
info "Kontrollerar $PUBLIC_URL"
if version="$(verify "$PUBLIC_URL")"; then
  info "Klart. Publicerad version: $version"
  info "Öppna $PUBLIC_URL i Chrome eller Edge. Återställ med: sudo ./deploy/install.sh --rollback"
else
  warn "Sidan svarade inte som väntat via https://$PUBLIC_HOST (kontrollerat mot $( [[ "$VHOST_ADDR" =~ ^[0-9.]+$ ]] && echo "$VHOST_ADDR" || echo 127.0.0.1)). Se 'sudo apache2ctl -S'."
  warn "Filerna är publicerade; kontrollera Apache-loggarna. Föregående version: sudo ./deploy/install.sh --rollback"
  exit 1
fi
