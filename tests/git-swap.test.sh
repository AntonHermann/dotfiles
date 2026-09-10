#!/bin/sh
# Testsuite fuer git-swap.  Jeder Fall laeuft in einem frischen Wegwerf-Repo.
#   sh tests/git-swap.test.sh
set -u

SWAP=${SWAP:-$(CDPATH= cd -- "$(dirname -- "$0")/../home/dot_local/bin" && pwd)/executable_git-swap}
[ -f "$SWAP" ] || { echo "git-swap nicht gefunden: $SWAP" >&2; exit 2; }

WORK=$(mktemp -d)
FAILLOG=$WORK/failures
: >"$FAILLOG"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

check() { # BESCHREIBUNG IST SOLL
	if [ "$2" = "$3" ]; then
		printf '    ok   %s\n' "$1"
	else
		printf '    FAIL %s\n' "$1"
		printf '         ist:  [%s]\n         soll: [%s]\n' "$2" "$3"
		echo "$1" >>"$FAILLOG"
	fi
}

newrepo() { # NAME
	d=$WORK/$1
	mkdir -p "$d"
	CDPATH= cd -- "$d" || exit 2
	git init -q .
	git config user.email test@example.com
	git config user.name Test
}

# "<index-tree> <arbeitsbaum-tree>" -- veraendert nichts
snap() {
	s=$(git stash create)
	if [ -z "$s" ]; then
		t=$(git rev-parse "HEAD^{tree}")
		echo "$t $t"
	else
		echo "$(git rev-parse "$s^2^{tree}") $(git rev-parse "$s^{tree}")"
	fi
}

swap() { "$SWAP" "$@" >"$WORK/out" 2>&1; }

run() { # NAME FUNKTION
	printf '  %s\n' "$1"
	( $2 ) || echo "$1: Abbruch im Testrumpf" >>"$FAILLOG"
}

# --- 1: disjunkte Dateien, der Alltagsfall ------------------------------
t_disjoint() {
	newrepo t1
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	echo 2 >a.txt; git add a.txt      # staged
	echo 2 >b.txt                     # unstaged
	before_work=$(snap | cut -d' ' -f2)
	swap; check "Exit-Code 0" "$?" 0
	check "a.txt im Index wieder wie HEAD" "$(git show :a.txt)" 1
	check "b.txt im Index geaendert" "$(git show :b.txt)" 2
	check "jetzt staged" "$(git diff --cached --name-only | tr '\n' ' ')" "b.txt "
	check "jetzt unstaged" "$(git diff --name-only | tr '\n' ' ')" "a.txt "
	check "Arbeitsbaum unveraendert" "$(snap | cut -d' ' -f2)" "$before_work"
}

# --- 2: gleiche Datei, disjunkte Hunks ----------------------------------
t_same_file() {
	newrepo t2
	printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' >f.txt; git add .; git commit -qm base
	sed -i 's/^2$/ZWEI/' f.txt; git add f.txt   # staged: Zeile 2
	sed -i 's/^9$/NEUN/' f.txt                  # unstaged: Zeile 9
	before_work=$(snap | cut -d' ' -f2)
	swap; check "Exit-Code 0" "$?" 0
	check "Index traegt nur den Zeile-9-Hunk" \
		"$(git show :f.txt | tr '\n' ' ')" "1 2 3 4 5 6 7 8 NEUN 10 "
	check "Arbeitsbaum unveraendert" "$(snap | cut -d' ' -f2)" "$before_work"
}

# --- 3: gleiche Datei, ueberlappende Hunks ------------------------------
t_overlap() {
	newrepo t3
	printf 'a\nb\nc\n' >f.txt; echo 1 >g.txt; git add .; git commit -qm base
	printf 'a\nB\nc\n' >f.txt; git add f.txt
	printf 'a\nBB\nc\n' >f.txt
	echo 2 >g.txt                     # disjunkt, unstaged
	before=$(snap)
	swap; check "Exit-Code 1 bei Konflikt" "$?" 1
	check "nichts veraendert" "$(snap)" "$before"
	check "Konfliktpfad genannt" \
		"$(grep -c 'f\.txt' "$WORK/out")" 1
	swap --partial; check "--partial Exit-Code 0" "$?" 0
	check "f.txt im Index unveraendert" "$(git show :f.txt | tr '\n' ' ')" "a B c "
	check "g.txt getauscht" "$(git show :g.txt)" 2
}

