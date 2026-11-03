#!/bin/bash
# Functional tests for loginnode-notify with a fake ps, fake sendmail and fake
# ssh. Nothing leaves this directory.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
APP="$T/../loginnode-notify"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; mkdir -p "$W/state"
pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $*"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# fake sendmail: append the message to outbox; fail if FAIL_TO is in To:
cat > "$W/sendmail" <<'EOF'
#!/bin/bash
msg=$(cat)
if [ -n "${FAIL_TO:-}" ] && grep -q "^To: $FAIL_TO" <<< "$msg"; then echo "relay says no" >&2; exit 75; fi
printf '%s\n.MSGEND.\n' "$msg" >> "$OUTBOX"
echo "$*" >> "$OUTBOX.argv"
EOF
# fake ssh: swallow stdin (as real ssh does), answer `who` and `write`
cat > "$W/ssh" <<'EOF'
#!/bin/bash
while [[ "$1" == -* ]]; do [ "$1" = -o ] && shift; shift; done
host="$1"; shift
cat > /dev/null
case "$*" in
  who) printf 'alice pts/9 2026-10-30 10:00\nbob pts/8 2026-10-30 10:00\n' ;;
  write*) echo "$host $*" >> "$NUDGES" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$W/sendmail" "$W/ssh"
export OUTBOX="$W/outbox" NUDGES="$W/nudges"

grep -v -E '^(state_dir|etc_dir|sendmail|ssh|login_nodes|ldap_helper_dir|mail_from|reply_to|self_test_netid|signature) *=' "$T/../etc/notify.ini" > "$W/test.ini"
cat >> "$W/test.ini" <<EOF
state_dir = $W/state
etc_dir = $W/etc
sendmail = $W/sendmail
ssh = $W/ssh
login_nodes = $(hostname -s) othernode
ldap_helper_dir =
mail_from = sender@example.edu
reply_to = replies@example.edu
self_test_netid = tester
signature = Best,
    Tess
EOF
mkdir -p "$W/etc"
cp "$T/../etc/categories.tsv" "$W/etc/"
printf 'root\nstaff1\ncourse1_*\n' > "$W/etc/allowlist.txt"
printf 'dina\t2026-10-30\nivan  2026-10-30\n' > "$W/etc/excluded.txt"
printf 'gina\tYağız\n' > "$W/etc/names.tsv"
# addresses deliberately unlike <netid>@yale.edu; hank has none on purpose
printf 'tester\tme.self@example.edu\nalice\talice.a@example.edu\nbob\tbob.b@example.edu\nerin\terin.e@example.edu\ngina\tgina.g@example.edu\njudy\tjudy.j@example.edu\numa\tuma.u@example.edu\nvic\tvic.v@example.edu\nwes\twes.w@example.edu\ntom\ttom.t@example.edu\ncarol\tcarol.c@example.edu\ndora\tdora.d@example.edu\n' > "$W/etc/addresses.tsv"
printf '%s\tsomeoldrun\thank\tclaude\tsubj\tsent\tabc\n' "$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)" > "$W/state/notify.log"
printf '%s\tolderrun\tjudy\tclaude\tsubj\tsent\tabc\n' "$(date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)" >> "$W/state/notify.log"

cat > "$W/ps.txt" <<'EOF'
alice      1001    7200   500000 pts/1    node /home/alice/.local/bin/claude --resume
alice      1002    7200  3000000 ?        /home/alice/.vscode-server/bin/abc/node /home/alice/.vscode-server/bin/abc/out/server-main.js --port 0
bob        2001    4000   300000 pts/2    codex
carol      3001 3000000   900000 ?        /home/carol/.vscode-server/bin/x/node server-main.js
staff1     4001    9999   100000 pts/3    claude
course1_ab 4101    9999   100000 pts/3    codex
dina      5001    9999   100000 pts/4    codex
ivan       5101    9999   100000 pts/4    codex
dave       6001     100   100000 pts/5    claude
erin       7001    5000  3000000 pts/6    python big.py
frank      8001    5000      100 pts/7    vim notes.txt
gina       9001    5000   100000 pts/8    gemini
hank       9101    5000     1000 pts/9    claude
judy       9201    5000     1000 pts/9    claude
12345      9301    5000     1000 pts/9    claude
EOF

