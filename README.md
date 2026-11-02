# loginnode-notify

Asks users running login-node work (coding agents, VS Code/Cursor/Jupyter servers,
bulk transfers, memory hogs) to move it into a Slurm allocation. One Python
script, standard library only (`/usr/bin/python3`, 3.9 on Bouchet). Run it on a
login node.

```
detect   scan the login nodes, start a new run            read-only
review   one row per user; you choose who to contact      read-only
compose  one editable draft per selected user             writes drafts
send     deliver the drafts; dry run unless --send        SENDS MAIL
report   what a run selected and sent
```

## Typical session

```bash
cd ~/messagedir
./loginnode-notify check                      # config, sendmail, templates
./loginnode-notify detect --all-nodes         # new run, now "current"
./loginnode-notify review --only-category claude
./loginnode-notify review --only-category claude --pick 1,4,7-9   # or --all, or -i
./loginnode-notify add io_heavy jdoe --note "In particular, ..."   # flag by hand
./loginnode-notify review --pick 1,4          # manual flags show as 'manual'
./loginnode-notify compose                    # state/runs/<id>/drafts/to<netid>
$EDITOR state/runs/<id>/drafts/to*            # edit freely
./loginnode-notify send                       # dry run: prints every message
./loginnode-notify send --self-test --only jdoe --send   # jdoe's message, to you (self_test_netid)
./loginnode-notify send --only jdoe --send    # one real recipient
./loginnode-notify send --send                # the rest (jdoe is skipped)
./loginnode-notify report
./loginnode-notify log 30
./loginnode-notify recheck --all-nodes        # contacted users still at it
```

`detect` writes `state/current`; every other command uses that run unless you
pass `--run <id>`.

## Guarantees

- **Nobody is mailed twice by accident.** Right before delivering, `send`
  re-reads `state/notify.log` and skips anyone already sent in this run or
  within `cooldown_days` (any category). So `send --only X --send` followed by
  `send --send`, or a retry after a failure, mails each person once.
- **One message per person.** A user flagged for several things (e.g. Codex
  and a VS Code server) is one row in `review` and gets one email naming both.
  The template is that of their highest-priority category (order of
  `etc/categories.tsv`).
- **Nothing is selected by default**; `review` with no `--all`/`--pick`/`-i` is
  a preview. `send` without `--send` is a dry run; with `--send` it asks you to
  type `YES` unless you pass `--yes`.
- **Caps:** `max_recipients` (default 25) per review and per send; raise it
  for one invocation with `--max-recipients N`.
- **Failures are not logged as sent**, so a re-run picks them up.
- **Only the program counts.** Patterns match `argv[0]`, plus the script or
  module when `argv[0]` is an interpreter (`node .../cli.js`,
  `python -m jupyterlab`). Arguments are ignored, so `tmux new -s claude`,
  `vim CLAUDE.md` or `rsync ... codex/` never count as a coding agent.
- **No command lines are stored**, only the category, process count, oldest
  age, memory and up to 8 PIDs.
- `etc/allowlist.txt` and `etc/excluded.txt` are re-checked at send time too,
  so editing them after `review` still takes effect.
- **Recipients get the address YCRC has on file**, the `mail` attribute in the
  HPC directory (via `/apps/bin/ycrc_ldap.py`), not `<netid>@yale.edu`: Yale's
  Microsoft 365 silently drops netID addresses, and a bare netID only reaches
  people who have a `~/.forward`. `etc/addresses.tsv` (netID<TAB>address)
  overrides the directory; anyone without an address is skipped, never guessed.
  `names` shows the address each selected user will get.
- Mail is built with Python's `email` package (proper `Date`, `Message-ID`,
  UTF-8 charset) and handed to `sendmail -t -oi`.

## Files

```
loginnode-notify          the script (python3)
etc/notify.ini            login nodes, thresholds, cooldown, sendmail (shared defaults)
etc/notify.local.ini      your sender, reply-to, self-test netID, signature (overrides)
etc/categories.tsv        category <TAB> regex on the program (argv[0] + script) <TAB> label
etc/allowlist.txt         netIDs never reported (exact, or prefix*)
etc/allowlist.local.txt   more of them: your own and other staff netIDs
etc/excluded.txt          people already emailed by hand: netID [YYYY-MM-DD]
etc/names.tsv             optional greeting override: netID <TAB> name
etc/addresses.tsv         optional address override: netID <TAB> email
templates/<category>.txt  Subject/Reply-To headers, blank line, body
state/current             id of the current run
state/runs/<id>/          candidates.json, targets.json, drafts/to<netid>
state/notify.log          audit trail; drives cooldown and duplicate prevention
state/names.cache         netID -> directory name
test/run-tests.sh         functional tests (fake ps/sendmail/ssh; sends nothing)
```

**Not in git:** `etc/excluded.txt`, `etc/names.tsv`, `etc/addresses.tsv` and
`state/` hold data about cluster users, and `etc/notify.local.ini` and
`etc/allowlist.local.txt` hold yours, so `.gitignore` keeps them all out. A fresh
checkout works without them (mail then comes from your own directory address,
with no signature); copy the `etc/*.example` files to start them.

