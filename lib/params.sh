#!/bin/bash
# lib/params.sh — one migration written down as a file (-f FILE).
#
# A run that works is twenty options long; retyping them is tedious and every
# retype is a chance to mistype one of them. The wizard prints this file, and
# a repeated or unattended run reads it. One "key=value" per line, no spaces
# around the '=', blank lines and lines starting with '#' ignored:
#
#   donor=root@192.168.1.111     # the source; an argument on the command line wins
#   disk=/dev/sda                # the target disk
#   step=plan                    # -s; default is the whole migration
#   yes=1                        # -y: never ask
#   dry=1                        # -n: print the commands, change nothing
#   key=/path/id_ed25519         # -i
#   mode=online                  # everything else is -o key=value
#   compress=zstd:3
#
# Sourced by bin/migrator BEFORE opt_check, so an unknown key in the file is
# refused there with the same near-miss hint a command line gets ("-o maxest"
# dies naming max-est) instead of being quietly ignored.
#
# Written to be readable by the operator who has to edit it at 3 a.m.: a line
# that is not key=value names its own line number.

pa_load() {   # pa_load FILE — fill DISK/STEP/YES/DRY/OPT from FILE
	local f=$1 line n=0 k v
	[ -n "$f" ] || die "$EX_ENV" "empty parameter file name"
	[ -r "$f" ] || die "$EX_ENV" "cannot read the parameter file: $f"
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		line=${line%$'\r'}                      # a file written on Windows
		case $line in ''|'#'*) continue ;; esac
		case $line in
			*=*) ;;
			*) die "$EX_ENV" "$f:$n: expected key=value, got '$line'" ;;
		esac
		k=${line%%=*}; v=${line#*=}
		k=${k//[[:space:]]/}                    # a stray space before the '='
		[ -n "$k" ] || die "$EX_ENV" "$f:$n: no key before '='"
		case $k in
			donor) PA_DONOR=$v ;;
			disk)  DISK=$v ;;
			step)  STEP=$v ;;
			key)   SSH_KEYFILE=$v ;;
			yes)   case $v in 0|no|false|'') ;; *) YES=y ;; esac ;;
			dry)   case $v in 0|no|false|'') ;; *) DRY=y ;; esac ;;
			*)     OPT[${k//_/-}]=$v ;;         # every other key is an -o
		esac
	done < "$f"
}

pa_dump() {   # pa_dump — the loaded settings as a parameter file, one per line
	# Sorted, so two dumps of the same run compare with diff: this is what
	# makes "the wizard printed it, I edited one line, I ran it again" safe.
	local k
	printf 'donor=%s\n' "${PA_DONOR:-}"
	printf 'disk=%s\n' "$DISK"
	[ -n "$STEP" ] && printf 'step=%s\n' "$STEP"
	[ -n "$SSH_KEYFILE" ] && printf 'key=%s\n' "$SSH_KEYFILE"
	[ -n "$YES" ] && printf 'yes=1\n'
	[ -n "$DRY" ] && printf 'dry=1\n'
	for k in $(printf '%s\n' "${!OPT[@]}" | LC_ALL=C sort); do
		printf '%s=%s\n' "$k" "${OPT[$k]}"
	done
	return 0
}
