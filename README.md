# MediaIndexer systemd Service

## Überblick

MediaIndexer wurde für den Betrieb als nativer Linux systemd-Service optimiert. Diese Version ersetzt die alte Cron-basierte Implementierung und bietet:

- **Native systemd-Integration** mit automatischem Neustart
- **Environment-basierte Konfiguration** statt Windows-INI-Dateien
- **Multi-Instance-Support** für verschiedene Verarbeitungstypen
- **Verbesserte Sicherheit** durch Sandboxing
- **Strukturiertes Logging** über systemd journal
- **Ressourcen-Management** und Performance-Optimierung

## Schnellstart

### 1. Installation

```bash
# Als root ausführen
sudo ./systemd/install-systemd.sh
```

### 2. Services starten

```bash
# Filmstrip-Service starten
sudo systemctl start mediaindexer@filmstrip.service
sudo systemctl enable mediaindexer@filmstrip.service

# Status prüfen
sudo systemctl status mediaindexer@filmstrip.service
```

### 3. Logs anzeigen

```bash
# Live-Logs verfolgen
sudo journalctl -fu mediaindexer@filmstrip.service

# Alle Logs anzeigen
sudo journalctl -u mediaindexer@filmstrip.service
```

## Konfiguration

### Environment-Dateien

Die Konfiguration erfolgt über Environment-Dateien in dieser Reihenfolge:

1. **System-Konfiguration**: `/etc/mediaindexer/mediaindexer.env`
2. **Lokale Konfiguration**: `./mediaindexer.env`
3. **Runtime-Override**: `MEDIAINDEXER_CONFIG_FILE` Environment-Variable

### Beispiel-Konfiguration

```bash
# /etc/mediaindexer/mediaindexer.env

# === VERZEICHNISSE ===
MEDIAINDEXER_SOURCE_DIR=/var/lib/mediaindexer/input
MEDIAINDEXER_DESTINATION_DIR=/var/lib/mediaindexer/output
MEDIAINDEXER_TEMP_DIR=/var/lib/mediaindexer/temp

# === VERARBEITUNG ===
MEDIAINDEXER_DISABLE_REMOVAL=0
MEDIAINDEXER_IGNORE_MISSING_FRAMES=0
MEDIAINDEXER_IMG_WIDTH=4096

# === LOGGING ===
MEDIAINDEXER_LOG_LEVEL=info  # debug, info, warn, error
MEDIAINDEXER_LOG_FILE=/var/log/mediaindexer/mediaindexer.log

# === PERFORMANCE ===
MEDIAINDEXER_SLEEP_INTERVAL=10
```

**Hinweis**: Alle Tools (FFmpeg, FFprobe, bmxtranswrap, mxf2raw) werden automatisch über die system-nativen Executables verwendet. Eine separate Pfad-Konfiguration ist nicht mehr erforderlich.

## Service-Instanzen

### Verfügbare Typen

| Instance-Typ | Ausgabe-Format | Beschreibung                        |
| ------------ | -------------- | ----------------------------------- |
| `filmstrip`  | `.jpg`         | Filmstreifen-Generierung aus Videos |
| `waveform`   | `.gif`         | Audio-Waveform-Visualisierung       |
| `r128sum`    | `.r128sum`     | EBU R128 Loudness-Zusammenfassung   |
| `r128log`    | `.r128log`     | Detaillierte EBU R128 Frame-Logs    |
| `xmlinfo`    | `.xml`         | FFprobe-Metadaten als XML           |
| `jsoninfo`   | `.json`        | FFprobe-Metadaten als JSON          |
| `mxfinfo`    | `.xml`         | MXF-spezifische Metadaten           |

### Service-Management

```bash
# Alle verfügbaren Services anzeigen
systemctl list-units "mediaindexer@*"

# Service starten/stoppen
sudo systemctl start mediaindexer@waveform.service
sudo systemctl stop mediaindexer@waveform.service

# Service automatisch starten
sudo systemctl enable mediaindexer@waveform.service
sudo systemctl disable mediaindexer@waveform.service

# Service neustarten
sudo systemctl restart mediaindexer@waveform.service

# Alle MediaIndexer-Services starten
sudo systemctl start mediaindexer.target
```

