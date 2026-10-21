#!/bin/bash
# Compare chaque fichier du depot a sa copie deployee (deploiements.tsv) :
# contenu, proprietaire et mode.
# Lecture seule : ne copie rien, dans aucun sens.
# Code de sortie : 0 = aucune derive, 1 = au moins une derive ou un fichier absent.
set -u
cd "$(dirname "$0")/.." || exit 2   # racine du depot

derive=0
while IFS=$'\t' read -r depot deploye proprio mode _apres; do
    [[ -z "$depot" || "$depot" == \#* ]] && continue
    if ! sudo -n test -f "$deploye"; then
        echo "ABSENT   $deploye"
        derive=1
        continue
    fi
    if ! sudo -n cat "$deploye" | cmp -s - "$depot"; then
        echo "CONTENU  $depot <> $deploye"
        derive=1
    fi
    actuel=$(sudo -n stat -c '%U:%G %a' "$deploye")
    if [[ "$actuel" != "$proprio $mode" ]]; then
        echo "DROITS   $deploye : $actuel, attendu $proprio $mode"
        derive=1
    fi
done < deploiement/deploiements.tsv

[[ $derive -eq 0 ]] && echo "OK, aucune derive"
exit $derive
