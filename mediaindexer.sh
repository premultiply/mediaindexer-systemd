#!/bin/bash

# MediaIndexer Bash Version
# Linux-native media indexing service with systemd support
# Moderne Linux-Implementierung mit Environment-basierter Konfiguration

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# =============================================================================
# KONFIGURATION UND SETUP
# =============================================================================

# Script-Verzeichnis ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Standard-Konfigurationsdateien
DEFAULT_ENV_FILE="$SCRIPT_DIR/mediaindexer.env"
SYSTEM_ENV_FILE="/etc/mediaindexer/mediaindexer.env"

# Konfiguration laden (Environment-Variablen mit Fallbacks)
load_config() {
    # Bestimme welche Konfigurationsdatei verwendet werden soll
    local env_file=""
    
    # 1. Kommandozeilen-Parameter
    if [[ -n "${MEDIAINDEXER_CONFIG_FILE:-}" ]]; then
        env_file="$MEDIAINDEXER_CONFIG_FILE"
    # 2. System-Konfiguration
    elif [[ -f "$SYSTEM_ENV_FILE" ]]; then
        env_file="$SYSTEM_ENV_FILE"
    # 3. Lokale Konfiguration
    elif [[ -f "$DEFAULT_ENV_FILE" ]]; then
        env_file="$DEFAULT_ENV_FILE"
    fi
    
    # Environment-Datei laden falls vorhanden
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        info "Loading configuration from: $env_file"
        # Lade Environment-Datei, ignoriere Kommentare und leere Zeilen
        set -a  # Automatisch alle Variablen exportieren
        source <(grep -v '^\s*#' "$env_file" | grep -v '^\s*$' || true)
        set +a
    else
        info "No configuration file found, using defaults"
    fi
    
    # Konfigurationswerte mit Fallbacks setzen
    TEMP_DIR="${MEDIAINDEXER_TEMP_DIR:-/tmp/mediaindexer/}"
    SOURCE_DIR="${MEDIAINDEXER_SOURCE_DIR:-$SCRIPT_DIR/input/}"
    DESTINATION_DIR="${MEDIAINDEXER_DESTINATION_DIR:-$SCRIPT_DIR/output/}"
    DISABLE_REMOVAL="${MEDIAINDEXER_DISABLE_REMOVAL:-0}"
    IGNORE_MISSING_FRAMES="${MEDIAINDEXER_IGNORE_MISSING_FRAMES:-0}"
    
    # FFmpeg-Einstellungen (immer system-native Versionen verwenden)
    FFMPEG_EXE="ffmpeg"
    FFPROBE_EXE="ffprobe"
    IMG_WIDTH="${MEDIAINDEXER_IMG_WIDTH:-4096}"
    
    # FFmpeg-Optionen
    FFPROBE_OPTS="${MEDIAINDEXER_FFPROBE_OPTS:- -loglevel level+quiet}"
    FFMPEG_OPTS="${MEDIAINDEXER_FFMPEG_OPTS:- -hide_banner -nostdin -nostats -probesize 16M}"
    
    # Logging-Einstellungen
    LOG_LEVEL="${MEDIAINDEXER_LOG_LEVEL:-info}"
    LOG_FILE="${MEDIAINDEXER_LOG_FILE:-}"
    
    # Performance-Einstellungen
    SLEEP_INTERVAL="${MEDIAINDEXER_SLEEP_INTERVAL:-10}"
}

# Logging-Funktionen mit verbessertem Output
log() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_line="[$timestamp] [$level] $message"
    
    # Ausgabe je nach Level
    case "${level^^}" in
        ERROR)
            echo "$log_line" >&2
            ;;
        WARN)
            echo "$log_line" >&2
            ;;
        *)
            echo "$log_line" >&2
            ;;
    esac
    
    # In Log-Datei schreiben falls konfiguriert
    if [[ -n "$LOG_FILE" ]]; then
        echo "$log_line" >> "$LOG_FILE"
    fi
}

# Convenience-Funktionen für verschiedene Log-Level
info() {
    log "INFO" "$@"
}

warn() {
    log "WARN" "$@"
}

error() {
    log "ERROR" "$@"
}

debug() {
    if [[ "${LOG_LEVEL,,}" == "debug" ]]; then
        log "DEBUG" "$@"
    fi
}

