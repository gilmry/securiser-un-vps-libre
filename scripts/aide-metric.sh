#!/bin/bash
# Expose le resultat du controle d'integrite AIDE au textfile collector de
# node-exporter, en ecartant le bruit des mises a jour de paquets.
#
# Ce script ne lance pas de scan : il LIT le rapport du run quotidien fait par
# le paquet AIDE (timer systemd dailyaidecheck sur Ubuntu). A lancer par cron,
# apres l'heure du scan (voir config/cron.d/durcissement.exemple).
#
# Pieges que ce script contourne :
#
#   1. Ne pas lire le code de sortie du service systemd : le wrapper du
#      paquet passe la sortie d'AIDE dans un pipe, et c'est le code du dernier
#      element du pipe qui remonte (0), meme quand AIDE trouve des differences.
#      On lit donc le code ecrit dans l'en-tete du rapport.
#
#   2. Le code brut ne distingue pas une mise a jour de paquet d'une
#      alteration. Sans filtrage, l'alerte est allumee plusieurs fois par
#      semaine, donc plus lue.
#
# Principe du filtrage : un chemin signale par AIDE est explique s'il
# appartient a un paquet ET que `dpkg --verify` de ce paquet ne le signale pas.
# Tout le reste reste un signal : fichier de paquet altere, fichier nouveau,
# fichier sans paquet. Le filtre ne peut qu'ecarter du bruit de mise a jour,
# jamais masquer un depot d'attaquant.
#
# Complements :
#   - un .pyc de __pycache__ n'appartient a aucun paquet (py3compile le
#     genere a l'installation) : il est rattache a son source .py ;
#   - un repertoire dont seuls mtime, ctime et inode bougent est ecarte :
#     c'est l'echo d'un ajout ou d'une suppression a l'interieur, qui a sa
#     propre entree si le fichier est surveille ;
#   - les fichiers qui changent seuls sans paquet doivent etre exclus du
#     perimetre AIDE, sinon ils ressortent tous « non expliques ». Voir
#     METHODE-EXCLUSIONS-AIDE.txt.
#
# Reserve connue : `dpkg --verify` separe ses champs par des espaces, donc un
# chemin de paquet contenant un espace serait mal decoupe. C'est rare, et
# l'erreur irait dans le sens permissif.
#
# Metriques exposees :
#   hardening_check_status{check="aide"}     code filtre : le signal d'alerte
#   hardening_check_raw_status{check="aide"} code brut d'AIDE, pour diagnostic
#   hardening_aide_unexplained_entries       chemins non expliques
#                                            (-1 = filtrage non applique)
#
# Codes : ceux d'AIDE (0 = rien de non explique, 1/2/4 = ajouts/suppressions/
# modifications et leurs sommes, >13 = erreur), plus 99 = resultat perime,
# illisible ou absent (le timer ne tourne plus).

set -uo pipefail

OUTDIR=${OUTDIR:-/var/lib/prometheus/node-exporter}
OUT="$OUTDIR/aide.prom"
TMP="$OUTDIR/.aide.prom.tmp"
LOG=${AIDE_LOG:-/var/log/aide/aide.log}
MAX_AGE=172800  # 48 h : deux cycles quotidiens manques
MAX_PATHS=5000  # au-dela on ne filtre pas : un evenement de cette taille
                # merite l'alerte. La vraie limite est ARG_MAX sur la ligne
                # de commande de `dpkg -S` (environ 2 Mo).
status=99
raw=99
unexplained=-1