N() { /usr/bin/python3 "$APP" --config "$W/test.ini" "$@"; }
sent_to() { grep -c "^To: $1\.[a-z]@example.edu" "$OUTBOX" 2>/dev/null || true; }

echo "== check"
N check > "$W/check.out" 2>&1; check "check passes on fixed templates" grep -q '^OK' "$W/check.out"

echo "== detect"
N detect --ps-file "$W/ps.txt" > "$W/detect.out" 2>&1 || bad "detect exit"
run=$(cat "$W/state/current")
check "run recorded as current" test -f "$W/state/runs/$run/candidates.json"
for u in staff1 course1_ab dave frank 12345; do
  check "detect skips $u" bash -c "! grep -q '^$u ' '$W/detect.out'"
done
check "erin is heavy" grep -q '^erin .*heavy' "$W/detect.out"
check "alice has claude and ide rows" bash -c "[ \$(grep -c '^alice ' '$W/detect.out') = 2 ]"

echo "== review"
N review > "$W/review0.out" 2>&1
check "preview selects nothing" grep -q ', 0 selected' "$W/review0.out"
check "alice is ONE row with both categories" bash -c "[ \$(grep -c ' alice ' '$W/review0.out') = 1 ] && grep -q 'alice  *claude,ide' '$W/review0.out'"
check "carol stale" grep -q 'carol.*no: stale>30d' "$W/review0.out"
check "dina already-emailed (tab)" grep -q 'dina.*already-emailed' "$W/review0.out"
check "ivan already-emailed (spaces)" grep -q 'ivan.*already-emailed' "$W/review0.out"
check "hank in cooldown" grep -q 'hank.*cooldown' "$W/review0.out"
check "judy (30d ago) eligible again" grep -q 'judy.*eligible' "$W/review0.out"
N review --pick 1-99 > /dev/null 2>&1; check "out-of-range pick rejected" test $? -ne 0
N review --all --max-recipients 2 > "$W/r.out" 2>&1; check "cap enforced" grep -q 'cap is 2' "$W/r.out"
N review --all > "$W/review.out" 2>&1
check "--all selects the 5 eligible users" grep -q '5 eligible, 5 selected' "$W/review.out"

echo "== compose"
N compose > "$W/compose.out" 2>&1
D="$W/state/runs/$run/drafts"
check "one draft per user" bash -c "[ \$(ls '$D' | wc -l) = 5 ]"
check "alice gets claude template with both labels" grep -q 'noticed Claude Code and a VS Code server running' "$D/toalice"
check "fixed --time in agent template" grep -q 'salloc --partition=agent --mem=8G --time=8:00:00' "$D/toalice"
check "no -t= anywhere" bash -c "! grep -rq -- '-t=' '$D'"
check "UTF-8 override greeting" grep -q 'Dear Yağız,' "$D/togina"
check "greeting from directory or netID" grep -Eq 'Dear (Robert|bob),' "$D/tobob"
check "signature filled" bash -c "grep -q '^Tess$' '$D/tobob'"
echo "EDITED" >> "$D/tobob"
N compose > /dev/null 2>&1; check "compose keeps edited draft" grep -q EDITED "$D/tobob"
sed -i 's/^Subject:.*//' "$D/toerin"; sed -i '1{/^Reply-To/d}' "$D/toerin"; sed -i '1{/^$/d}' "$D/toerin"

echo "== send dry run"
N send > "$W/dry.out" 2>&1
check "dry run sends nothing" test ! -s "$OUTBOX"
check "dry run plans 5" grep -q 'dry run: 5 message' "$W/dry.out"

echo "== self-test"
N send --self-test --only alice --send --yes > /dev/null 2>&1
check "self-test goes to self_test_netid's directory address" grep -q '^To: me.self@example.edu' "$OUTBOX"
check "self-test sends nothing to alice" test "$(sent_to alice)" = 0
check "self-test subject names the real address" grep -q '^Subject: \[self-test for alice <alice.a@example.edu>\]' "$OUTBOX"
check "self-test logged as selftest" grep -q "	alice	.*	selftest	" "$W/state/notify.log"
: > "$OUTBOX"