## Überwachung und Debugging

### Status-Überwachung

```bash
# Service-Status
sudo systemctl status mediaindexer@filmstrip.service

# Detaillierter Status
sudo systemctl show mediaindexer@filmstrip.service

# Aktive Prozesse
ps aux | grep mediaindexer

# Ressourcen-Verbrauch
sudo systemctl status mediaindexer@filmstrip.service --no-pager -l
```

### Logging

```bash
# Live-Logs (nur Errors)
sudo journalctl -fu mediaindexer@filmstrip.service -p err

# Logs der letzten Stunde
sudo journalctl -u mediaindexer@filmstrip.service --since "1 hour ago"

# Logs mit spezifischem Log-Level
sudo journalctl -u mediaindexer@filmstrip.service -p info

# Log-Rotation Status
sudo journalctl --disk-usage
```

### Performance-Monitoring

```bash
# CPU/Memory-Usage
sudo systemctl status mediaindexer@filmstrip.service | grep -E "(CPU|Memory)"

# Detaillierte Ressourcen-Nutzung
sudo systemd-cgtop | grep mediaindexer

# Service-Restart-Historie
sudo journalctl -u mediaindexer@filmstrip.service | grep "Started\\|Stopped"
```

## Erweiterte Konfiguration

### Per-Instance Konfiguration

Verschiedene Instanzen können unterschiedliche Konfigurationen haben:

```bash
# Erstelle instance-spezifische Konfiguration
sudo cp /etc/mediaindexer/mediaindexer.env /etc/mediaindexer/mediaindexer-filmstrip.env

# Bearbeite die filmstrip-spezifische Konfiguration
sudo nano /etc/mediaindexer/mediaindexer-filmstrip.env
```

Dann in der systemd-Service-Datei:

```ini
EnvironmentFile=/etc/mediaindexer/mediaindexer-%i.env
```

### Ressourcen-Limits

```bash
# Service-Limits anzeigen
sudo systemctl show mediaindexer@filmstrip.service | grep -E "Memory|CPU"

# Temporäre Limits setzen
sudo systemctl set-property mediaindexer@filmstrip.service MemoryMax=1G
sudo systemctl set-property mediaindexer@filmstrip.service CPUQuota=50%
```

### Sicherheits-Features

Die systemd-Services nutzen mehrere Sicherheits-Features:

- **NoNewPrivileges**: Verhindert Privilege-Escalation
- **ProtectSystem**: Schreibschutz für System-Verzeichnisse
- **ProtectHome**: Blockiert Zugriff auf Home-Verzeichnisse
- **PrivateTmp**: Isoliertes /tmp-Verzeichnis
- **ReadWritePaths**: Explizit erlaubte Schreibpfade

## Migration von der Cron-Version

### Automatische Migration

```bash
# Führe das Migration-Script aus
./migrate-to-systemd.sh
```

### Manuelle Migration

1. **Alte Cron-Jobs entfernen**:

```bash
crontab -e  # MediaIndexer-Einträge löschen
```

2. **Konfiguration konvertieren**:

```bash
# config.ini → mediaindexer.env
# [general]
# TempDir=/tmp/mediaindexer/
# ↓
# MEDIAINDEXER_TEMP_DIR=/tmp/mediaindexer/
```

3. **systemd-Service installieren**:

```bash
sudo ./systemd/install-systemd.sh
```

## Fehlerbehandlung

### Häufige Probleme

**Service startet nicht**:

```bash
# Detaillierte Fehlerinfo
sudo journalctl -u mediaindexer@filmstrip.service --no-pager -l

# Konfiguration prüfen
sudo systemd-analyze verify /etc/systemd/system/mediaindexer@.service

# Dependencies prüfen
systemctl list-dependencies mediaindexer@filmstrip.service
```