# Konfiguration laden
load_config

# Pfade normalisieren (trailing slash hinzufügen)
[[ "$TEMP_DIR" != */ ]] && TEMP_DIR="$TEMP_DIR/"
[[ "$SOURCE_DIR" != */ ]] && SOURCE_DIR="$SOURCE_DIR/"
[[ "$DESTINATION_DIR" != */ ]] && DESTINATION_DIR="$DESTINATION_DIR/"

# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================

# Überprüft ob eine Datei noch geschrieben wird
is_file_in_use() {
    local file="$1"
    
    # Prüfe ob Datei existiert
    if [[ ! -f "$file" ]]; then
        return 1  # Datei existiert nicht - nicht in Verwendung
    fi
    
    # Methode 1: Prüfe mit lsof auf schreibende Prozesse
    if command -v lsof &> /dev/null; then
        # Suche nach Prozessen die die Datei zum Schreiben geöffnet haben
        # +D = Verzeichnis rekursiv, +L1 = folge symbolischen Links
        # Filtere nach Schreibzugriff (w, u für read/write)
        if lsof +L1 "$file" 2>/dev/null | grep -q '[wu]'; then
            debug "File $file is open for writing (detected by lsof)"
            return 0  # In Verwendung zum Schreiben
        fi
    fi
    
    # Methode 2: Größen-Check über kurze Zeit
    # Wenn sich die Dateigröße ändert, wird noch geschrieben
    local size1 size2
    size1=$(stat -c%s "$file" 2>/dev/null || echo "0")
    sleep 0.1  # 100ms warten
    size2=$(stat -c%s "$file" 2>/dev/null || echo "0")
    
    if [[ "$size1" != "$size2" ]]; then
        debug "File $file size changed ($size1 -> $size2) - still being written"
        return 0  # Größe hat sich geändert - wird noch geschrieben
    fi
    
    debug "File $file appears to be stable - not being written"
    return 1  # Nicht in Verwendung
}

# Kopiert Zeitstempel von Quelle zu Ziel
copy_time_props() {
    local source="$1"
    local destination="$2"
    
    if [[ -f "$destination" && -f "$source" ]]; then
        touch -r "$source" "$destination"
    fi
}

# Überprüft ob eine Datei aktualisiert werden muss
check_compare() {
    local source="$1"
    local destination="$2"
    
    # Prüfen ob Quelldatei existiert und keine Directory ist
    if [[ ! -f "$source" ]]; then
        return 1  # Falsch
    fi
    
    # Prüfen ob Quelldatei groß genug ist (> 64KB)
    local size
    size=$(stat -f%z "$source" 2>/dev/null || stat -c%s "$source" 2>/dev/null || echo "0")
    if [[ "$size" -le 65536 ]]; then
        return 1  # Falsch
    fi
    
    # Prüfen ob Zieldatei nicht existiert oder leer ist
    if [[ ! -f "$destination" ]] || [[ ! -s "$destination" ]]; then
        if ! is_file_in_use "$source"; then
            return 0  # Wahr - Datei muss verarbeitet werden
        else
            return 1  # Falsch - Datei ist in Verwendung
        fi
    fi
    
    # Prüfen ob Modifikationszeiten unterschiedlich sind
    local source_mtime dest_mtime
    source_mtime=$(stat -f%m "$source" 2>/dev/null || stat -c%Y "$source" 2>/dev/null || echo "0")
    dest_mtime=$(stat -f%m "$destination" 2>/dev/null || stat -c%Y "$destination" 2>/dev/null || echo "0")
    
    if [[ "$source_mtime" -ne "$dest_mtime" ]]; then
        if ! is_file_in_use "$source"; then
            return 0  # Wahr - Datei muss verarbeitet werden
        fi
    fi
    
    return 1  # Falsch - Keine Verarbeitung nötig
}

# =============================================================================
# MEDIENFUNKTIONEN
# =============================================================================

# Führt ffprobe aus und gibt JSON-Ausgabe zurück
run_ffprobe_json() {
    local file="$1"
    local destination="$2"
    
    info "Creating JSON metadata for: $file"
    
    if "$FFPROBE_EXE" $FFPROBE_OPTS -show_format -show_programs -show_streams -show_chapters -show_error -print_format json "$file" > "$destination" 2>/dev/null; then
        return 0
    else
        [[ -f "$destination" ]] && rm -f "$destination"
        return 1
    fi
}