N selftest --send --yes > /dev/null 2>&1
check "selftest command goes to the directory address" bash -c "grep -q '^To: me.self@example.edu' '$OUTBOX' && grep -q '^Subject: loginnode-notify transport test' '$OUTBOX'"
: > "$OUTBOX"

echo "== one real recipient, then the rest"
N send --only bob --send --yes > /dev/null 2>&1
check "bob sent once" test "$(sent_to bob)" = 1
FAIL_TO=erin.e@ N send --send --yes > "$W/send1.out" 2>&1; rc=$?
check "failure gives exit 1" test $rc = 1
check "failed erin not logged" bash -c "! grep -q '	erin	.*	sent	' '$W/state/notify.log'"
check "bob skipped on second send" grep -q 'bob .*already sent in this run' "$W/send1.out"
check "bob still received exactly once" test "$(sent_to bob)" = 1
for u in alice gina judy; do check "$u received exactly once" test "$(sent_to $u)" = 1; done
N send --send --yes > "$W/send2.out" 2>&1
check "retry delivers erin" test "$(sent_to erin)" = 1
N send --send --yes > "$W/send3.out" 2>&1
check "third send delivers nothing" grep -q 'nothing to send' "$W/send3.out"
for u in alice bob erin gina judy; do check "$u total exactly once" test "$(sent_to $u)" = 1; done
check "erin without Subject header gets default subject" bash -c "awk '/^To: erin.e@/,/MSGEND/' '$OUTBOX' | grep -q '^Subject: login node usage on Bouchet'"
check "UTF-8 charset header" bash -c "awk '/^To: gina.g@/,/MSGEND/' '$OUTBOX' | grep -qi 'charset=\"utf-8\"'"
check "Reply-To set" bash -c "awk '/^To: alice.a@/,/MSGEND/' '$OUTBOX' | grep -q '^Reply-To: replies@example.edu'"
check "sendmail called with -t -oi" bash -c "grep -q '^-t -oi' '$OUTBOX.argv'"
check "log has categories for alice" grep -q "	alice	claude,ide	" "$W/state/notify.log"

check "nothing ever sent to <netid>@yale.edu" bash -c "! grep -E '^To: (alice|bob|erin|gina|judy|hank)@' '$OUTBOX'"

echo "== a fresh run respects the cooldown"
N detect --ps-file "$W/ps.txt" > /dev/null 2>&1
N review --all > "$W/review2.out" 2>&1
check "new run selects nobody already mailed" grep -q ' 0 selected' "$W/review2.out"

echo "== write nudge does not eat the target list"
: > "$OUTBOX"
N review --all --ignore-cooldown > /dev/null 2>&1
run2=$(cat "$W/state/current")
N compose > /dev/null 2>&1
python3 - "$W/state/runs/$run2/targets.json" <<'EOF'
import json, sys
p = sys.argv[1]; t = json.load(open(p))
for r in t["users"]: r["hosts"] = ["othernode"]
json.dump(t, open(p, "w"))
EOF
N send --send --yes --write-nudge > "$W/nudge.out" 2>&1
check "all 5 with addresses sent with --write-nudge over ssh" test "$(grep -c '^To: ' "$OUTBOX")" = 5
check "hank (no address) skipped, not guessed" grep -q 'hank .*no email in the directory' "$W/nudge.out"
check "nudges went out via ssh" grep -q 'othernode write alice pts/9' "$NUDGES"

echo "== --all-nodes merges a failing remote gracefully"
N detect --all-nodes --ps-file "$W/ps.txt" > "$W/alln.out" 2>&1
check "failed remote reported" grep -q 'FAILED: othernode' "$W/alln.out"

echo "== directory lookup tolerates stray whitespace and missing entries"
# fake ldap_python: gets "-I -c CODE helper_dir netid...", answers like the
# real directory sometimes does (" someone@example.org", leading space)
cat > "$W/fakepy" <<'EOF'
#!/bin/bash
shift 4
printf '{'; sep=''
for u in "$@"; do
  case "$u" in nomail) printf '%s"%s": []' "$sep" "$u" ;; *) printf '%s"%s": [" %s.x@example.org "]' "$sep" "$u" "$u" ;; esac
  sep=', '