# --- 4: neu gestagete Datei, danach nochmal geaendert -------------------
t_staged_new() {
	newrepo t4
	echo 1 >a.txt; git add .; git commit -qm base
	printf 'A\n' >neu.txt; git add neu.txt
	printf 'A\nB\n' >neu.txt
	before=$(snap)
	swap
	rc=$?
	# "haenge B an" laesst sich nicht auf HEAD anwenden, wo die Datei fehlt:
	# der Tausch ist hier nicht darstellbar, Abbruch ist die richtige Antwort.
	check "Konflikt erkannt" "$rc" 1
	check "nichts veraendert" "$(snap)" "$before"
}

# --- 5: gestagetes Loeschen ---------------------------------------------
t_staged_delete() {
	newrepo t5
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	git rm -q a.txt                   # staged: geloescht
	echo 2 >b.txt                     # unstaged
	swap; check "Exit-Code 0" "$?" 0
	check "a.txt wieder im Index" "$(git show :a.txt)" 1
	check "a.txt im Arbeitsbaum weiterhin weg" "$(test -e a.txt && echo da || echo weg)" weg
	check "Loeschung ist jetzt unstaged" \
		"$(git diff --name-status -- a.txt)" "D	a.txt"
	check "b.txt jetzt staged" "$(git show :b.txt)" 2
}

# --- 6: gestagetes Umbenennen plus Inhaltsaenderung ---------------------
t_rename() {
	newrepo t6
	printf 'eins\nzwei\ndrei\n' >a.txt; git add .; git commit -qm base
	git mv a.txt a2.txt               # staged: Umbenennung
	sed -i 's/^zwei$/ZWEI/' a2.txt    # unstaged: Inhalt
	swap; check "Exit-Code 0" "$?" 0
	check "Index traegt a.txt mit neuem Inhalt" \
		"$(git show :a.txt 2>/dev/null | tr '\n' ' ')" "eins ZWEI drei "
	check "a2.txt nicht mehr im Index" \
		"$(git ls-files -- a2.txt)" ""
	# staged ist jetzt die Inhaltsaenderung an a.txt, unstaged die Umbenennung
	check "Inhaltsaenderung jetzt staged" \
		"$(git diff --cached --name-status)" "M	a.txt"
	check "a.txt im Arbeitsbaum weg" "$(git diff --name-status)" "D	a.txt"
	check "a2.txt untracked" "$(git status --short -- a2.txt)" "?? a2.txt"
}

# --- 7: Binaerdatei ------------------------------------------------------
t_binary() {
	newrepo t7
	printf '\000\001\002' >bin.dat; echo 1 >a.txt; git add .; git commit -qm base
	printf '\000\001\003' >bin.dat; git add bin.dat   # staged
	echo 2 >a.txt                                     # unstaged
	swap; check "Exit-Code 0" "$?" 0
	check "Binaerdatei wieder auf HEAD-Stand im Index" \
		"$(git show :bin.dat | od -An -tu1 | tr -s ' ')" " 0 1 2"
	check "Binaeraenderung jetzt unstaged" \
		"$(git diff --name-only | tr '\n' ' ')" "bin.dat "
}

# --- 8: Modewechsel ------------------------------------------------------
t_mode() {
	newrepo t8
	echo 1 >f.txt; echo 1 >g.txt; git add .; git commit -qm base
	chmod +x f.txt; git add f.txt     # staged: nur der Modus
	echo 2 >g.txt                     # unstaged
	swap; check "Exit-Code 0" "$?" 0
	check "Index hat wieder 100644" \
		"$(git ls-files --stage f.txt | cut -d' ' -f1)" 100644
	check "Modewechsel jetzt unstaged" \
		"$(git diff --name-only | tr '\n' ' ')" "f.txt "
}

# --- 9: sauberer Baum ----------------------------------------------------
t_clean() {
	newrepo t9
	echo 1 >a.txt; git add .; git commit -qm base
	before=$(snap)
	swap; check "Exit-Code 0" "$?" 0
	check "Meldung" "$(grep -c 'nichts zu tauschen' "$WORK/out")" 1
	check "nichts veraendert" "$(snap)" "$before"
}

# --- 10: doppelter Tausch = Identitaet ----------------------------------
t_involution() {
	newrepo t10
	printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' >f.txt
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	sed -i 's/^2$/ZWEI/' f.txt; echo 2 >a.txt; git add f.txt a.txt
	sed -i 's/^9$/NEUN/' f.txt; echo 2 >b.txt
	before=$(snap)
	swap; check "erster Tausch" "$?" 0
	check "Zustand hat sich geaendert" \
		"$(test "$(snap)" != "$before" && echo anders || echo gleich)" anders
	swap; check "zweiter Tausch" "$?" 0
	check "wieder der Ausgangszustand" "$(snap)" "$before"
}

