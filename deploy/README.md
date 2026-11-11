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

1. Bygger en kopia av `src/web` (`deploy/build.sh`) som checkoutens ägare, inte som root, och publicerar den i `/local/1/httpd/phomymo.parnes.com`. Bara filer som är incheckade i `HEAD` kommer med (se nedan).
2. Skriver `/etc/apache2/pho.conf` från `deploy/apache.conf` och aktiverar `mod_headers` vid behov. Snippeten sätter cache- och säkerhetshuvuden, nekar dolda filer och kataloger, serverar bara statiska filtyper och stänger av PHP, SSI, CGI och symlänkar i webbroten, även om servern har dem påslagna för andra sajter.
3. Skapar `/etc/apache2/sites-available/phomymo.parnes.com.conf` (port 80) och aktiverar den. Det görs bara om ingen aktiv vhost redan svarar för namnet.
4. Kör `apache2ctl configtest`. Om testet misslyckas återställs ändrade filer. Annars laddas Apache om.
5. Kör `certbot --apache -d phomymo.parnes.com --redirect`, som skapar `phomymo.parnes.com-le-ssl.conf` och omdirigerar http till https. Ange `CERTBOT_EMAIL=...` om certbot inte redan har ett konto på servern.
6. Hämtar `https://phomymo.parnes.com/`, `printers.json` och `version.json` lokalt, kontrollerar att säkerhetshuvudena finns och att dolda filer nekas, och skriver ut vilken commit som är publicerad.

Om det redan finns en vhost för namnet lägger skriptet bara till `Include /etc/apache2/pho.conf` i den. Vhosten måste ligga i en egen fil; skriptet vägrar ändra en fil med flera `<VirtualHost>`-block.

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

Bygget tar filerna från den incheckade versionen (`git archive HEAD`), aldrig från arbetskopian. Ospårade, ignorerade eller ej incheckade filer i checkouten hamnar alltså inte på webben; `version.json` visar `"dirty": true` om det fanns sådana ändringar i `src/web`. Bygget avbryts om commiten innehåller symlänkar, dolda filer eller kataloger, eller filtyper som inte är statiska (till exempel `.php`, `.shtml`, `.cgi`).

Källfilerna i `src/web` lämnas som upstream skrev dem, så att det är lätt att ta in nya versioner. `deploy/build.sh` gör följande ändringar i kopian:

- Kanoniska adresser och Open Graph-adresser pekar på `https://phomymo.parnes.com` i stället för `phomymo.affordablemagic.net`.
- Sökmotorer ombeds att inte indexera sajten (`robots.txt`, metataggen och `X-Robots-Tag`). Kör med `ALLOW_INDEX=1` om sajten ska kunna indexeras.
- Cloudflare-filen `_headers` tas bort. Apache sätter huvudena i stället. HTML, JS och JSON skickas med `Cache-Control: no-cache` eftersom bara några av modulerna har `?v=`-versioner. Webbläsaren frågar därför servern vid varje laddning och får aldrig en blandning av gamla och nya moduler.

Inspektera vad som publiceras utan root:

```bash
./deploy/build.sh ~/pho-test
```

Tailwind, typsnitt, JsBarcode, QRCode, jsPDF och pdf.js hämtas från CDN (cdn.tailwindcss.com, Google Fonts, jsDelivr, cdnjs) av klientens webbläsare, precis som i upstream. Det finns ännu ingen Content-Security-Policy: den behöver provas mot de riktiga CDN-biblioteken (särskilt Tailwinds körtidsmotor) innan den slås på, eftersom en felaktig policy gör sajten obrukbar.

## Ta in nya versioner från upstream

```bash
git remote add upstream https://github.com/transcriptionstream/phomymo.git   # en gång
git fetch upstream
git merge upstream/master
git push
```

Driftfilerna ligger bara i `deploy/` och krockar inte med upstream.

Granska vad som kommer in innan du mergar, särskilt filer som blivit symlänkar eller nya filtyper:

```bash
git diff --summary HEAD upstream/master
git diff --stat HEAD upstream/master
```

Rader med `mode 120000` är symlänkar. Bygget vägrar sådana, men det är bättre att upptäcka dem före mergen.

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
