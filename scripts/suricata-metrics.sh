#!/bin/bash
# Expose des metriques Suricata au textfile collector de node-exporter.
# A lancer par cron toutes les 2 minutes. Meme pattern que les
# scans de durcissement (rkhunter/lynis/aide) : ecriture atomique via .tmp + mv.
#
# Metriques exposees :
#   suricata_up                             1 si le service systemd tourne
#   suricata_capture_kernel_packets_total   compteur paquets vus par le kernel
#   suricata_capture_kernel_drops_total     compteur paquets perdus en capture
#   suricata_alerts_total{severity="N"}     compteur d'alertes par severite
#   suricata_eve_log_bytes                  taille courante de eve.json
#   suricata_metrics_last_run_timestamp_seconds  fraicheur de ce collecteur
#
# Les compteurs repartent a zero a chaque rotation de eve.json / redemarrage :
# c'est un reset de compteur, gere nativement par rate()/increase() cote Prometheus.

set -uo pipefail

OUTDIR=${OUTDIR:-/var/lib/prometheus/node-exporter}
OUT="$OUTDIR/suricata.prom"
TMP="$OUTDIR/.suricata.prom.tmp"
EVE=${EVE:-/var/log/suricata/eve.json}

emit() { printf '%s\n' "$1" >> "$TMP"; }

: > "$TMP"

# --- etat du service ---
if systemctl is-active --quiet suricata; then up=1; else up=0; fi
emit '# HELP suricata_up Suricata systemd service is active.'
emit '# TYPE suricata_up gauge'
emit "suricata_up $up"

# --- compteurs de capture (dernier evenement stats de eve.json) ---
# tail -c borne le scan : inutile de relire tout le fichier.
last_stats=$(tail -c 5000000 "$EVE" 2>/dev/null | grep '"event_type":"stats"' | tail -1)
if [ -z "$last_stats" ]; then
    last_stats=$(grep '"event_type":"stats"' "$EVE" 2>/dev/null | tail -1)
fi
if [ -n "$last_stats" ]; then
    pkts=$(printf '%s' "$last_stats" | jq -r '.stats.capture.kernel_packets // empty' 2>/dev/null)
    drops=$(printf '%s' "$last_stats" | jq -r '.stats.capture.kernel_drops // empty' 2>/dev/null)
    if [ -n "$pkts" ] && [ -n "$drops" ]; then
        emit '# HELP suricata_capture_kernel_packets_total Packets seen by the kernel capture.'
        emit '# TYPE suricata_capture_kernel_packets_total counter'
        emit "suricata_capture_kernel_packets_total $pkts"
        emit '# HELP suricata_capture_kernel_drops_total Packets dropped by the kernel capture.'
        emit '# TYPE suricata_capture_kernel_drops_total counter'
        emit "suricata_capture_kernel_drops_total $drops"
    fi
fi

# --- alertes par severite ---
# grep d'abord (rapide sur un gros fichier), jq seulement sur les lignes alert.
emit '# HELP suricata_alerts_total Suricata alerts in the current eve.json, by severity.'
emit '# TYPE suricata_alerts_total counter'
counts=$(grep '"event_type":"alert"' "$EVE" 2>/dev/null \
         | jq -r '.alert.severity // empty' 2>/dev/null \
         | sort -n | uniq -c)
for sev in 1 2 3; do
    n=$(printf '%s\n' "$counts" | awk -v s="$sev" '$2 == s {print $1}')
    emit "suricata_alerts_total{severity=\"$sev\"} ${n:-0}"
done

# --- volume de log ---
size=$(stat -c %s "$EVE" 2>/dev/null || echo 0)
emit '# HELP suricata_eve_log_bytes Current size of eve.json in bytes.'
emit '# TYPE suricata_eve_log_bytes gauge'
emit "suricata_eve_log_bytes $size"

# --- fraicheur du collecteur lui-meme ---
emit '# HELP suricata_metrics_last_run_timestamp_seconds Unix time of the last collector run.'
emit '# TYPE suricata_metrics_last_run_timestamp_seconds gauge'
emit "suricata_metrics_last_run_timestamp_seconds $(date +%s)"

chmod 0644 "$TMP"
mv "$TMP" "$OUT"
