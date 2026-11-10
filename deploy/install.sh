#!/usr/bin/env bash
# Publishes Pho (Phomymo) on Apache at https://phomymo.parnes.com.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$HERE")}"
PUBLIC_HOST="${PUBLIC_HOST:-phomymo.parnes.com}"
DOCUMENT_ROOT="${DOCUMENT_ROOT:-/local/1/httpd/$PUBLIC_HOST}"
SITE_FILE="${SITE_FILE:-/etc/apache2/sites-available/$PUBLIC_HOST.conf}"
SNIPPET_FILE="${SNIPPET_FILE:-/etc/apache2/pho.conf}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ALLOW_INDEX="${ALLOW_INDEX:-0}"
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
ssl_vhost_exists() {
  local f
  for f in $(host_vhosts); do grep -Eq '<VirtualHost[^>]*:443' "$f" && return 0; done
  return 1
}

validate() {
  [[ "$PUBLIC_HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "PUBLIC_HOST är inte ett giltigt värdnamn: $PUBLIC_HOST"
  [[ "$DOCUMENT_ROOT" == /* && "$DOCUMENT_ROOT" != "/" && "$DOCUMENT_ROOT" != */ ]] || die "DOCUMENT_ROOT måste vara en absolut sökväg utan avslutande snedstreck."
  [[ "$SITE_FILE" == /etc/apache2/sites-available/*.conf ]] || die "SITE_FILE måste ligga i /etc/apache2/sites-available/ och sluta på .conf."
  [[ "$SNIPPET_FILE" == /etc/apache2/* ]] || die "SNIPPET_FILE måste ligga i /etc/apache2/."
  [[ -f "$REPO_DIR/src/web/index.html" ]] || die "Hittar inte Pho i $REPO_DIR (src/web/index.html saknas)."
  [[ -x "$HERE/build.sh" ]] || die "deploy/build.sh saknas eller är inte körbar."
  [[ -d "$(dirname "$DOCUMENT_ROOT")" ]] || die "Katalogen för DocumentRoot saknas: $(dirname "$DOCUMENT_ROOT")"
  # Never replace a directory someone else put there.
  if [[ -d "$DOCUMENT_ROOT" && ! -f "$DOCUMENT_ROOT/$MARKER" && -n "$(ls -A "$DOCUMENT_ROOT")" ]]; then
    die "$DOCUMENT_ROOT finns redan och har inte publicerats av detta skript. Flytta undan den eller ange DOCUMENT_ROOT=..."
  fi
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
  local base="$1" body
  body="$(curl -fsS --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:127.0.0.1" "$base/")" || return 1
  grep -q '<title>Phomymo' <<<"$body" || return 1
  curl -fsS --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:127.0.0.1" "$base/printers.json" | head -c 1 | grep -q '[{[]' || return 1
  curl -fsS --noproxy "*" --max-time 15 --resolve "$PUBLIC_HOST:443:127.0.0.1" "$base/version.json"
}

if [[ $EUID -ne 0 ]] && ! $CHECK_ONLY; then die "Kör med sudo."; fi
validate

if $CHECK_ONLY; then
  info "Repo:          $REPO_DIR"
  info "Publik adress: $PUBLIC_URL"
  info "DocumentRoot:  $DOCUMENT_ROOT"
  if ! $SKIP_APACHE; then
    vhosts="$(host_vhosts)"
    if [[ -n "$vhosts" ]]; then info "Befintliga vhostar för $PUBLIC_HOST:"; while read -r v; do echo "      $v"; done <<<"$vhosts"
    else info "Ingen vhost för $PUBLIC_HOST ännu; skapas i $SITE_FILE och certbot hämtar certifikat."
    fi
  fi
  info "Kontrollen gick igenom. Inget har ändrats."
  exit 0
fi

# --- Files -----------------------------------------------------------------------------------
if $ROLLBACK; then
  [[ -f "$PREV_DIR/$MARKER" ]] || die "Det finns ingen föregående version i $PREV_DIR."
  info "Byter tillbaka till föregående version"
  mv "$DOCUMENT_ROOT" "$NEW_DIR"
  mv "$PREV_DIR" "$DOCUMENT_ROOT"
  mv "$NEW_DIR" "$PREV_DIR"
  info "Publicerad nu: $(cat "$DOCUMENT_ROOT/version.json" 2>/dev/null || echo okänd)"
  exit 0
fi

info "Bygger Pho"
rm -rf "$NEW_DIR"
REPO_DIR="$REPO_DIR" ALLOW_INDEX="$ALLOW_INDEX" "$HERE/build.sh" "$NEW_DIR" "$PUBLIC_URL"
touch "$NEW_DIR/$MARKER"
chown -R root:root "$NEW_DIR"

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
<VirtualHost *:80>
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

  # Every vhost for the host includes the snippet (also ones made earlier by hand).
  for f in $(host_vhosts); do
    grep -Fq "$include_line" "$f" && continue
    info "Lägger till '$include_line' i $f"
    backup "$f"
    sed -i "0,/<\/VirtualHost>/s##    $include_line\n</VirtualHost>#" "$f"
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
  warn "Sidan svarade inte som väntat via https://$PUBLIC_HOST på den här maskinen."
  warn "Filerna är publicerade; kontrollera Apache-loggarna. Föregående version: sudo ./deploy/install.sh --rollback"
  exit 1
fi