done
printf '}\n'
EOF
chmod +x "$W/fakepy"
{ grep -v -E '^ldap_(python|helper_dir) *=' "$W/test.ini"; printf 'ldap_python = %s\nldap_helper_dir = /unused\n' "$W/fakepy"; } > "$W/ldap.ini"
/usr/bin/python3 "$APP" --config "$W/ldap.ini" name kim nomail > "$W/name.out" 2>&1
check "leading/trailing space stripped from directory email" grep -q 'kim .* kim.x@example.org$' "$W/name.out"
check "user without mail reported, not guessed" grep -q 'nomail .*(no email)' "$W/name.out"

echo "== only the running program counts, not its arguments"
cat > "$W/ps2.txt" <<'EOF'
kate       1101    7200    5000 pts/1    tmux new -s claude
leo        1201    7200    5000 pts/1    vim CLAUDE.md
mia        1301    7200    5000 pts/1    screen -S codex
quinn      1401    7200    5000 ?        /bin/sh -c export PATH="$HOME/.local/bin:$PATH"; exec codex app-server
sam        1501    7200    5000 pts/1    rsync -a /home/sam/codex/ /scratch/sam/codex/
nick       2101    7200    5000 ?        /home/nick/.claude/remote/ccd-cli/2.1.308-3f6ee6c72f6a --model=claude-opus
olga       2201    7200    5000 pts/2    node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
pete       2301    7200    5000 pts/2    /home/pete/.local/share/claude/versions/2.1.302 --resume
rita       2401    7200    5000 ?        /usr/bin/python3 -m jupyterlab --no-browser
rob        2501    7200    5000 ?        /usr/bin/python3 /usr/local/bin/aws s3 sync /a s3://b
tom        2601    7200    5000 pts/3    npx -y @openai/codex
xena       2701    7200    5000 ?        /home/xena/.cursor-server/bin/linux-x64/0a1b/node /home/xena/.cursor-server/bin/linux-x64/0a1b/out/server-main.js
xena       2702    7200    5000 ?        /home/xena/.cursor-server/bin/linux-x64/0a1b/node /home/xena/.cursor-server/bin/linux-x64/0a1b/out/bootstrap-fork --type=extensionHost
yuri       2801    7200    5000 ?        /home/yuri/.vscode-server/cli/servers/Stable-0a1b/server/node /home/yuri/.vscode-server/cli/servers/Stable-0a1b/server/out/server-main.js
yara       2901    7200    5000 pts/4    cursor-agent
ulla       3001    7200    5000 pts/5    /usr/bin/find /gpfs/project -name *.h5
vera       3101    7200    5000 pts/5    du -sh /home/vera
walt       3201    7200    5000 pts/5    python3 find.py --all
xavi       3301    7200    5000 pts/5    vim find
yves       3401     300    5000 pts/5    find / -name core
EOF
N detect --ps-file "$W/ps2.txt" > "$W/detect2.out" 2>&1
check "second detect works" grep -q 'is now current' "$W/detect2.out"
N detect --ps-file "$W/ps2.txt" > "$W/detect3.out" 2>&1; N detect --ps-file "$W/ps2.txt" > "$W/detect4.out" 2>&1
check "back-to-back detects get distinct run ids" bash -c "[ \$(ls '$W/state/runs' | sort -u | wc -l) = \$(ls '$W/state/runs' | wc -l) ] && grep -q 'is now current' '$W/detect4.out'"
for u in kate leo mia quinn; do
  check "$u not flagged (agent name only in arguments)" bash -c "! grep -q '^$u ' '$W/detect2.out'"
