# Claude-Bridge: Uhr → Claude Code auf dem eigenen Server

Damit beantwortet **Claude Code auf deinem Server** die Fragen von der Uhr – mit deinem Claude-Abo und deinen **claude.ai-Konnektoren**, ohne API-Key.

```
Uhr ──BT-Anruf──▶ iPhone (Offline-Diktat) ──WireGuard──▶ Bridge (192.168.0.5:18650) ──▶ claude -p ──▶ Konnektoren
```

In der App läuft das über den Anbieter **„Hermes Call“**. Benutzt Claude ein Werkzeug, sagt die Uhr „I'm using a tool“.

> Nur für dich persönlich: ein Server, ein Claude-Konto, eine Person.

Die Anleitung passt zur Runner-VM `claude-runner-mini-pc` (Ubuntu, 192.168.0.5, WireGuard-Netz 10.0.0.0/24). Für andere Server IP und Netz anpassen.

## Warum ein eigener Benutzer

Der Self-hosted-Runner (`claude-runner`) meldet sich nur mit dem **Environment-Secret** an; die Konnektoren bekommen seine Sessions von der Cloud. Für `claude -p` braucht es dagegen ein **echtes claude.ai-Login**. Das kommt in einen **eigenen Benutzer `claude-watch`**, nicht in `claude-runner`: Sessions auf dem Runner laufen als `claude-runner` und könnten sonst die Anmeldedaten lesen.

## 1. Benutzer und Claude Code (als `smokerdoker`)

```bash
sudo adduser --disabled-password --gecos "" claude-watch
sudo chmod 750 /home/claude-watch
sudo -iu claude-watch bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
sudo -iu claude-watch /home/claude-watch/.local/bin/claude
```

Im letzten Schritt mit deinem **claude.ai-Konto** anmelden (Claude Code zeigt eine URL, im Browser öffnen, Code zurück ins Terminal), dann `/mcp` prüfen (claude.ai-Konnektoren sichtbar?) und `/exit`.

Test (voller Pfad, `~` würde auf dein eigenes Home zeigen):

```bash
sudo -iu claude-watch /home/claude-watch/.local/bin/claude -p "Welche Termine habe ich morgen?"
```

## 2. Bridge installieren

Im geklonten Repo:

```bash
sudo install -d -o claude-watch -g claude-watch -m 700 \
  /home/claude-watch/.local/share/claude-watch-bridge /home/claude-watch/.config/claude-watch-bridge
sudo install -o claude-watch -g claude-watch -m 700 tools/claude-bridge/bridge.py /home/claude-watch/.local/share/claude-watch-bridge/
sudo -u claude-watch sh -c 'umask 077; python3 -c "import secrets; print(secrets.token_urlsafe(32))" > /home/claude-watch/.config/claude-watch-bridge/key'
sudo install -m 644 tools/claude-bridge/claude-watch-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now claude-watch-bridge
sudo ufw allow from 10.0.0.0/24 to any port 18650 proto tcp comment 'watch bridge (WireGuard)'
curl -s http://192.168.0.5:18650/health     # → {"ok": true}
```

Schlüssel für die App: `sudo cat /home/claude-watch/.config/claude-watch-bridge/key`

Logs: `journalctl -u claude-watch-bridge -f`

## 3. iPhone-App

WireGuard auf dem iPhone verbinden. Dann **Features → Hermes**:
- *Hermes server URL*: `http://192.168.0.5:18650` (unverschlüsseltes http erlaubt die App nur zu privaten IPs; WireGuard verschlüsselt)
- *Hermes API key*: der Schlüssel aus Schritt 2 (bleibt im Schlüsselbund)
- Testnachricht → *Send to Hermes*. Fragt iOS nach „Lokales Netzwerk“: erlauben.

**Features → Voice Providers**: **Hermes Call** mit Stern markieren. Auf der Uhr: Voice → Hermes → Anruf annehmen → sprechen.

## Sicherheit

- Claude hat hier **keine Shell und keinen Dateizugriff** (`CLAUDE_DISALLOWED`), nur Konnektoren, MCP-Server und Websuche: E-Mails oder Termine können versteckte Anweisungen enthalten.
- Claude soll vor Senden/Löschen/Ändern nachfragen (System-Prompt).
- Port 18650 nur aus dem WireGuard-Netz. Wer den Schlüssel hat, kann über dein Claude-Konto fragen: geheim halten, bei Verdacht neu erzeugen und `sudo systemctl restart claude-watch-bridge`.
- Der Runner schafft eine Session gleichzeitig, die Bridge ist davon unabhängig. RAM: Bridge auf 1,2 GB begrenzt (VM hat 4 GB, Runner bis 2,6 GB).

## Einstellungen

Als `Environment=…` in der Service-Datei: `CLAUDE_MODEL` (z. B. `sonnet`, `haiku`), `CLAUDE_TIMEOUT` (Standard 110 s), `CLAUDE_DISALLOWED`, `BRIDGE_HOST`, `BRIDGE_PORT`.