**Fehlende Berechtigungen**:

```bash
# Datei-Berechtigungen prüfen
sudo ls -la /var/lib/mediaindexer/
sudo ls -la /etc/mediaindexer/

# Berechtigungen reparieren
sudo chown -R mediaindexer:mediaindexer /var/lib/mediaindexer/
sudo chmod 750 /var/lib/mediaindexer/
```

**FFmpeg-Fehler**:

```bash
# FFmpeg-Verfügbarkeit prüfen
sudo -u mediaindexer ffmpeg -version
sudo -u mediaindexer ffprobe -version

# PATH-Variable prüfen
sudo -u mediaindexer printenv PATH
```

### Debug-Modus

```bash
# Debug-Logging aktivieren
sudo systemctl edit mediaindexer@filmstrip.service

# Füge hinzu:
[Service]
Environment=MEDIAINDEXER_LOG_LEVEL=debug

# Service neustarten
sudo systemctl daemon-reload
sudo systemctl restart mediaindexer@filmstrip.service
```

## Performance-Optimierung

### Parallel-Verarbeitung

```bash
# Mehrere Instances für verschiedene Typen
sudo systemctl start mediaindexer@filmstrip.service
sudo systemctl start mediaindexer@waveform.service
sudo systemctl start mediaindexer@xmlinfo.service

# Oder alle auf einmal
sudo systemctl start mediaindexer.target
```

### I/O-Optimierung

```bash
# ionice für I/O-Priorität setzen
sudo systemctl edit mediaindexer@filmstrip.service

# Hinzufügen:
[Service]
IOSchedulingClass=2
IOSchedulingPriority=4
```

### Speicher-Optimierung

```bash
# Memory-Limits setzen
sudo systemctl edit mediaindexer@filmstrip.service

# Hinzufügen:
[Service]
MemoryMax=2G
MemorySwapMax=0
```

## Wartung

### Log-Rotation

```bash
# Aktuelle Log-Größe prüfen
sudo journalctl --disk-usage

# Alte Logs löschen
sudo journalctl --vacuum-time=7d
sudo journalctl --vacuum-size=100M
```

### Service-Updates

```bash
# Script aktualisieren
sudo cp mediaindexer.sh /opt/mediaindexer/
sudo chmod +x /opt/mediaindexer/mediaindexer.sh

# Services neustarten
sudo systemctl restart "mediaindexer@*.service"
```

### Backup

```bash
# Konfiguration sichern
sudo cp -r /etc/mediaindexer/ /backup/mediaindexer-config/

# Service-Dateien sichern
sudo cp /etc/systemd/system/mediaindexer@.service /backup/
sudo cp /etc/systemd/system/mediaindexer.target /backup/
```

## Deinstallation

```bash
# Services stoppen und deaktivieren
sudo systemctl stop "mediaindexer@*.service"
sudo systemctl disable "mediaindexer@*.service"

# Service-Dateien entfernen
sudo rm /etc/systemd/system/mediaindexer@.service
sudo rm /etc/systemd/system/mediaindexer.target

# systemd neu laden
sudo systemctl daemon-reload

# Dateien entfernen (optional)
sudo rm -rf /opt/mediaindexer/
sudo rm -rf /etc/mediaindexer/
sudo rm -rf /var/lib/mediaindexer/
sudo rm -rf /var/log/mediaindexer/

# Benutzer entfernen (optional)
sudo userdel mediaindexer
sudo groupdel mediaindexer
```

## Weitere Ressourcen

- **systemd-Dokumentation**: `man systemd.service`
- **Journal-Logs**: `man journalctl`
- **Service-Management**: `man systemctl`
- **Environment-Dateien**: `man systemd.exec`

---

**Hinweis**: Diese systemd-Version ersetzt die alte Cron-basierte Implementierung vollständig und bietet deutlich bessere Integration in moderne Linux-Systeme.