done
check "sam's rsync is a transfer, not codex" grep -q '^sam .*io_transfer' "$W/detect2.out"
for u in nick olga pete; do check "$u flagged as Claude Code" grep -q "^$u .*claude" "$W/detect2.out"; done
check "python -m jupyterlab is ide_server" grep -q '^rita .*ide_server' "$W/detect2.out"
check "aws s3 is io_transfer" grep -q '^rob .*io_transfer' "$W/detect2.out"
check "npx @openai/codex is codex" grep -q '^tom .*codex' "$W/detect2.out"
check "Cursor server is ide, labelled Cursor" grep -q '^xena .* ide .* 2 .*a Cursor server' "$W/detect2.out"
check "VS Code server is ide, labelled VS Code" grep -q '^yuri .* ide .*a VS Code server' "$W/detect2.out"
check "cursor-agent is a coding agent, not ide" grep -q '^yara .*other_agent' "$W/detect2.out"
check "find is io_scan" grep -q '^ulla .*io_scan .*a long filesystem scan' "$W/detect2.out"
check "du is io_scan" grep -q '^vera .*io_scan' "$W/detect2.out"
check "a script named find.py is not a scan" bash -c "! grep -q '^walt ' '$W/detect2.out'"
check "find as an argument is not a scan" bash -c "! grep -q '^xavi ' '$W/detect2.out'"
check "a short find (< min_etime) is ignored" bash -c "! grep -q '^yves ' '$W/detect2.out'"

echo "== manual flags (add)"
N add io_heavy uma --note "In particular, an rsync of about 2 TB into /home." > "$W/add1.out" 2>&1
check "add prints the resolved address" grep -q 'uma .*io_heavy .*uma.u@example.edu' "$W/add1.out"
N add io_heavy vic,wes > /dev/null 2>&1
N add io_heavy tom --note "Also a lot of small-file I/O." > /dev/null 2>&1
N add io_heavy nobodyx > "$W/add2.out" 2>&1
check "add warns when there is no address" grep -q 'nobodyx .*NO EMAIL' "$W/add2.out"
N add bogus uma > "$W/add3.out" 2>&1; rc=$?
check "unknown category rejected" bash -c "[ $rc -ne 0 ] && grep -q \"unknown category 'bogus'\" '$W/add3.out'"
N add io_heavy nobodyx --remove > /dev/null 2>&1
N check > "$W/check2.out" 2>&1
check "check lists io_heavy as manual-only" grep -q 'manual-only: io_heavy' "$W/check2.out"
check "manual-only category is never detected" bash -c "! grep -q 'io_heavy' '$W/detect4.out'"
N review --all > "$W/review3.out" 2>&1
check "manual user shows as manual in review" grep -q ' uma .*io_heavy .*manual .*SELECTED' "$W/review3.out"
check "removed manual flag is gone" bash -c "! grep -q ' nobodyx ' '$W/review3.out'"
check "manual reason merged with detected one, manual first" grep -q ' tom .*io_heavy,codex' "$W/review3.out"
run3=$(cat "$W/state/current"); D3="$W/state/runs/$run3/drafts"
N compose > /dev/null 2>&1
check "io_heavy template used" grep -q '^Subject: heavy file I/O on the Bouchet login nodes' "$D3/touma"
check "note filled in" grep -q "$(hostname -s). In particular, an rsync of about 2 TB into /home." "$D3/touma"
check "empty note leaves a clean line" grep -q "^$(hostname -s)\.\$" "$D3/tovic"
check "no trailing whitespace in drafts" bash -c "! grep -q '[[:space:]]\$' '$D3'/to*"
check "no unfilled placeholders" bash -c "! grep -q '{{' '$D3'/to*"
check "io_scan template used, with the age" bash -c "grep -q '^Subject: long filesystem scan on the Bouchet login nodes' '$D3/toulla' && grep -q 'running for 2h00m' '$D3/toulla'"
check "merged user gets the manual template and both labels" bash -c "grep -q '^Subject: heavy file I/O' '$D3/totom' && grep -q 'Also a lot of small-file I/O.' '$D3/totom'"
N add io_heavy wes --remove > /dev/null 2>&1; N review > "$W/review4.out" 2>&1
check "add --remove takes a user out of the run" bash -c "! grep -q ' wes ' '$W/review4.out'"