Runs made by the old bash pipeline (TSV files) are not readable by the new
script, but their sends are in `notify.log`, so cooldown still covers them.

## Review statuses

`eligible` · `allowlist` · `already-emailed` (excluded.txt) · `excluded`
(`--exclude`) · `cooldown (sent DATE)` · `category-filter` (`--only-category`) ·
`stale>30d` (VS Code/Cursor/Jupyter servers older than `stale_etime_days`: orphaned,
need a cleanup rather than an email; `--include-stale` overrides). A category in
parentheses after the user's categories, e.g. `codex (+ide)`, was filtered or
stale and is left out of the message.

Course accounts (`cpsc4880_*`, `gene7600_*`, ...) are shared logins whose mail
may not reach the person running the agent. Put the prefix in
`etc/allowlist.txt` to skip them.

## Cleanup notices for stale servers

VS Code/Cursor/Jupyter servers older than `stale_etime_days` (30) in
`stale_categories` are almost always left over from a disconnected session.
Normal review marks them `stale>30d` and does not select them. To ask those
people to clean up instead:

```bash
./loginnode-notify review --stale                 # only stale servers count now
./loginnode-notify review --stale --pick 2,5      # (--stale-days N to change the age)
./loginnode-notify compose                        # -> state/runs/<id>/drafts-stale/
./loginnode-notify send
```

Templates are `templates/stale_<category>.txt`, else `templates/stale.txt`:
`stale_ide.txt` gives the exact `pkill` for VS Code/Cursor servers plus a
`pgrep` check, each as `ssh <node> ...` for every node the user was seen on;
`stale.txt` a generic "find it with ps, kill it" (also per node) for the rest. `{{DAYS}}` is the age
in whole days. Stale drafts live in `drafts-stale/`, so they never replace a
normal draft of the same run; notify.log records them as `stale:<category>`,
and the usual cooldown, allowlist and one-notice-per-run rules apply.

## Flagging people by hand

`add CATEGORY NETID... [--note TEXT] [--host H]` puts users into the current run
for a reason detection cannot see, e.g. heavy I/O you spotted in `iotop`. They
then go through `review`/`compose`/`send` like everyone else (allowlist,
excluded.txt and cooldown still apply). `--note` fills `{{NOTE}}` in the
template, so you can say what you saw; `--remove` takes the flag back. A manual
reason comes first when a user is also detected for something else, so its
template and note are used.

Categories: `claude`, `codex`, `copilot`, `gemini`, `other_agent` (incl.
`cursor-agent`), `ide` (VS Code and Cursor remote servers; the email names
which), `ide_server` (Jupyter/RStudio), `io_transfer`, `io_scan` (long-running `find`,
`du`, `ncdu`, `gdu`, `fd`), `heavy`, and the manual-only `io_heavy`.

Manual-only reasons are lines in `etc/categories.tsv` with `-` as the regex,
like the shipped `io_heavy` (template `templates/io_heavy.txt`). To add another,
append e.g. `cpu_heavy<TAB>-<TAB>long CPU-heavy jobs` and a
`templates/cpu_heavy.txt` (or rely on `templates/default.txt`). Any detected
category can also be added by hand. Manual flags belong to one run, so add them
again after a new `detect`.

## Templates

Placeholders: `{{NAME}}` greeting name, `{{FULLNAME}}`, `{{USER}}`, `{{AGENT}}`
(what was seen, e.g. "Codex CLI and a VS Code server"), `{{HOSTS}}`,
`{{OLDEST}}`, `{{DAYS}}`, `{{PROCS}}`, `{{REPLY_TO}}`, `{{SUPPORT}}`, `{{SIGNATURE}}`, `{{NOTE}}`
(the `--note` of a manual flag; empty otherwise).

A line starting with `{{FOR_EACH_HOST}}` is repeated once per login node the
user was seen on, with `{{HOST}}` filled in. The stale templates use it so the
cleanup and check commands reach the right node however the person logged in:

```
{{FOR_EACH_HOST}}    ssh {{HOST}} 'pkill -u $USER -f "\.(vscode|cursor)-server"'
```
`check` flags unknown placeholders and missing Subject headers. If you change an
`salloc` line, check it is accepted before mailing it:

```bash
sbatch --test-only --partition=devel --cpus-per-task=4 --mem=8G --time=4:00:00 --wrap=true
```

(`devel` is capped at 6 h by its QOS; `agent` allows 7 days.)

## Names

`{{NAME}}` comes from `etc/names.tsv`, else `state/names.cache`, else
`finger <netid>` ("In real life:"), else `getent passwd`, else the netID (with a
warning). `./loginnode-notify names` shows what each selected user will be
called; `./loginnode-notify name NETID...` looks one up now. Delete a line from
`state/names.cache` to force a fresh lookup.

## Terminal nudge

`send --send --write-nudge` also `write`s a one-line note to each terminal the
user has on the hosts where they were seen (via ssh for other login nodes).
Best effort; needs `mesg y` on their side.

## Testing

```bash
bash test/run-tests.sh      # uses a scratch state dir and a fake sendmail
./loginnode-notify selftest          # preview a transport test to you
./loginnode-notify selftest --send   # post it (logged as selftest, no cooldown)
```
