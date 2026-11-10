#!/usr/bin/env bash
# Builds a deployable copy of Pho (src/web) into OUT_DIR. Needs no root and changes nothing
# outside OUT_DIR, so it can be run anywhere to inspect exactly what install.sh publishes.
#
#   ./deploy/build.sh OUT_DIR [PUBLIC_URL]
#
# The source files stay as upstream wrote them (easier merges from transcriptionstream/phomymo);
# site-specific changes are made to the copy:
#   - canonical/Open Graph URLs point at PUBLIC_URL instead of phomymo.affordablemagic.net
#   - search engines are asked not to index the site (set ALLOW_INDEX=1 to allow)
#   - Cloudflare's _headers file is dropped (Apache sets the headers)
#   - version.json records the deployed commit
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$HERE")}"
OUT_DIR="${1:-}"
PUBLIC_URL="${2:-${PUBLIC_URL:-https://phomymo.parnes.com}}"
ALLOW_INDEX="${ALLOW_INDEX:-0}"
UPSTREAM_URL="https://phomymo.affordablemagic.net"

die() { echo "FEL: $*" >&2; exit 1; }
[[ -n "$OUT_DIR" ]] || die "Användning: $0 OUT_DIR [PUBLIC_URL]"
[[ "$PUBLIC_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "PUBLIC_URL måste vara https://värd utan avslutande snedstreck."
SRC="$REPO_DIR/src/web"
for f in index.html app.js printer.js printers.json; do
  [[ -f "$SRC/$f" ]] || die "Filen saknas: $SRC/$f"
done
[[ ! -e "$OUT_DIR" ]] || [[ -z "$(ls -A "$OUT_DIR")" ]] || die "$OUT_DIR finns redan och är inte tom."

mkdir -p "$OUT_DIR"
cp -a "$SRC/." "$OUT_DIR/"
rm -f "$OUT_DIR/_headers"
# og:image points at /screenshot.png; upstream keeps it outside src/web.
[[ -f "$REPO_DIR/screenshot.png" ]] && cp "$REPO_DIR/screenshot.png" "$OUT_DIR/screenshot.png"

for f in "$OUT_DIR/index.html" "$OUT_DIR/docs/manual.html"; do
  [[ -f "$f" ]] && sed -i "s#${UPSTREAM_URL}#${PUBLIC_URL}#g" "$f"
done

if [[ "$ALLOW_INDEX" == 1 ]]; then
  printf 'User-agent: *\nAllow: /\n' >"$OUT_DIR/robots.txt"
else
  sed -i 's#<meta name="robots" content="index, follow">#<meta name="robots" content="noindex, nofollow">#' "$OUT_DIR/index.html"
  printf 'User-agent: *\nDisallow: /\n' >"$OUT_DIR/robots.txt"
fi

commit="$(git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty=false
if [[ "$commit" != unknown ]] && [[ -n "$(git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" status --porcelain -- src/web 2>/dev/null)" ]]; then
  dirty=true
fi
printf '{"commit":"%s","dirty":%s,"built":"%s"}\n' "$commit" "$dirty" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$OUT_DIR/version.json"

# Readable by Apache regardless of the builder's umask.
find "$OUT_DIR" -type d -exec chmod 755 {} +
find "$OUT_DIR" -type f -exec chmod 644 {} +
echo "Byggt $commit$($dirty && echo ' (med ändringar som inte är incheckade)') till $OUT_DIR för $PUBLIC_URL"
