# Claude-Bridge: Uhr → Claude Code auf deinem Server

Damit beantwortet **Claude Code auf deinem Ubuntu-Server** die Fragen von der Uhr – mit deinem Claude-Abo und deinen **claude.ai-Konnektoren** (Kalender, Gmail, …), ohne API-Key.

```
Uhr ──Bluetooth-Anruf──▶ iPhone (Spracherkennung) ──HTTPS──▶ Bridge ──▶ claude -p ──▶ Konnektoren
```

In der App läuft das über den Anbieter **„Hermes Call“** (OpenAI-kompatibles Format). Benutzt Claude ein Werkzeug, sagt die Uhr „I'm using a tool“.

> Nur für dich persönlich: ein Server, ein Claude-Konto, eine Person. Die Bridge nicht mit anderen teilen.

## 1. Claude Code auf dem Server

Als normaler Benutzer (nicht root):

```bash
claude --version          # ist Claude Code installiert?
claude                    # einmal interaktiv starten, mit deinem Claude-Team-Konto anmelden, dann /exit
claude mcp list           # zeigt die verfügbaren Konnektoren/MCP-Server
claude -p "Welche Termine habe ich morgen?"   # Test: sollte deinen Kalender nutzen
```

Fehlen Konnektoren: in Claude Code `/mcp` öffnen und prüfen, ob die claude.ai-Konnektoren aktiviert sind.

## 2. Bridge installieren

Im geklonten Repo auf dem Server:

```bash
install -d -m 700 ~/.local/share/claude-watch-bridge ~/.config/claude-watch-bridge ~/.config/systemd/user
install -m 700 tools/claude-bridge/bridge.py ~/.local/share/claude-watch-bridge/
install -m 644 tools/claude-bridge/claude-watch-bridge.service ~/.config/systemd/user/
python3 -c "import secrets; print(secrets.token_urlsafe(32))" > ~/.config/claude-watch-bridge/key
chmod 600 ~/.config/claude-watch-bridge/key
systemctl --user daemon-reload
systemctl --user enable --now claude-watch-bridge
loginctl enable-linger "$USER"     # läuft auch ohne angemeldete Sitzung weiter
curl -s http://127.0.0.1:18650/health   # → {"ok": true}
```

Schlüssel anzeigen (brauchst du gleich in der App): `cat ~/.config/claude-watch-bridge/key`

Logs: `journalctl --user -u claude-watch-bridge -f`

## 3. HTTPS mit Tailscale (empfohlen)

Die App spricht nur HTTPS. Mit [Tailscale](https://tailscale.com) bleibt die Bridge privat – nur deine Geräte erreichen sie:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo tailscale serve --bg --https=443 http://127.0.0.1:18650
tailscale serve status       # zeigt die Adresse, z. B. https://ubuntu.tailXXXX.ts.net
```

(Falls `serve` HTTPS-Zertifikate verlangt: in der Tailscale-Admin-Konsole unter *DNS* „HTTPS Certificates“ aktivieren.)

Auf dem iPhone die **Tailscale-App** installieren, mit demselben Konto anmelden, VPN an lassen.

## 4. In der iPhone-App

**Features → Hermes**
- *Hermes server URL*: deine `https://….ts.net`-Adresse
- *Hermes API key*: der Schlüssel aus Schritt 2 (wird im Schlüsselbund gespeichert)
- Testnachricht tippen → *Send to Hermes*

**Features → Voice Providers**: **Hermes Call** mit Stern markieren. Auf der Uhr: Voice → Hermes → Anruf annehmen → sprechen.

## Sicherheit

- Standardmäßig hat Claude auf dem Server **keine Shell und keinen Dateizugriff** (`CLAUDE_DISALLOWED`), nur Konnektoren, MCP-Server und Websuche. Grund: E-Mails oder Termine können versteckte Anweisungen enthalten.
- Claude soll vor dem Senden/Löschen/Ändern nachfragen (steht im System-Prompt). Für sensible Konnektoren trotzdem überlegen, ob Schreibrechte nötig sind.
- Wer den Schlüssel hat, kann über dein Claude-Konto fragen – Schlüssel geheim halten, bei Verdacht neu erzeugen und `systemctl --user restart claude-watch-bridge`.

## Einstellungen

In der Service-Datei als `Environment=…`: `CLAUDE_MODEL` (z. B. `sonnet`, `haiku`), `CLAUDE_TIMEOUT` (Standard 110 s), `CLAUDE_DISALLOWED`, `BRIDGE_PORT`.