if [ -r "$LOG" ]; then
    mtime=$(stat -c %Y "$LOG" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$mtime" -gt 0 ] && [ $((now - mtime)) -le "$MAX_AGE" ]; then
        # head : l'en-tete est en tete de fichier, et le rapport peut peser
        # plusieurs dizaines de Mo. Ne jamais lire au-dela.
        code=$(head -5 "$LOG" 2>/dev/null \
               | sed -n 's/^AIDE returned with exit code \([0-9]\{1,\}\).*/\1/p' \
               | head -1)
        # Un run en cours (en-tete ecrit, code pas encore) laisse code vide :
        # on garde 99, qui veut dire « je ne sais pas », pas « tout va bien ».
        if [ -n "$code" ]; then
            status="$code"
            raw="$code"
        fi
    fi
fi

[[ "$status" =~ ^[0-9]+$ ]] || status=99
[[ "$raw"    =~ ^[0-9]+$ ]] || raw=99

# Filtrage uniquement quand AIDE signale des differences (codes 1 a 7). Les
# codes >13 sont des erreurs d'execution, 0 n'a rien a filtrer et 99 est un
# angle mort : dans ces trois cas on ne touche a rien.
if [ "$status" -ge 1 ] && [ "$status" -le 7 ]; then
    # Les sections Added/Removed/Changed precedent « Detailed information
    # about changes », qui est la partie volumineuse du rapport.
    #
    # On ecarte au passage les repertoires dont SEULS mtime, ctime et inode
    # ont bouge. Un tel repertoire n'a pas ete modifie lui-meme : son horodatage
    # a suivi l'ajout ou la suppression d'un fichier a l'interieur. Si ce
    # fichier est dans le perimetre, AIDE le signale par sa propre entree et
    # rien n'est perdu ; s'il en est exclu, le mtime du parent n'est que
    # l'echo de ce qu'on a decide d'ignorer. Sans ce tri, quelques repertoires
    # systeme suffisent a garder l'alerte allumee chaque nuit.
    # Des qu'une permission, un proprietaire, une taille ou une somme de
    # controle bouge, la lettre correspondante apparait et l'entree est gardee.
    mapfile -t paths < <(
        awk '/^Detailed information about changes/ {exit}
             /^[fdlpcbs][^:]*: \// {
                 attrs = $0; sub(/: \/.*$/, "", attrs)
                 if (substr(attrs, 1, 1) == "d") {
                     reste = substr(attrs, 2)
                     gsub(/[=. mci]/, "", reste)
                     if (reste == "") next
                 }
                 chemin = $0; sub(/^[^:]*: /, "", chemin)
                 print chemin
             }' "$LOG" \
        | sort -u
    )

    # Nombre de lignes d'entree que le rapport contient, AVANT tout ecartement.
    # Il separe deux situations que le tableau vide confondait :
    #
    #   0 ligne lue           -> l'awk n'a rien su lire du rapport, on ne sait
    #                            pas ce qu'il contient : -1, le code brut alerte.
    #   N lues, 0 retenue     -> tout etait du bruit de repertoire, et il n'y a
    #                            donc rien a signaler : 0.
    #
    # Sans cette distinction, une nuit parfaitement propre (que du bruit de
    # repertoire) ressortirait en « format inattendu ».
    entrees=$(awk '/^Detailed information about changes/ {exit}
                   /^[fdlpcbs][^:]*: \// {n++}
                   END {print n+0}' "$LOG")
    [[ "$entrees" =~ ^[0-9]+$ ]] || entrees=0

    if [ "$entrees" -eq 0 ]; then
        unexplained=-1            # format inattendu : le code brut alerte
    elif [ "${#paths[@]}" -eq 0 ]; then
        unexplained=0             # que des repertoires ecartes : rien a signaler
        status=0
    elif [ "${#paths[@]}" -gt "$MAX_PATHS" ]; then
        unexplained=${#paths[@]}
    else
        # Les .pyc de __pycache__ n'appartiennent a aucun paquet : ils sont
        # produits par py3compile a l'installation, donc recompiles a chaque
        # mise a jour du paquet Python qui les porte.
        #
        # On remonte donc du .pyc a son source :
        #   <dir>/__pycache__/<nom>.cpython-3NN[.opt-N].pyc -> <dir>/<nom>.py
        # et on applique au source la meme regle qu'aux autres chemins : s'il
        # appartient a un paquet ET sort conforme de `dpkg --verify`, le .pyc
        # est la recompilation attendue de ce source. Un .pyc dont le source
        # n'appartient a aucun paquet, ou dont le source est altere, reste un
        # signal : le filtre ne relache rien sur le code Python lui-meme.
        declare -A source_py=()
        for p in "${paths[@]}"; do
            case "$p" in
                */__pycache__/*.pyc)
                    base=${p##*/}
                    base=${base%.pyc}
                    base=${base%.opt-[0-9]}
                    nom=${base%.cpython-*}
                    # Pas le schema attendu (pas de tag cpython) : on ne devine
                    # pas de source, l'entree reste non expliquee.
                    [ "$nom" = "$base" ] && continue
                    source_py["$p"]="${p%/__pycache__/*}/$nom.py"
                    ;;
            esac
        done

        # Les sources deduits entrent dans la meme interrogation dpkg que les
        # chemins signales : une seule passe, et `divergent` les couvre aussi.
        mapfile -t lookup < <(
            printf '%s\n' "${paths[@]}" ${source_py[@]+"${source_py[@]}"} | sort -u
        )

        declare -A owner=()
        while IFS= read -r line; do
            pkgs=${line%%: *}
            file=${line#*: }
            owner["$file"]=${pkgs%%,*}
        done < <(dpkg -S "${lookup[@]}" 2>/dev/null)

        declare -A divergent=()
        if [ "${#owner[@]}" -gt 0 ]; then
            mapfile -t pkglist < <(printf '%s\n' "${owner[@]}" | sort -u)
            while IFS= read -r vline; do
                vfile=${vline##* }
                [ -n "$vfile" ] && divergent["$vfile"]=1
            done < <(dpkg --verify "${pkglist[@]}" 2>/dev/null)
        fi

        unexplained=0
        for p in "${paths[@]}"; do
            if [ -n "${owner[$p]:-}" ] && [ -z "${divergent[$p]:-}" ]; then
                continue          # fichier de paquet conforme : mise a jour
            fi
            src=${source_py[$p]:-}
            if [ -n "$src" ] && [ -n "${owner[$src]:-}" ] \
               && [ -z "${divergent[$src]:-}" ]; then
                continue          # .pyc recompile depuis un source conforme
            fi
            unexplained=$((unexplained + 1))
        done

        [ "$unexplained" -eq 0 ] && status=0
    fi
fi

{
    printf 'hardening_check_status{check="aide"} %s\n' "$status"
    printf 'hardening_check_raw_status{check="aide"} %s\n' "$raw"
    printf 'hardening_aide_unexplained_entries %s\n' "$unexplained"
} > "$TMP"
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
