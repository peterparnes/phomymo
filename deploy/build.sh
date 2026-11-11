#!/usr/bin/env bash
# Builds a deployable copy of Pho into OUT_DIR. Needs no root and changes nothing outside
# OUT_DIR, so it can be run anywhere to inspect exactly what install.sh publishes.
#
#   ./deploy/build.sh OUT_DIR [PUBLIC_URL]
#
# Only files committed in HEAD are published (git archive), never the working tree: untracked,
# ignored or uncommitted files in the checkout do not reach the web server.
#
# The source files stay as upstream wrote them (easier merges from transcriptionstream/phomymo);
# site-specific changes are made to the copy:
#   - canonical/Open Graph URLs point at PUBLIC_URL instead of phomymo.affordablemagic.net
#   - search engines are asked not to index the site (set ALLOW_INDEX=1 to allow)
#   - Cloudflare's _headers file is dropped (Apache sets the headers)
#   - version.json records the deployed commit
#
# Content merged from upstream is not trusted to be harmless: the build refuses symlinks,
# hidden files and file types a web server could execute (.php, .shtml, .cgi, ...).
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$HERE")}"
OUT_DIR="${1:-}"
PUBLIC_URL="${2:-${PUBLIC_URL:-https://phomymo.parnes.com}}"
ALLOW_INDEX="${ALLOW_INDEX:-0}"
UPSTREAM_URL="https://phomymo.affordablemagic.net"
# File types that are served as static content. Anything else in src/web stops the build.
ALLOWED_EXT='html|htm|js|mjs|json|css|png|jpg|jpeg|gif|svg|webp|ico|woff|woff2|txt|map'

die() { echo "FEL: $*" >&2; exit 1; }
# Never let repository config (hooks, fsmonitor) run commands during the build.
git_repo() { git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$REPO_DIR" "$@"; }

[[ -n "$OUT_DIR" ]] || die "Användning: $0 OUT_DIR [PUBLIC_URL]"
[[ "$PUBLIC_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "PUBLIC_URL måste vara https://värd utan avslutande snedstreck."
command -v git >/dev/null || die "git saknas."
command -v tar >/dev/null || die "tar saknas."
[[ -d "$REPO_DIR/.git" ]] || die "$REPO_DIR är ingen git-checkout."
if [[ $EUID -eq 0 && "$(stat -c %u "$REPO_DIR")" != 0 ]]; then
  die "Kör inte build.sh som root mot en checkout som ägs av en annan användare (install.sh kör den som ägaren)."
fi
[[ ! -e "$OUT_DIR" ]] || [[ -z "$(ls -A "$OUT_DIR")" ]] || die "$OUT_DIR finns redan och är inte tom."

commit="$(git_repo rev-parse --short HEAD 2>/dev/null)" || die "Kunde inte läsa HEAD i $REPO_DIR."

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
paths=(src/web)
git_repo cat-file -e HEAD:screenshot.png 2>/dev/null && paths+=(screenshot.png)
git_repo archive --format=tar HEAD -- "${paths[@]}" | tar -x --no-same-owner -C "$stage"

# Check everything before writing anything to OUT_DIR.
bad="$(find "$stage" -mindepth 1 ! -type f ! -type d -print -quit)"
[[ -z "$bad" ]] || die "Symlänk eller specialfil i commit $commit: ${bad#"$stage"/}"
bad="$(find "$stage" -mindepth 1 -name '.*' -print -quit)"
[[ -z "$bad" ]] || die "Dold fil eller katalog i commit $commit: ${bad#"$stage"/}"
bad="$(find "$stage/src/web" -type f ! -name _headers -print | grep -Eiv "\.($ALLOWED_EXT)\$" | head -n 1 || true)"
[[ -z "$bad" ]] || die "Filtyp som inte publiceras statiskt i commit $commit: ${bad#"$stage"/}"
for f in index.html app.js printer.js printers.json; do
  [[ -f "$stage/src/web/$f" ]] || die "Filen saknas i commit $commit: src/web/$f"
done

mkdir -p "$OUT_DIR"
cp -R "$stage/src/web/." "$OUT_DIR/"
rm -f "$OUT_DIR/_headers"
# og:image points at /screenshot.png; upstream keeps it outside src/web.
[[ -f "$stage/screenshot.png" ]] && cp "$stage/screenshot.png" "$OUT_DIR/screenshot.png"

for f in "$OUT_DIR/index.html" "$OUT_DIR/docs/manual.html"; do
  [[ -f "$f" ]] && sed -i "s#${UPSTREAM_URL}#${PUBLIC_URL}#g" "$f"
done

if [[ "$ALLOW_INDEX" == 1 ]]; then
  printf 'User-agent: *\nAllow: /\n' >"$OUT_DIR/robots.txt"
else
  sed -i 's#<meta name="robots" content="index, follow">#<meta name="robots" content="noindex, nofollow">#' "$OUT_DIR/index.html"
  printf 'User-agent: *\nDisallow: /\n' >"$OUT_DIR/robots.txt"
fi

# "dirty" only informs: uncommitted changes in src/web are not part of the build.
dirty=false
[[ -n "$(git_repo status --porcelain -- src/web 2>/dev/null)" ]] && dirty=true
printf '{"commit":"%s","dirty":%s,"built":"%s"}\n' "$commit" "$dirty" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$OUT_DIR/version.json"

# Readable by Apache regardless of the builder's umask.
find "$OUT_DIR" -type d -exec chmod 755 {} +
find "$OUT_DIR" -type f -exec chmod 644 {} +
echo "Byggt $commit till $OUT_DIR för $PUBLIC_URL"
$dirty && echo "OBS: src/web har ändringar som inte är incheckade; de publiceras inte."
exit 0