echo "== stale cleanup notices (review --stale)"
{ cat "$W/ps.txt"; echo "dora       3101 4000000   900000 ?        /usr/bin/python3 -m jupyterlab --no-browser"; } > "$W/ps3.txt"
N detect --ps-file "$W/ps3.txt" > /dev/null 2>&1
run5=$(cat "$W/state/current")
N review > "$W/rs0.out" 2>&1
check "normal review points at --stale" grep -q 'have only stale servers.*review --stale' "$W/rs0.out"
N review --stale --include-stale > /dev/null 2>&1; rc=$?
check "--stale and --include-stale are exclusive" test $rc -ne 0
N review --stale --stale-days 60 --all > "$W/rs1.out" 2>&1
check "--stale-days raises the threshold" grep -q ' 0 selected' "$W/rs1.out"
N review --stale --all > "$W/rs2.out" 2>&1
check "stale VS Code user selected" grep -q ' carol .*ide .*SELECTED' "$W/rs2.out"
check "stale Jupyter user selected" grep -q ' dora .*ide_server .*SELECTED' "$W/rs2.out"
check "active users are not-stale in stale mode" grep -q ' bob .*no: not-stale' "$W/rs2.out"
check "stale mode is announced" grep -q 'STALE mode' "$W/rs2.out"
N compose > /dev/null 2>&1
S="$W/state/runs/$run5/drafts-stale"
check "stale drafts kept apart from normal drafts" bash -c "test -f '$S/tocarol' && test ! -e '$W/state/runs/$run5/drafts/tocarol'"
check "stale_ide template used" grep -q '^Subject: a VS Code server left running on the Bouchet login nodes' "$S/tocarol"
check "{{DAYS}} filled" grep -q 'running for about 34 days' "$S/tocarol"
H=$(hostname -s)
check "cleanup command goes to the right node" grep -qxF "    ssh $H 'pkill -u \$USER -f \"\\.(vscode|cursor)-server\"'" "$S/tocarol"
check "check command for the same node" grep -qxF "    ssh $H 'pgrep -u \$USER -fl \"\\.(vscode|cursor)-server\"'" "$S/tocarol"
check "generic stale.txt for other categories" bash -c "grep -q 'running for about 46 days' '$S/todora' && grep -qF 'ssh $H ps -u \$USER -o pid,etime,args' '$S/todora'"
check "no {{FOR_EACH_HOST}} or {{HOST}} left" bash -c "! grep -q '{{' '$S'/to*"
python3 - "$W/state/runs/$run5/targets.json" <<'EOF'
import json, sys
p = sys.argv[1]; t = json.load(open(p))
for r in t["users"]:
    if r["user"] == "carol": r["hosts"] = ["login1", "login2"]
json.dump(t, open(p, "w"))
EOF
N compose --force --only carol > /dev/null 2>&1
check "one cleanup line per host" bash -c "[ \$(grep -c \"^    ssh login[12] 'pkill\" '$S/tocarol') = 2 ] && [ \$(grep -c \"^    ssh login[12] 'pgrep\" '$S/tocarol') = 2 ]"
check "hosts listed in order" bash -c "grep -A1 \"^    ssh login1 'pkill\" '$S/tocarol' | grep -q \"^    ssh login2 'pkill\""
N send > "$W/ss0.out" 2>&1
check "stale dry run labels the notice" grep -q '===== carol \[stale:ide\]' "$W/ss0.out"
: > "$OUTBOX"
N send --send --yes > /dev/null 2>&1
check "stale notices delivered" bash -c "grep -q '^To: carol.c@example.edu' '$OUTBOX' && grep -q '^To: dora.d@example.edu' '$OUTBOX'"
check "logged as stale:<category>" bash -c "grep -q '	carol	stale:ide	' '$W/state/notify.log' && grep -q '	dora	stale:ide_server	' '$W/state/notify.log'"
N review --stale --all > "$W/rs3.out" 2>&1
check "stale users in cooldown after their notice" grep -q ' carol .*cooldown' "$W/rs3.out"