# Führt ffprobe aus und gibt XML-Ausgabe zurück
run_ffprobe_xml() {
    local file="$1"
    local destination="$2"
    
    info "Creating XML metadata for: $file"
    
    if "$FFPROBE_EXE" $FFPROBE_OPTS -show_format -show_programs -show_streams -show_chapters -show_error -print_format xml "$file" > "$destination" 2>/dev/null; then
        return 0
    else
        [[ -f "$destination" ]] && rm -f "$destination"
        return 1
    fi
}

# Ermittelt die Dauer einer Mediendatei mit ffmpeg
run_ffmpeg_get_duration() {
    local file="$1"
    
    local output
    output=$("$FFMPEG_EXE" $FFMPEG_OPTS -i "$file" 2>&1 || true)
    
    # Extrahiere Duration-String
    local duration
    duration=$(echo "$output" | grep -o 'Duration: [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9]' | head -1 | cut -d' ' -f2)
    
    if [[ -n "$duration" ]]; then
        # Konvertiere HH:MM:SS.ss zu Sekunden
        local hours minutes seconds
        IFS=: read -r hours minutes seconds <<< "$duration"
        
        # Berechne Gesamtsekunden
        local total_seconds
        total_seconds=$(echo "$hours * 3600 + $minutes * 60 + $seconds" | bc -l)
        echo "$total_seconds"
    else
        echo "-1"
    fi
}

# Ermittelt die Dauer in Frames für MXF-Dateien
run_bmxtranswrap_get_duration() {
    local file="$1"
    
    if ! command -v bmxtranswrap &> /dev/null; then
        debug "bmxtranswrap not available, skipping MXF frame count"
        echo "-1"
        return 1
    fi
    
    local output
    output=$(bmxtranswrap -t op1a --start 9223372036854775807 --dur 0 --check-end --check-complete --disable-audio --disable-data "$file" 2>&1 || true)
    
    local duration
    duration=$(echo "$output" | grep -o 'input duration [0-9]*' | cut -d' ' -f3)
    
    if [[ -n "$duration" ]]; then
        echo "$duration"
    else
        echo "-1"
    fi
}