# --- 11: untracked bleibt untracked -------------------------------------
t_untracked() {
	newrepo t11
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	echo 2 >a.txt; git add a.txt
	echo 2 >b.txt
	echo hallo >u.txt                 # untracked
	swap; check "Exit-Code 0" "$?" 0
	check "u.txt weiterhin untracked" \
		"$(git status --short -- u.txt)" "?? u.txt"
	check "u.txt inhaltlich unberuehrt" "$(cat u.txt)" hallo
}

# --- 12: --dry-run veraendert nichts ------------------------------------
t_dry_run() {
	newrepo t12
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	echo 2 >a.txt; git add a.txt
	echo 2 >b.txt
	before=$(snap)
	swap --dry-run; check "Exit-Code 0" "$?" 0
	check "nichts veraendert" "$(snap)" "$before"
	check "kein Backup-Ref angelegt" \
		"$(git for-each-ref --format='%(refname)' refs/git-swap/)" ""
	check "Vorschau zeigt b.txt als kuenftig staged" \
		"$(sed -n '/waere danach staged/,/^$/p' "$WORK/out" | grep -c 'b\.txt')" 1
}

# --- 13: Backup laesst sich zurueckspielen ------------------------------
t_backup() {
	newrepo t13
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	echo 2 >a.txt; git add a.txt
	echo 2 >b.txt
	before=$(snap)
	swap; check "Exit-Code 0" "$?" 0
	check "Backup-Ref angelegt" \
		"$(git for-each-ref --format='%(refname)' refs/git-swap/ | wc -l | tr -d ' ')" 1
	snapshot=$(sed -n 's/^rueckgaengig: git stash apply --index //p' "$WORK/out")
	git checkout -q -- . 2>/dev/null || true
	git reset -q --hard >/dev/null
	git stash apply --index "$snapshot" >/dev/null 2>&1
	check "Ausgangszustand wiederhergestellt" "$(snap)" "$before"
}

# --- 14: alte Backup-Refs werden abgeraeumt -----------------------------
t_prune() {
	newrepo t14
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	i=1
	while [ $i -le 12 ]; do
		git update-ref "refs/git-swap/backup-100000000$i" HEAD
		i=$((i + 1))
	done
	echo 2 >a.txt; git add a.txt
	echo 2 >b.txt
	swap; check "Exit-Code 0" "$?" 0
	check "es bleiben 10 Backups" \
		"$(git for-each-ref refs/git-swap/ | wc -l | tr -d ' ')" 10
	check "das neueste ist das aktuelle" \
		"$(git for-each-ref --format='%(refname)' --sort=-refname refs/git-swap/ |
			sed -n 1p | grep -c 'backup-1000000')" 0
	check "das aelteste ist weg" \
		"$(git for-each-ref --format='%(refname)' refs/git-swap/ |
			grep -c 'backup-1000000001$')" 0
}

# --- 15: zwei Tausche in derselben Sekunde ------------------------------
t_backup_collision() {
	newrepo t15
	echo 1 >a.txt; echo 1 >b.txt; git add .; git commit -qm base
	echo 2 >a.txt; git add a.txt
	echo 2 >b.txt
	swap; check "erster Tausch" "$?" 0
	swap; check "zweiter Tausch" "$?" 0
	check "beide Backups erhalten" \
		"$(git for-each-ref refs/git-swap/ | wc -l | tr -d ' ')" 2
}

echo "git-swap: $SWAP"
run "1  disjunkte Dateien"                 t_disjoint
run "2  gleiche Datei, disjunkte Hunks"    t_same_file
run "3  ueberlappende Hunks"               t_overlap
run "4  neu gestagete Datei"               t_staged_new
run "5  gestagetes Loeschen"               t_staged_delete
run "6  gestagetes Umbenennen"             t_rename
run "7  Binaerdatei"                       t_binary
run "8  Modewechsel"                       t_mode
run "9  sauberer Baum"                     t_clean
run "10 doppelter Tausch = Identitaet"     t_involution
run "11 untracked bleibt untracked"        t_untracked
run "12 --dry-run"                         t_dry_run
run "13 Backup zurueckspielen"             t_backup
run "14 alte Backups abraeumen"            t_prune
run "15 zwei Tausche, zwei Backups"        t_backup_collision

failures=$(wc -l <"$FAILLOG" | tr -d ' ')
echo
if [ "$failures" -eq 0 ]; then
	echo "alle Tests bestanden"
	exit 0
fi
echo "$failures fehlgeschlagen:"
sed 's/^/  /' "$FAILLOG"
exit 1
