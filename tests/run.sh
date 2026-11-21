#!/bin/bash
# tests/run.sh — the migrator test harness ("make test"). Seconds, no root.
#
#   1. shellcheck over bin/migrator, lib/*.sh, tools/*.sh, tests/*.sh and
#      tests/cases/*.sh (-x; -s bash, or -s sh for #!/bin/sh scripts such as
#      tools/install.sh, which is piped into sh on the Live). When the
#      linter is not installed this step is a loud SKIP, not a failure:
#      "make requirements" installs it.
#   2. every tests/cases/*.sh, each in its own process, with awk resolving to
#      mawk (the Live has no gawk; the build host has both) and RUN set to a
#      throwaway state dir, so a case can never touch /run/migrator.
#
# usage: tests/run.sh [CASE...]      CASE = file name without .sh; default: all
# Prints "== N cases, M assertions, F failures ==".
# exit: 0 green · 1 a shellcheck finding, a FAIL line or a crashed case · 2 harness cannot run
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u
REPO=$(readlink -f "$(dirname "$0")/..")
cd "$REPO" || exit 2
shopt -s nullglob

# /tmp on the build host is a small tmpfs shared with the stands; /var/tmp is not.
# A host without /var/tmp (Git Bash) falls back to TMPDIR so the suite still runs.
TMP=$(mktemp -d /var/tmp/xslive-migrator-test.XXXXXX 2>/dev/null) ||
	TMP=$(mktemp -d "${TMPDIR:-/tmp}/xslive-migrator-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
FAILED=0

# --- 1. shellcheck ------------------------------------------------------------
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
	bash_files=(); sh_files=()
	for f in bin/migrator lib/*.sh tools/*.sh tests/*.sh tests/cases/*.sh; do
		if head -1 "$f" | grep -q '/bin/sh$'; then sh_files+=("$f"); else bash_files+=("$f"); fi
	done
	rc=0
	shellcheck -x -s bash "${bash_files[@]}" || rc=1
	[ ${#sh_files[@]} -eq 0 ] || shellcheck -x -s sh "${sh_files[@]}" || rc=1
	if [ $rc -eq 0 ]; then echo "  PASS shellcheck (${#bash_files[@]} bash + ${#sh_files[@]} sh files)"
	else echo "  FAIL shellcheck"; FAILED=1; fi
else
	echo "  SKIP shellcheck (not installed: run 'make requirements')"
fi

# --- 2. table tests -----------------------------------------------------------
# The cases see the Live's awk: a bin dir where awk -> mawk goes first on PATH.
mkdir "$TMP/bin"
if command -v mawk >/dev/null 2>&1; then
	ln -s "$(command -v mawk)" "$TMP/bin/awk"
	AWK_NOTE=mawk
else
	echo "  WARN mawk is not installed: cases run with $(command -v awk), which is not what the Live has"
	AWK_NOTE="$(basename "$(readlink -f "$(command -v awk)")") (mawk missing!)"
fi

cases=()
if [ $# -gt 0 ]; then
	for c in "$@"; do
		[ -r "tests/cases/$c.sh" ] || { echo "no such case: tests/cases/$c.sh"; exit 2; }
		cases+=("tests/cases/$c.sh")
	done
else
	cases=(tests/cases/*.sh)
fi

N=0; PASS=0; FAIL=0; SKIP=0
for c in "${cases[@]}"; do
	name=$(basename "$c" .sh)
	echo "== $name =="
	N=$((N+1))
	mkdir -p "$TMP/run-$name"
	RUN="$TMP/run-$name" AWK=mawk PATH="$TMP/bin:$PATH" bash "$c" 2>&1 | tee "$TMP/out-$name"
	rc=${PIPESTATUS[0]}
	p=$(grep -c '^  PASS ' "$TMP/out-$name"); f=$(grep -c '^  FAIL ' "$TMP/out-$name"); s=$(grep -c '^  SKIP ' "$TMP/out-$name")
	PASS=$((PASS+p)); FAIL=$((FAIL+f)); SKIP=$((SKIP+s))
	# a case that dies without a FAIL line (syntax error, die outside a subshell) is still a failure
	if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then echo "  FAIL $name crashed (exit $rc)"; FAIL=$((FAIL+1)); fi
	[ "$rc" -eq 0 ] || FAILED=1
done

echo "== $N cases, $((PASS+FAIL)) assertions, $FAIL failures == (skipped: $SKIP, awk: $AWK_NOTE)"
[ "$FAIL" -eq 0 ] || FAILED=1
exit $FAILED