# Extrahiert einen Frame an einer bestimmten Position
run_ffmpeg_pos_frame() {
    local file="$1"
    local pos="$2"
    local duration="${3:-0}"
    local reverse="${4:-false}"
    
    local seek_option=""
    [[ "$duration" != "0" && $(echo "$duration > 0" | bc -l) -eq 1 ]] && seek_option=" -ss $duration"
    
    local reverse_filter=""
    [[ "$reverse" == "true" ]] && reverse_filter="reverse,"
    
    local output_file="${TEMP_DIR}temp$(printf '%02d' "$pos").bmp"
    
    mkdir -p "$TEMP_DIR"
    
    if "$FFMPEG_EXE" $FFMPEG_OPTS -loglevel quiet $seek_option -i "$file" -an -vsync 0 -vf "${reverse_filter}scale=dar*ih/2:ih/2" -vframes 1 -y "$output_file" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Extrahiert einen Frame an einer bestimmten Position (MXF)
run_bmxtranswrap_pos_frame() {
    local file="$1"
    local pos="$2"
    local duration="$3"
    
    if ! command -v bmxtranswrap &> /dev/null; then
        debug "bmxtranswrap not available, skipping MXF frame extraction"
        return 1
    fi
    
    local temp_file="${TEMP_DIR}temp$(printf '%02d' "$pos").mxf"
    mkdir -p "$TEMP_DIR"
    
    local rounded_duration
    rounded_duration=$(echo "$duration" | cut -d. -f1)
    
    if bmxtranswrap --log-level 0 -t op1a --start "$rounded_duration" --dur 1 --check-complete -o "$temp_file" --disable-audio --disable-data "$file" >/dev/null 2>&1; then
        local result
        if run_ffmpeg_pos_frame "$temp_file" "$pos" "0" "true"; then
            result=0
        else
            result=1
        fi
        [[ -f "$temp_file" ]] && rm -f "$temp_file"
        return $result
    else
        return 1
    fi
}

# Erstellt ein Filmstrip aus mehreren Frames
run_ffmpeg_stack_frames() {
    local source_pattern="$1"
    local destination="$2"
    
    if "$FFMPEG_EXE" $FFMPEG_OPTS -loglevel quiet -i "$source_pattern" -vf "tile=11x1:color=lime,scale=${IMG_WIDTH}:-1" -qscale:v 5 -y "$destination" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Erstellt Waveform-Visualisierung
run_ffmpeg_waves() {
    local file="$1"
    local destination="$2"
    local single_audio_track="${3:-true}"
    
    info "Creating waveform for: $file"
    
    local audio_filter
    if [[ "$single_audio_track" == "true" ]]; then
        audio_filter="pan=stereo|c0=c0|c1=c1,"
    else
        audio_filter="amerge=inputs=2,"
    fi
    
    if "$FFMPEG_EXE" $FFMPEG_OPTS -loglevel quiet -i "$file" -vn -filter_complex:a "${audio_filter}showwavespic=s=${IMG_WIDTH}x64:colors=white:scale=log,negate" -frames:v 1 -y "$destination" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Erstellt EBU R128 Loudness Summary
run_ffmpeg_ebur128_sum() {
    local file="$1"
    local destination="$2"
    local single_audio_track="${3:-true}"
    
    info "Creating EBU R128 summary for: $file"
    
    local audio_filter
    if [[ "$single_audio_track" == "true" ]]; then
        audio_filter="pan=stereo|c0=c0|c1=c1,"
    else
        audio_filter="amerge=inputs=2,"
    fi
    
    local output
    output=$("$FFMPEG_EXE" $FFMPEG_OPTS -loglevel level+info -i "$file" -vn -filter_complex:a "${audio_filter}ebur128=peak=true:framelog=verbose" -f null - 2>&1 || true)
    
    # Extrahiere Summary-Teil
    local summary
    summary=$(echo "$output" | sed -n '/Summary:/,/^$/p' | sed -n '/Summary:/,$p')
    
    if [[ -n "$summary" ]]; then
        [[ -f "$destination" ]] && rm -f "$destination"
        echo "$summary" > "$destination"
        return 0
    else
        return 1
    fi
}

# Erstellt EBU R128 Loudness Log
run_ffmpeg_ebur128_log() {
    local file="$1"
    local destination="$2"
    local single_audio_track="${3:-true}"
    
    info "Creating EBU R128 log for: $file"
    
    local audio_filter
    if [[ "$single_audio_track" == "true" ]]; then
        audio_filter="pan=stereo|c0=c0|c1=c1,"
    else
        audio_filter="amerge=inputs=2,"
    fi
    
    local output
    output=$("$FFMPEG_EXE" $FFMPEG_OPTS -loglevel level+verbose -i "$file" -vn -filter_complex:a "${audio_filter}ebur128=peak=true:framelog=verbose" -f null - 2>&1 || true)
    
    # Extrahiere verbose-Logs
    local logs
    logs=$(echo "$output" | grep '\[verbose\].*t: ' | sed 's/.*\[verbose\] //')
    
    if [[ -n "$logs" ]]; then
        [[ -f "$destination" ]] && rm -f "$destination"
        echo "$logs" > "$destination"
        return 0
    else
        return 1
    fi
}

# Führt MXF2RAW aus für MXF-Info-Extraktion
run_mxf2raw() {
    local file="$1"
    local destination="$2"
    
    if ! command -v mxf2raw &> /dev/null; then
        debug "mxf2raw not available, skipping MXF info extraction"
        return 1
    fi
    
    info "Creating MXF info for: $file"
    
    if mxf2raw --info --info-format xml --info-file "$destination" --check-complete --check-end "$file" >/dev/null 2>&1; then
        if [[ -f "$destination" && -s "$destination" ]]; then
            return 0
        else
            [[ -f "$destination" ]] && rm -f "$destination"
            return 1
        fi
    else
        [[ -f "$destination" ]] && rm -f "$destination"
        return 1
    fi
}

# Erstellt ein Filmstrip (entspricht der Filmstrip-Funktion aus AutoIt)
create_filmstrip() {
    local file="$1"
    local target="$2"
    local is_mxf_file="${3:-false}"
    
    info "Creating filmstrip for: $file"
    
    mkdir -p "$TEMP_DIR"
    
    local duration
    if [[ "$is_mxf_file" == "true" ]]; then
        duration=$(run_bmxtranswrap_get_duration "$file")
    else
        duration=$(run_ffmpeg_get_duration "$file")
    fi
    
    if [[ "$duration" == "-1" ]] || [[ $(echo "$duration <= 0" | bc -l) -eq 1 ]]; then
        error "Could not determine duration for: $file"
        return 1
    fi
    
    local successful=0
    
    if [[ "$is_mxf_file" == "true" ]]; then
        # 0-based Frame position für MXF
        duration=$(echo "$duration - 1" | bc -l)
        
        run_bmxtranswrap_pos_frame "$file" 0 0 && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 1 $(echo "$duration * 0.1" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 2 $(echo "$duration * 0.2" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 3 $(echo "$duration * 0.3" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 4 $(echo "$duration * 0.4" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 5 $(echo "$duration * 0.5" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 6 $(echo "$duration * 0.6" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 7 $(echo "$duration * 0.7" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 8 $(echo "$duration * 0.8" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 9 $(echo "$duration * 0.9" | bc -l) && ((successful++)) || true
        run_bmxtranswrap_pos_frame "$file" 10 "$duration" && ((successful++)) || true
    else
        run_ffmpeg_pos_frame "$file" 0 0 && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 1 $(echo "$duration * 0.1" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 2 $(echo "$duration * 0.2" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 3 $(echo "$duration * 0.3" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 4 $(echo "$duration * 0.4" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 5 $(echo "$duration * 0.5" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 6 $(echo "$duration * 0.6" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 7 $(echo "$duration * 0.7" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 8 $(echo "$duration * 0.8" | bc -l) && ((successful++)) || true
        run_ffmpeg_pos_frame "$file" 9 $(echo "$duration * 0.9" | bc -l) && ((successful++)) || true
        
        local last_frame_time
        last_frame_time=$(echo "if ($duration - 10.0 > 0) $duration - 10.0 else 0" | bc -l)
        run_ffmpeg_pos_frame "$file" 10 "$last_frame_time" "true" && ((successful++)) || true
    fi
    
    if [[ "$successful" -eq 11 ]] || [[ "$IGNORE_MISSING_FRAMES" == "1" ]]; then
        # Alle Frames extrahiert, jetzt zusammenfügen
        if run_ffmpeg_stack_frames "${TEMP_DIR}temp%02d.bmp" "$target"; then
            info "Filmstrip created successfully: $target"
            # Temporäre Dateien löschen
            rm -f "${TEMP_DIR}temp"??.bmp
            return 0
        else
            error "Failed to create filmstrip: $target"
            # Temporäre Dateien löschen
            rm -f "${TEMP_DIR}temp"??.bmp
            return 1
        fi
    else
        error "Only $successful of 11 frames extracted for: $file"
        # Temporäre Dateien löschen
        rm -f "${TEMP_DIR}temp"??.bmp
        return 1
    fi
}

# =============================================================================
# HAUPTFUNKTIONEN
# =============================================================================

# Verarbeitet eine einzelne Datei basierend auf dem Instance-Type
process_file() {
    local source="$1"
    local destination="$2"
    local extension="$3"
    local instance_type="$4"
    
    # Fehlerbehandlung: Einzelne Dateifehler sollen das Script nicht beenden
    set +e  # Temporär Error-Exit deaktivieren
    
    local success=false
    
    case "$instance_type" in
        "filmstrip")
            local is_mxf=false
            [[ "${extension,,}" == "mxf" ]] && is_mxf=true
            if create_filmstrip "$source" "$destination" "$is_mxf"; then
                success=true
            fi
            ;;
        "waveform")
            if run_ffmpeg_waves "$source" "$destination" "false" || run_ffmpeg_waves "$source" "$destination" "true"; then
                success=true
            fi
            ;;
        "r128sum")
            if run_ffmpeg_ebur128_sum "$source" "$destination" "false" || run_ffmpeg_ebur128_sum "$source" "$destination" "true"; then
                success=true
            fi
            ;;
        "r128log")
            if run_ffmpeg_ebur128_log "$source" "$destination" "false" || run_ffmpeg_ebur128_log "$source" "$destination" "true"; then
                success=true
            fi
            ;;
        "xmlinfo")
            if run_ffprobe_xml "$source" "$destination"; then
                success=true
            fi
            ;;
        "jsoninfo")
            if run_ffprobe_json "$source" "$destination"; then
                success=true
            fi
            ;;
        "mxfinfo")
            if run_mxf2raw "$source" "$destination"; then
                success=true
            fi
            ;;
    esac
    
    set -e  # Error-Exit wieder aktivieren
    
    if [[ "$success" == "true" ]]; then
        return 0
    else
        error "Failed to process file: $source"
        return 1
    fi
}

# Verarbeitet alle Quelldateien
process_source_files() {
    local instance_type="$1"
    local instance_ext="$2"
    
    info "Processing source files for type: $instance_type"
    
    # Sicherstellen, dass Verzeichnisse existieren
    mkdir -p "$SOURCE_DIR" "$DESTINATION_DIR" "$TEMP_DIR"
    
    local processed_count=0
    local error_count=0
    local total_count=0
    
    # Alle Dateien im Source-Verzeichnis durchgehen
    while IFS= read -r -d '' source_file; do
        # Überspringe Verzeichnisse
        [[ -d "$source_file" ]] && continue
        
        total_count=$((total_count + 1))
        
        local basename filename extension destination
        basename=$(basename "$source_file")
        filename="${basename%.*}"
        extension="${basename##*.}"
        destination="${DESTINATION_DIR}${filename}.${instance_ext}"
        
        if check_compare "$source_file" "$destination"; then
            info "Processing: $source_file -> $destination"
            
            # Verarbeitung mit Fehlerbehandlung
            if process_file "$source_file" "$destination" "$extension" "$instance_type"; then
                copy_time_props "$source_file" "$destination"
                processed_count=$((processed_count + 1))
                info "Successfully processed: $source_file"
            else
                error_count=$((error_count + 1))
                warn "Failed to process: $source_file (continuing with next file)"
            fi
        fi
        
    done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -print0)
    
    info "Processing completed: $processed_count successful, $error_count failed, $total_count total files"
}

# Verarbeitet Zieldateien für das Löschen verwaister Dateien
process_destination_files() {
    local instance_ext="$1"
    
    if [[ "$DISABLE_REMOVAL" == "1" ]]; then
        log "File removal disabled by configuration"
        return
    fi
    
    log "Entering deletion loop"
    
    local removed_count=0
    
    # Alle Ausgabedateien durchgehen
    while IFS= read -r -d '' dest_file; do
        local basename filename source_pattern
        basename=$(basename "$dest_file")
        filename="${basename%.*}"
        
        # Suche nach entsprechender Quelldatei (mit beliebiger Extension)
        local source_exists=false
        while IFS= read -r -d '' source_file; do
            local source_basename source_filename
            source_basename=$(basename "$source_file")
            source_filename="${source_basename%.*}"
            
            if [[ "$source_filename" == "$filename" ]]; then
                source_exists=true
                break
            fi
        done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -print0 2>/dev/null || true)
        
        if [[ "$source_exists" == "false" ]]; then
            log "Source for $filename has gone. Removing $dest_file"
            rm -f "$dest_file"
            removed_count=$((removed_count + 1))
        fi
        
    done < <(find "$DESTINATION_DIR" -maxdepth 1 -name "*.${instance_ext}" -type f -print0 2>/dev/null || true)
    
    log "Removed $removed_count orphaned files"
}

# Hauptschleife (für kontinuierliche Ausführung)
main_loop() {
    local instance_type="$1"
    local instance_ext="$2"
    local run_once="${3:-false}"
    
    while true; do
        log "Starting processing cycle for instance type: $instance_type"
        
        process_source_files "$instance_type" "$instance_ext"
        process_destination_files "$instance_ext"
        
        log "Processing cycle completed"
        
        if [[ "$run_once" == "true" ]]; then
            break
        fi
        
        # 10 Sekunden warten vor nächstem Zyklus
        sleep "$SLEEP_INTERVAL"
    done
}

# =============================================================================
# HAUPTPROGRAMM
# =============================================================================

# Hilfefunktion
show_help() {
    cat << EOF
MediaIndexer systemd Service

Usage: $0 [OPTIONS] INSTANCE_TYPE

INSTANCE_TYPE:
  filmstrip   - Create filmstrips (JPG)
  waveform    - Create waveform visualizations (GIF)  
  r128sum     - Create EBU R128 audio summaries
  r128log     - Create detailed EBU R128 logs
  xmlinfo     - Extract metadata as XML
  jsoninfo    - Extract metadata as JSON
  mxfinfo     - Extract MXF-specific information

OPTIONS:
  -o, --once     Run once and exit (default: continuous loop)
  -h, --help     Show this help

Examples:
  $0 filmstrip                    # Run filmstrip generation continuously
  $0 --once waveform             # Generate waveforms once and exit

Configuration:
  Configuration is loaded from environment files in this order:
  1. MEDIAINDEXER_CONFIG_FILE environment variable
  2. /etc/mediaindexer/mediaindexer.env (system config)
  3. ./mediaindexer.env (local config)

Requirements:
  - ffmpeg and ffprobe must be installed system-wide
  - bc (calculator) package for duration calculations
  - bmxtranswrap (optional, for MXF support)
  - mxf2raw (optional, for MXF metadata extraction)
  - lsof (optional, for better file-in-use detection)
EOF
}

# Kommandozeilenargumente verarbeiten
RUN_ONCE=false
INSTANCE_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--once)
            RUN_ONCE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        filmstrip|waveform|r128sum|r128log|xmlinfo|jsoninfo|mxfinfo)
            INSTANCE_TYPE="$1"
            shift
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validierung
if [[ -z "$INSTANCE_TYPE" ]]; then
    error "Instance type parameter is missing"
    echo "Supported instance types are: filmstrip, waveform, r128sum, r128log, xmlinfo, jsoninfo, mxfinfo" >&2
    exit 1
fi

# Instance-Extension ermitteln
case "$INSTANCE_TYPE" in
    "filmstrip")  INSTANCE_EXT="jpg" ;;
    "waveform")   INSTANCE_EXT="gif" ;;
    "r128sum")    INSTANCE_EXT="r128sum" ;;
    "r128log")    INSTANCE_EXT="r128log" ;;
    "xmlinfo")    INSTANCE_EXT="xml" ;;
    "jsoninfo")   INSTANCE_EXT="json" ;;
    "mxfinfo")    INSTANCE_EXT="xml" ;;
    *)
        error "Wrong instance type parameter: $INSTANCE_TYPE"
        exit 1
        ;;
