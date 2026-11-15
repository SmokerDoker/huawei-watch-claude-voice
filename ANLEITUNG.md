# Claude auf der Huawei Watch GT 3 Pro – ohne Mac

Fork von [VoiceGPTforHuaweiWatch](https://github.com/eymnyld/VoiceGPTforHuaweiWatch) (AGPL-3.0) mit drei Änderungen:

- **GitHub-Actions-Workflow** (`.github/workflows/build-ios.yml`): baut die iPhone-App auf einem macOS-Runner als unsignierte `.ipa`, optional mit der signierten Watch-App „Voice“.
- **Deutsch:** Die Spracherkennung nutzt die Sprache des iPhones (z. B. `de-DE`) statt fest Englisch. Einstellbar unter *Claude Voice Settings → Dictation language*.
- **Claude antwortet kurz und ohne Markdown**, damit es am Telefon-Lautsprecher der Uhr gut klingt.

So funktioniert es: Du öffnest „Voice“ auf der Uhr, das iPhone ruft die Uhr per Bluetooth an, du nimmst an und sprichst. Das iPhone erkennt die Sprache offline, schickt den Text an die Claude API und liest die Antwort über die Uhr vor.

> ⚠️ Inoffizielles Protokoll: Die App koppelt sich direkt mit der Uhr. Das kann die Verbindung zur Huawei-Health-App stören; im schlimmsten Fall muss die Uhr zurückgesetzt werden. Getestet wurde upstream nur die GT 3 SE.

---

## Schritt 1 – Repo und Bundle-ID

1. Dieses Repo als **öffentliches** Repo in deinem GitHub-Account anlegen. Dann sind die macOS-Runner kostenlos und unbegrenzt.
   Die gebaute App wird nur **verschlüsselt** hochgeladen (7z, AES-256, auch die Dateinamen) und nach einem Tag gelöscht. Deine Schlüssel liegen als Secrets im Repo und sind nicht öffentlich.
2. *Settings → Secrets and variables → Actions → Variables → New variable*
   `BUNDLE_ID` = z. B. `com.smokerdoker.huasideload`
   Die Watch-App heißt dann automatisch `com.smokerdoker.huasideload.voice`.
3. *Settings → Secrets and variables → Actions → Secrets → New secret*
   `ARTIFACT_PASSWORD` = ein langes Passwort (mind. 12 Zeichen, am besten aus dem Passwort-Manager). Damit entpackst du später die App.

## Schritt 2 – iPhone-App ohne Watch-App bauen und installieren

1. *Actions → Build iOS app (unsigned IPA) → Run workflow* (Haken „watch app“ aus lassen).
2. Nach ca. 5–10 Minuten unter dem Lauf das Artefakt **HuaSideload-unsigned-ipa-encrypted** herunterladen (innerhalb von 24 Stunden).
   Die Zip enthält `HuaSideload-unsigned-ipa.7z` → mit [7-Zip](https://www.7-zip.org) und deinem `ARTIFACT_PASSWORD` entpacken → `HuaSideload-unsigned.ipa`.
3. Auf dem Windows-PC [Sideloadly](https://sideloadly.io) installieren, iPhone per Kabel anschließen, die `.ipa` reinziehen, Apple-ID eingeben, **Start**.
   - In den *Advanced Options* darf die Bundle-ID **nicht** geändert werden.
4. Auf dem iPhone: *Einstellungen → Allgemein → VPN & Geräteverwaltung* → deiner Apple-ID vertrauen. Ab iOS 16 zusätzlich *Datenschutz & Sicherheit → Entwicklermodus* einschalten.
5. App öffnen → Uhr koppeln (Huawei Health dafür schließen) → im Tab **Watch** unter *Status* → **Show identity** → **Copy UDID**.

Mit kostenloser Apple-ID läuft die App nach 7 Tagen ab → mit Sideloadly einfach neu installieren (Daten bleiben erhalten).

## Schritt 3 – Signierschlüssel für die Watch-App (einmalig, unter Windows)

Benötigt Java (z. B. [Temurin 17](https://adoptium.net)). In PowerShell, in einem neuen Ordner:

```powershell
keytool -genkeypair -alias mykey -keyalg EC -groupname secp256r1 -sigalg SHA256withECDSA `
  -validity 9125 -storetype PKCS12 -keystore mykey.p12 -storepass DEINPASSWORT -keypass DEINPASSWORT `
  -dname "CN=mykey,OU=Noah,O=Noah,C=DE"
keytool -certreq -alias mykey -keystore mykey.p12 -storepass DEINPASSWORT -sigalg SHA256withECDSA -file mykey.csr
```

Store-Passwort und Key-Passwort müssen gleich sein.

## Schritt 4 – AppGallery Connect

[developer.huawei.com](https://developer.huawei.com) → AppGallery Connect → *Certificates, App ID and Profiles*:

1. **Certificates → New:** Typ *Debug*, `mykey.csr` hochladen → `.cer` herunterladen.
2. **Devices → Add:** Typ *Sports watch (lite wearable)*, UDID aus Schritt 2 einfügen.
3. **My projects → Projekt anlegen → Add app:** HarmonyOS-App, Gerät *Sports watch*, Paketname `<BUNDLE_ID>.voice` (z. B. `com.smokerdoker.huasideload.voice`). Keine Berechtigungen auswählen.
4. **Profiles → Add:** diese App, Typ *Debug*, dein Zertifikat, deine Uhr → `.p7b` herunterladen.

## Schritt 5 – Secrets hinterlegen

In PowerShell die Dateien in Base64 umwandeln (Ergebnis landet in der Zwischenablage):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\mykey.p12")) | Set-Clipboard
```

Unter *Settings → Secrets and variables → Actions → Secrets* anlegen:

| Secret | Inhalt |
|---|---|
| `WATCH_KEYSTORE_P12_BASE64` | Base64 von `mykey.p12` |
| `WATCH_KEY_PASSWORD` | dein Passwort |
| `WATCH_CERT_BASE64` | Base64 der `.cer` |
| `WATCH_PROFILE_BASE64` | Base64 der `.p7b` |

## Schritt 6 – Mit Watch-App bauen und installieren

1. *Run workflow* mit Haken **„Also build and sign the Voice watch app“**.
2. Neue `.ipa` mit Sideloadly installieren (wie Schritt 2).
3. In der App: **Install → Install Voice**.
4. Uhr in den iPhone-Bluetooth-Einstellungen **für Anrufe verbinden** (Uhr antippen).

## Schritt 7 – Claude einrichten

1. API-Key aus der [Claude Console](https://console.anthropic.com) holen (wird nach Verbrauch abgerechnet, getrennt vom claude.ai-Abo).
2. In der App: **Features → Voice Providers → Claude Voice Settings**
   - HTTPS URL: `https://api.anthropic.com/v1/messages` (vorausgefüllt)
   - Model ID: z. B. `claude-haiku-5-5` (schnell, günstig) oder `claude-sonnet-5-5`
   - API key → **Save key** (liegt danach im iOS-Schlüsselbund, nur auf diesem Gerät)
   - Dictation language: leer lassen oder `de-DE`
3. Claude mit Stern als Favorit markieren.
4. Auf dem iPhone die deutsche Offline-Diktierfunktion aktivieren: *Einstellungen → Allgemein → Tastatur → Diktieren* an, Deutsch als Tastatur vorhanden.
5. Auf der Uhr **Voice** öffnen → Claude wählen → Anruf auf der Uhr annehmen → sprechen.

## Weitere Funktionen

- **Antwort und Ja/Nein auf der Uhr:** Im Sprachchat mit Claude erscheint die ganze Antwort auf der Uhr (wischen zum Scrollen). Fragt Claude vor einer Aktion nach, kommen zwei Knöpfe **Ja** / **Nein**; gesprochenes „Ja“ geht auch. Wurde die Uhr-App vom Anrufbildschirm verdrängt: einfach wieder öffnen, die letzte Antwort kommt erneut.
- **Handy suchen:** „Telefon suchen“ auf der Uhr lässt das iPhone klingeln und vibrieren – auch im Lautlos-Modus, nicht aber bei ganz leiser Lautstärke. Stoppt über die Uhr, durch Tippen auf die Mitteilung, beim Öffnen der App oder nach einer Minute. HuaSideload muss im Hintergrund laufen und Mitteilungen erlauben.
- **Apple Health:** Das Artefakt enthält zwei IPAs. `HuaSideload-health.ipa` hat zusätzlich die HealthKit-Berechtigung. Lehnt Sideloadly sie mit der kostenlosen Apple-ID ab, `HuaSideload-unsigned.ipa` nehmen (alles außer Apple Health funktioniert). In der App: Gesundheit → „Export to Apple Health“, optional automatisch nach jedem Sync. Geschrieben werden Schritte, Strecke, aktive Kalorien, Puls, SpO2 und die TruSleep-Nächte (als „Schlaf“, ohne Phasen). Erneutes Exportieren erzeugt keine Duplikate.

## Wenn etwas nicht klappt

- **Workflow: „Set the repository variable BUNDLE_ID“** → Schritt 1.2.
- **Workflow: „Set the secret ARTIFACT_PASSWORD“** → Schritt 1.3.
- **Artefakt weg** → wird nach 24 Stunden gelöscht; Workflow einfach neu starten.
- **Workflow scheitert beim SDK-Download** → Huawei-Mirror langsam/nicht erreichbar, einfach erneut starten.
- **Installation auf der Uhr: Fehler 103** → UDID nicht im Profil, falscher Paketname oder falsches Zertifikat (Schritt 4).
- **„Check microphone access and offline speech recognition“** → Mikrofon/Spracherkennung für die App erlauben, Schritt 7.4.
- **Uhr verliert die Verbindung** → HuaSideload nicht aus dem App-Umschalter wischen.

## Optional: Claude Code auf dem eigenen Server (Konnektoren, kein API-Key)

Statt der Claude API kann die Uhr auch **Claude Code auf deinem eigenen Server** fragen – mit deinem Claude-Abo und deinen claude.ai-Konnektoren. Einrichtung: [`tools/claude-bridge/README.md`](tools/claude-bridge/README.md).
