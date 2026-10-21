#!/bin/bash
# Deploie le depot sur la machine, par copie (jamais par lien symbolique :
# cron ignore un lien vers un fichier qui n'appartient pas a root, et AIDE
# ne surveille pas forcement le dossier du depot).
#
# Sans argument : montre ce qui changerait, n'ecrit rien.
# --appliquer    : montre, demande confirmation, copie, puis relance derive.sh.
#
# Ne redemarre aucun service : la colonne « a faire apres » de
# deploiements.tsv est affichee pour chaque fichier copie.
set -u
cd "$(dirname "$0")/.." || exit 2   # racine du depot

appliquer=0
case "${1:-}" in
    "") ;;
    --appliquer) appliquer=1 ;;
    *) echo "usage: $0 [--appliquer]" >&2; exit 2 ;;
esac

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Arbre de travail sale : committer avant de deployer." >&2
    exit 2
fi

a_copier=()
while IFS=$'\t' read -r depot deploye proprio mode apres; do
    [[ -z "$depot" || "$depot" == \#* ]] && continue
    if ! sudo -n test -f "$deploye"; then
        echo "=== NOUVEAU $deploye"
    elif ! sudo -n cat "$deploye" | cmp -s - "$depot"; then
        echo "=== CONTENU $deploye"
        sudo -n cat "$deploye" | diff -u --label "deploye" --label "depot" - "$depot"
    elif [[ "$(sudo -n stat -c '%U:%G %a' "$deploye")" != "$proprio $mode" ]]; then
        echo "=== DROITS  $deploye : $(sudo -n stat -c '%U:%G %a' "$deploye") -> $proprio $mode"
    else
        continue
    fi
    a_copier+=("$depot"$'\t'"$deploye"$'\t'"$proprio"$'\t'"$mode"$'\t'"$apres")
done < deploiement/deploiements.tsv

if [[ ${#a_copier[@]} -eq 0 ]]; then
    echo "Rien a deployer."
    exit 0
fi

echo
echo "${#a_copier[@]} fichier(s) a deployer depuis $(git rev-parse --short HEAD)."
if [[ $appliquer -eq 0 ]]; then
    echo "Simulation : relancer avec --appliquer pour ecrire."
    exit 0
fi

read -r -p "Deployer ? Taper « oui » : " reponse
[[ "$reponse" == "oui" ]] || { echo "Abandon."; exit 1; }

echo
for ligne in "${a_copier[@]}"; do
    IFS=$'\t' read -r depot deploye proprio mode apres <<< "$ligne"
    sudo -n install -o "${proprio%%:*}" -g "${proprio##*:}" -m "$mode" "$depot" "$deploye" || exit 1
    echo "copie    $deploye"
    echo "  apres : $apres"
done

echo
echo "Rappel : le scan AIDE de la nuit signalera les fichiers copies hors de"
echo "le dossier du depot. C'est la trace du deploiement, a lire comme telle."
echo
./derive.sh