esac

# Abhängigkeiten prüfen
if ! command -v ffmpeg &> /dev/null; then
    error "ffmpeg not found. Please install ffmpeg package."
    exit 1
fi

if ! command -v ffprobe &> /dev/null; then
    error "ffprobe not found. Please install ffmpeg package."
    exit 1
fi

if ! command -v bc &> /dev/null; then
    error "bc (calculator) not found. Please install bc package."
    exit 1
fi

# Optionale Tools prüfen (Warnungen, aber kein Exit)
if ! command -v bmxtranswrap &> /dev/null; then
    warn "bmxtranswrap not found. MXF support will be limited."
fi

if ! command -v mxf2raw &> /dev/null; then
    warn "mxf2raw not found. MXF metadata extraction will not be available."
fi

if ! command -v lsof &> /dev/null; then
    warn "lsof not found. File-in-use detection will use fallback method."
fi

# Konfiguration ausgeben
info "MediaIndexer starting"
info "Instance Type: $INSTANCE_TYPE"
info "Instance Extension: $INSTANCE_EXT"
info "Source Directory: $SOURCE_DIR"
info "Destination Directory: $DESTINATION_DIR"
info "Temp Directory: $TEMP_DIR"
info "Run Once: $RUN_ONCE"
info "Log Level: $LOG_LEVEL"
[[ -n "$LOG_FILE" ]] && info "Log File: $LOG_FILE"

# Verzeichnisse erstellen falls nötig
mkdir -p "$SOURCE_DIR" "$DESTINATION_DIR" "$TEMP_DIR"
[[ -n "$LOG_FILE" ]] && mkdir -p "$(dirname "$LOG_FILE")"

# Hauptschleife starten
main_loop "$INSTANCE_TYPE" "$INSTANCE_EXT" "$RUN_ONCE"

info "MediaIndexer completed"
