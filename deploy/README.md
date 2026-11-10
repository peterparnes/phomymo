# Driftsättning på phomymo.parnes.com

Pho är en statisk webbapp. Allt körs i webbläsaren: utskrift via Web Bluetooth/WebUSB direkt från klientens dator eller telefon, och design sparas i webbläsarens localStorage. Servern lämnar bara ut filerna i `src/web/`. Ingen Node-tjänst, databas eller backup behövs.

Web Bluetooth och WebUSB kräver HTTPS, så sajten måste ligga på en TLS-vhost. Fungerar i Chrome/Edge (även Android), inte i Firefox, Safari eller på iOS.

## Förutsättningar

- DNS: `phomymo.parnes.com` pekar på servern (A/AAAA). Certbot behöver det första gången.
- Apache 2 med `certbot` och dess Apache-plugin, som för LB3.
- Repot utcheckat i `/home/parnes/work/phomymo`.

## Första installationen

```bash
cd /home/parnes/work
git clone https://github.com/peterparnes/phomymo.git
cd phomymo
./deploy/install.sh --check
sudo ./deploy/install.sh
```

Första gången gör skriptet följande:

1. Bygger en kopia av `src/web` (`deploy/build.sh`) och publicerar den i `/local/1/httpd/phomymo.parnes.com`.
2. Skriver `/etc/apache2/pho.conf` från `deploy/apache.conf` (cache- och säkerhetshuvuden, nekar dolda filer) och aktiverar `mod_headers` vid behov.
3. Skapar `/etc/apache2/sites-available/phomymo.parnes.com.conf` (port 80) och aktiverar den. Det görs bara om ingen aktiv vhost redan svarar för namnet.
4. Kör `apache2ctl configtest`. Om testet misslyckas återställs ändrade filer. Annars laddas Apache om.
5. Kör `certbot --apache -d phomymo.parnes.com --redirect`, som skapar `phomymo.parnes.com-le-ssl.conf` och omdirigerar http till https. Ange `CERTBOT_EMAIL=...` om certbot inte redan har ett konto på servern.
6. Hämtar `https://phomymo.parnes.com/`, `printers.json` och `version.json` lokalt och skriver ut vilken commit som är publicerad.

Om det redan finns en vhost för namnet lägger skriptet bara till `Include /etc/apache2/pho.conf` i den.

På nuc är alla vhostar bundna till en IP-adress (`<VirtualHost www.parnes.com:443>` slås upp till 192.168.2.80). Apache väljer alltid en sådan vhost före en `*:443`-vhost, så skriptet läser adressen från `apache2ctl -S` och binder Pho:s vhostar till samma adress. Det gäller även vhostar som tidigare skapats med `*`. Slutkontrollen görs mot samma adress och kontrollerar certifikatet.

## Uppdatera

```bash
cd /home/parnes/work/phomymo
git pull
sudo ./deploy/install.sh
```

Den föregående versionen sparas i `/local/1/httpd/phomymo.parnes.com.prev`. Byt tillbaka med:

```bash
sudo ./deploy/install.sh --rollback
```

`https://phomymo.parnes.com/version.json` visar vilken commit som är publicerad.

## Ändringar i den publicerade kopian

Källfilerna i `src/web` lämnas som upstream skrev dem, så att det är lätt att ta in nya versioner. `deploy/build.sh` gör följande ändringar i kopian:

- Kanoniska adresser och Open Graph-adresser pekar på `https://phomymo.parnes.com` i stället för `phomymo.affordablemagic.net`.
- Sökmotorer ombeds att inte indexera sajten (`robots.txt`, metataggen och `X-Robots-Tag`). Kör med `ALLOW_INDEX=1` om sajten ska kunna indexeras.
- Cloudflare-filen `_headers` tas bort. Apache sätter huvudena i stället. HTML, JS och JSON skickas med `Cache-Control: no-cache` eftersom bara några av modulerna har `?v=`-versioner. Webbläsaren frågar därför servern vid varje laddning och får aldrig en blandning av gamla och nya moduler.

Inspektera vad som publiceras utan root:

```bash
./deploy/build.sh /tmp/pho-test
```

Tailwind, typsnitt, JsBarcode, QRCode, jsPDF och pdf.js hämtas från CDN (cdn.tailwindcss.com, Google Fonts, jsDelivr, cdnjs) av klientens webbläsare, precis som i upstream. Därför sätts ingen Content-Security-Policy. Den skulle behöva tillåta inline-skript och de CDN:erna och skulle skydda lite.

## Ta in nya versioner från upstream

```bash
git remote add upstream https://github.com/transcriptionstream/phomymo.git   # en gång
git fetch upstream
git merge upstream/master
git push
```

Driftfilerna ligger bara i `deploy/` och krockar inte med upstream.

## Inställningar

Alla standardvärden finns högst upp i `deploy/install.sh` och kan ändras med miljövariabler, till exempel `sudo PUBLIC_HOST=pho.example.com ./deploy/install.sh`:

| Variabel | Standard |
|---|---|
| `PUBLIC_HOST` | `phomymo.parnes.com` |
| `DOCUMENT_ROOT` | `/local/1/httpd/$PUBLIC_HOST` |
| `SITE_FILE` | `/etc/apache2/sites-available/$PUBLIC_HOST.conf` |
| `SNIPPET_FILE` | `/etc/apache2/pho.conf` |
| `CERTBOT_EMAIL` | tomt (certbot använder sitt befintliga konto) |
| `ALLOW_INDEX` | `0` |
| `VHOST_ADDR` | `auto`: samma IP-adress som serverns övriga vhostar (192.168.2.80 på nuc), annars `*` |

Skriptet vägrar skriva över en DocumentRoot som det inte själv har publicerat. Det känner igen sina egna kataloger på filen `.pho-deploy`.

Sajten är öppen för alla som har adressen. Den innehåller inga data, men om den ska vara privat kan du lägga till Basic Auth i `/etc/apache2/pho.conf` och i `deploy/apache.conf`, så att det följer med vid nästa installation.