echo "== personal settings live in uncommitted local files"
printf '[notify]\nreply_to = local-replies@example.edu\n' > "$W/test.local.ini"
N check > "$W/local1.out" 2>&1
check "notify.local.ini overrides notify.ini" grep -q '^reply-to    local-replies@example.edu' "$W/local1.out"
rm "$W/test.local.ini"
printf 'bob\n' > "$W/etc/allowlist.local.txt"
N review > "$W/local2.out" 2>&1
check "allowlist.local.txt adds to the allowlist" grep -q ' bob .*no: allowlist' "$W/local2.out"
rm "$W/etc/allowlist.local.txt"
grep -v -E '^(mail_from|reply_to) *=' "$W/test.ini" > "$W/nofrom.ini"
USER=tester /usr/bin/python3 "$APP" --config "$W/nofrom.ini" check > "$W/local3.out" 2>&1
check "empty mail_from = your directory address" bash -c "grep -q '^from        me.self@example.edu' '$W/local3.out' && grep -q '^reply-to    me.self@example.edu' '$W/local3.out'"

echo "== replies (review --replies)"
check "sends log their Message-ID" bash -c "awk -F'\t' '\$6==\"sent\" && \$8 ~ /^<.+>\$/' '$W/state/notify.log' | grep -q ."
bobid=$(awk -F'\t' '$3=="bob" && $6=="sent" {id=$8} END {print id}' "$W/state/notify.log")
mkdir -p "$W/Replies.mbox"
/usr/bin/python3 - "$W/Replies.mbox/mbox" "$bobid" <<'EOF'
import mailbox, sys
from email.message import EmailMessage
box = mailbox.mbox(sys.argv[1])
def add(frm, date, irt=None):
    m = EmailMessage(); m["From"] = frm; m["To"] = "replies@example.edu"
    m["Subject"] = "Re: Claude Code on the Bouchet login nodes"
    if date: m["Date"] = date
    if irt: m["In-Reply-To"] = irt
    m.set_content("thanks, moving it now"); box.add(m)
add("Alice A <alice.a@example.edu>", "Sat, 01 Nov 2026 10:00:00 -0400")       # directory address
add("Alice A <alice.a@example.edu>", "Thu, 30 Oct 2026 09:00:00 -0400")       # older; latest wins
add("Robert <robert@elsewhere.org>", "Sun, 02 Nov 2026 12:00:00 -0500", sys.argv[2])  # answers bob's notice
add("Stranger <stranger@example.org>", "Sun, 02 Nov 2026 12:00:00 -0500")     # nobody we know
add("gina.g@example.edu", None)                                               # undated
box.flush()
EOF
N review --replies "$W/Replies.mbox" > "$W/rp1.out" 2>&1
check "reply from directory address -> replied, latest date" grep -q ' alice .*no: replied (2026-11-01)' "$W/rp1.out"
check "reply to a logged Message-ID from another address" grep -q ' bob .*no: replied (2026-11-02)' "$W/rp1.out"
check "undated reply still counts" grep -q ' gina .*no: replied (0000-00-00)' "$W/rp1.out"
check "users who did not write are unaffected" bash -c "! grep -q ' erin .*replied' '$W/rp1.out'"
check "summary counts the repliers" grep -q '3 user(s) here wrote to you (in Replies.mbox); 3 held back' "$W/rp1.out"
N review --replies "$W/Replies.mbox/mbox" --include-replied > "$W/rp2.out" 2>&1
check "--include-replied keeps the marker, not the hold" bash -c "grep -q ' alice .*cooldown.*\[replied 2026-11-01\]' '$W/rp2.out' && ! grep -q 'no: replied' '$W/rp2.out'"
printf '[notify]\nreplies_mbox = %s\n' "$W/Replies.mbox" > "$W/test.local.ini"
N review > "$W/rp3.out" 2>&1; N check > "$W/rp4.out" 2>&1
check "replies_mbox setting used without the flag" grep -q ' alice .*no: replied' "$W/rp3.out"
check "check shows the replies mbox" grep -q '^replies     .*Replies.mbox$' "$W/rp4.out"
printf '[notify]\nreplies_mbox = %s\n' "$W/nothere.mbox" > "$W/test.local.ini"
N check > "$W/rp5.out" 2>&1; rc=$?
check "check flags a missing replies mbox" bash -c "[ $rc -ne 0 ] && grep -q 'has no mbox' '$W/rp5.out'"
rm "$W/test.local.ini"
N review > "$W/rp6.out" 2>&1
check "without --replies nothing is held" bash -c "! grep -q 'replied' '$W/rp6.out'"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
