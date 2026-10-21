#!/bin/bash
# Compare les sources vues par Suricata aux decisions de CrowdSec.
#
# Lecture seule. Repond a une question : mon detecteur voit-il des sources
# que mon systeme de bannissement ignore ? CrowdSec ne lit que les journaux
# qu'on lui donne (souvent le seul access log du reverse proxy) : une
# requete rejetee avant d'etre journalisee n'existe pas pour lui.
#
# Usage : sudo ./ecart-suricata-crowdsec.sh [heures] [nombre]
#   heures : fenetre analysee (defaut 24)
#   nombre : nombre de sources affichees (defaut 15)
#
# Variables :
#   FAST_LOG            defaut /var/log/suricata/fast.log
#   CROWDSEC_CONTAINER  defaut crowdsec ; vide = cscli installe sur l'hote
#
# Code de sortie : 0 si toutes les sources affichees ont une decision,
# 1 si au moins une n'en a pas, 2 en cas d'erreur.

set -uo pipefail

heures=${1:-24}
nombre=${2:-15}
FAST_LOG=${FAST_LOG:-/var/log/suricata/fast.log}
CONTENEUR=${CROWDSEC_CONTAINER-crowdsec}

[[ "$heures" =~ ^[0-9]+$ && "$nombre" =~ ^[0-9]+$ ]] || { echo "usage: $0 [heures] [nombre]" >&2; exit 2; }
[ -r "$FAST_LOG" ] || { echo "illisible : $FAST_LOG (lancer avec sudo ?)" >&2; exit 2; }

cscli() {
    if [ -n "$CONTENEUR" ]; then docker exec "$CONTENEUR" cscli "$@"; else command cscli "$@"; fi
}

decisions=$(cscli decisions list -o raw 2>/dev/null) || { echo "cscli injoignable" >&2; exit 2; }

# fast.log horodate en MM/JJ/AAAA-HH:MM:SS : on reordonne en AAAAMMJJHHMMSS
# pour comparer des chaines, y compris a cheval sur deux annees.
# fast.log est en heure locale, le seuil aussi.
seuil=$(date -d "-$heures hour" +%Y%m%d%H%M%S)

echo "Sources vues par Suricata sur ${heures} h, et decision CrowdSec en cours :"
echo
printf '%8s  %-40s %s\n' "alertes" "source" "decision"

ecart=0
while read -r n ip; do
    # Adresse entiere, pas une sous-chaine (1.2.3.4 ne doit pas valider 11.2.3.45).
    motif="(^|[^0-9a-fA-F.])${ip//./\\.}([^0-9a-fA-F.:]|$)"
    if printf '%s\n' "$decisions" | grep -qE -- "$motif"; then
        etat="oui"
    else
        etat="AUCUNE"
        ecart=1
    fi
    printf '%8s  %-40s %s\n' "$n" "$ip" "$etat"
done < <(
    awk -v seuil="$seuil" '
        {
            split($1, t, /[\/\-:.]/)
            cle = t[3] t[1] t[2] t[4] t[5] t[6]
            if (cle < seuil) next
            if (match($0, /\} [0-9a-fA-F:.]+/)) {
                src = substr($0, RSTART + 2, RLENGTH - 2)
                sub(/:[0-9]+$/, "", src)
                print src
            }
        }' "$FAST_LOG" | sort | uniq -c | sort -rn | head -n "$nombre"
)

echo
if [ "$ecart" -eq 1 ]; then
    echo "Des sources tres actives n'ont aucune decision. Verifiez si leurs"
    echo "requetes atteignent le journal lu par CrowdSec (voir RECETTE.txt)."
fi
exit "$ecart"
