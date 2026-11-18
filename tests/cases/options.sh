#!/bin/bash
# tests/cases/options.sh — the -o surface, in one place. The registry in
# lib/common.sh is the source of truth; this case keeps the usage header, the
# operator manual and the table on reloca.to from drifting away from it, and
# proves that a mistyped key is refused instead of being quietly ignored.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
M=$REPO/bin/reloca.to

# the registry: three lines in lib/common.sh, read without sourcing it
keys=$(sed -n 's/^RELOCA_OPTS_[A-Z]*="\(.*\)"$/\1/p' "$REPO/lib/common.sh" | tr ' ' '\n' | grep -c .)
assert_eq "the registry has three groups" 3 "$(grep -c '^RELOCA_OPTS_[A-Z]*=' "$REPO/lib/common.sh")"
if [ "$keys" -gt 30 ]; then _pass "the registry lists the options ($keys)"; else _fail "the registry lists the options" "only $keys"; fi
ALL=$(sed -n 's/^RELOCA_OPTS_[A-Z]*="\(.*\)"$/\1/p' "$REPO/lib/common.sh" | tr ' ' '\n' | grep . | LC_ALL=C sort)

# 1. no key is listed twice, and every key is one -o would accept
dups=$(echo "$ALL" | uniq -d)
assert_eq "no key appears in two groups" "" "$dups"
bad=$(echo "$ALL" | grep -v '^[a-z][a-z-]*$' || true)
assert_eq "every key is lowercase with hyphens" "" "$bad"

# 2. the usage header documents each of them (the terminal reference)
usage=$(bash "$M" -h 2>&1)
miss=
for k in $ALL; do case "$usage" in *"$k="*) ;; *) miss="$miss $k";; esac; done
assert_eq "reloca.to -h documents every key" "" "$miss"
assert_has "the usage header points at the full reference" "reloca.to/options/" "$usage"

# 3. the operator manual documents each of them (it is published at reloca.to
#    and kept out of the public tree, so this runs where the manual is)
if [ -r "$REPO/docs/reloca.to.md" ]; then
	miss=
	for k in $ALL; do grep -q "\`$k=\`" "$REPO/docs/reloca.to.md" || miss="$miss $k"; done
	assert_eq "docs/reloca.to.md documents every key" "" "$miss"
else
	skip "the manual documents every key" "no docs/reloca.to.md in this tree"
fi

# 4. the site's reference page carries exactly the same keys, no more, no less
if command -v python3 >/dev/null 2>&1 && [ -d "$REPO/site" ]; then
	site=$(python3 -c "import sys; sys.path.insert(0, '$REPO/site'); import options; print('\n'.join(sorted(r['k'] for r in options.ROWS)))")
	assert_eq "site/options.py lists exactly the registry" "$ALL" "$site"
	langs=$(python3 -c "
import sys; sys.path.insert(0, '$REPO/site'); import options
bad = [r['k'] for r in options.ROWS + options.FLAGS + options.STEPS if not all(r.get(l, '').strip() for l in ('en', 'uk', 'ru'))]
bad += [l for l in ('en', 'uk', 'ru') if set(options.PAGE[l]) != set(options.PAGE['en'])]
print(' '.join(bad))")
	assert_eq "every row of the reference is translated" "" "$langs"
else
	skip "the site reference matches the registry" "no site/ in this tree"
fi

# 5. keys are spelled with hyphens; an underscore is normalised, so a script
#    written before the spelling settled keeps working
out=$(bash "$M" -o max_est=600 -V 2>&1); rc=$?
assert_eq  "the underscore spelling still works" 0 "$rc"
bad=$(printf '%s\n' "$ALL" | grep '_' || true)
assert_eq  "no registry key spells itself with an underscore" "" "$bad"

# 6. a typo is refused, with the near miss named: "-o maxest=600" was accepted
#    once and did nothing, and the run then froze the donor for a window the
#    operator believed he had raised
out=$(bash "$M" -o maxest=600 -V 2>&1); rc=$?
assert_eq  "a mistyped -o key exits 2"      2 "$rc"
assert_has "it names the key"               "unknown option -o maxest" "$out"
assert_has "it names the near miss"         "did you mean max-est=" "$out"
assert_has "it points at the reference"     "reloca.to/options/" "$out"
out=$(bash "$M" -o nonsense=1 -V 2>&1); rc=$?
assert_eq  "a key nobody knows exits 2"     2 "$rc"
case "$out" in *"did you mean"*) _fail "no near miss is invented" "got: $out";; *) _pass "no near miss is invented";; esac
for k in $ALL; do
	out=$(bash "$M" -o "$k=1" -V 2>&1); rc=$?
	[ "$rc" = 0 ] || { _fail "-o $k=1 is accepted" "exit $rc: $out"; continue; }
done
_pass "every registry key is accepted by -o"

# 7. options are repeated, not joined by a comma: the comma belongs to the
#    value, so "-o compress=none,patience=600" would quietly set the compressor
#    to "none,patience=600"
out=$(bash "$M" -o compress=none,patience=600 -V 2>&1); rc=$?
assert_eq  "comma-joined options exit 2"    2 "$rc"
assert_has "the refusal splits them"        "use -o compress=none -o patience=600" "$out"
for v in driver=mpt3sas,virtio-scsi console=ttyS0,115200; do
	out=$(bash "$M" -o "$v" -V 2>&1); rc=$?
	assert_eq "a comma inside a value is fine ($v)" 0 "$rc"
done
out=$(bash "$M" -o compress=none -o patience=600 -V 2>&1); rc=$?
assert_eq  "two options, two -o"            0 "$rc"

# 8. the release notes at the bottom of the site: the newest entry is this
#    version, every entry is dated and translated, and the versions descend
if command -v python3 >/dev/null 2>&1 && [ -d "$REPO/site" ]; then
	out=$(python3 -c "
import re, sys; sys.path.insert(0, '$REPO/site'); import changelog
v = open('$REPO/VERSION').read().strip()
r = changelog.RELEASES
bad = []
if r[0]['v'] != v: bad.append('VERSION is %s but the newest entry is %s' % (v, r[0]['v']))
for e in r:
    if not re.match(r'^20[0-9][0-9]-[01][0-9]-[0-3][0-9]\$', e['date']): bad.append('%s: bad date %s' % (e['v'], e['date']))
    if len({len(e[l]) for l in ('en', 'uk', 'ru')}) != 1: bad.append('%s: the languages carry different notes' % e['v'])
    if not all(all(i.strip() for i in e[l]) for l in ('en', 'uk', 'ru')): bad.append('%s: an empty note' % e['v'])
ver = [tuple(int(x) for x in e['v'].split('.')) for e in r]
if ver != sorted(ver, reverse=True): bad.append('the releases are not newest first')
print('; '.join(bad))")
	assert_eq "the release notes match VERSION and are complete" "" "$out"
else
	skip "the release notes match VERSION" "no site/ in this tree"
fi

t_end
