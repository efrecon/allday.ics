#!/bin/sh

set -eu
# shellcheck disable=SC3040 # now part of POSIX, but not everywhere yet!
if set -o | grep -q 'pipefail'; then set -o pipefail; fi

# Regular expression to match the line(s) to start extraction at
: "${BETWEEN_START:=""}"

# Regular expression to match the line(s) to stop extraction at
: "${BETWEEN_END:=""}"

# Keep the matching start and end lines during extraction
: "${BETWEEN_KEEP:="0"}"

# Path to a file that contains the lines that are NOT in the sections to extract
# (will be truncated ONCE)
: "${BETWEEN_EXEMPT:=""}"

# Level of verbosity, the higher the more verbose. All messages are sent to the
# stderr.
: "${BETWEEN_VERBOSE:=0}"

usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "$0 keeps the lines between a start and end patterns only in files passed as parameters" && \
    grep "[[:space:]].)[[:space:]][[:space:]]*#" "$0" |
    sed 's/#//' |
    sed -E 's/([a-zA-Z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^BETWEEN_' | sed 's/^BETWEEN_/    BETWEEN_/g'
  exit "${1:-0}"
}

while getopts "e:ks:x:vh-" opt; do
  case "$opt" in
    v) # Increase verbosity, will otherwise log on errors/warnings only
      BETWEEN_VERBOSE=$((BETWEEN_VERBOSE+1));;
    h) # Print help and exit
      usage;;
    k) # Keep the start and end lines
      BETWEEN_KEEP=1;;
    s) # Pattern (regex, case insensitive) to match the line to start at
      BETWEEN_START="$OPTARG";;
    e) # Pattern (regex, case insensitive) to match the line to end at
      BETWEEN_END="$OPTARG";;
    x) # Path to a file that contains the lines that are NOT in the sections to extract (will be truncated ONCE)
      BETWEEN_EXEMPT="$OPTARG";;
    -) # End of options, everything after are path to files to process
      break;;
    ?)
      usage 1;;
  esac
done
shift $((OPTIND-1))

# PML: Poor Man's Logging
_log() {
  printf '[%s] [%s] [%s] %s\n' \
    "$(basename "$0")" \
    "${2:-LOG}" \
    "$(date +'%Y%m%d-%H%M%S')" \
    "${1:-}" \
    >&2
}
trace() { if [ "${BETWEEN_VERBOSE:-0}" -ge "3" ]; then _log "$1" TRC; fi; }
debug() { if [ "${BETWEEN_VERBOSE:-0}" -ge "2" ]; then _log "$1" DBG; fi; }
verbose() { if [ "${BETWEEN_VERBOSE:-0}" -ge "1" ]; then _log "$1" NFO; fi; }
warn() { _log "$1" WRN; }
error() { _log "$1" ERR && exit 1; }

if [ -z "$BETWEEN_START" ]; then
  error "No pattern to match the line to start at, run with -h for help"
fi

# Truncate the file containing the lines to exempt, if relevant
truncate_exempt() {
  if [ -n "$BETWEEN_EXEMPT" ] && [ "$BETWEEN_EXEMPT" != "-" ] && [ -f "$BETWEEN_EXEMPT" ]; then
    printf '' > "$BETWEEN_EXEMPT"
    warn "Truncated $BETWEEN_EXEMPT"
  fi
}

# Run the command passed as a parameter and redirect its output to the file
# containing the exempt lines. Force doing this in a subshell to be able to exec
# the command (parenthesis in function block)
exempt_output() (
  if [ -n "$BETWEEN_EXEMPT" ]; then
    if [ "$BETWEEN_EXEMPT" = "-" ]; then
      exec "$@"
    else
      exec "$@" >> "$BETWEEN_EXEMPT"
    fi
  fi
)

# Perform section extraction in the file passed as a parameter. This will write
# the lines not in the section in the exempt file if relevant.
between_patterns() {
  start=$(grep -inE "$BETWEEN_START" "$1" | head -n 1 | cut -f1 -d:)
  if [ -z "$start" ]; then
    warn "No line matching the start pattern $BETWEEN_START in $1"
    exempt_output cat "$1"
    return
  else
    verbose "Found start pattern '$BETWEEN_START' in '$1' at line $start"
    section=$(mktemp); # Create a temporary file to store the subsection
    if [ "$BETWEEN_KEEP" = 1 ]; then
      tail -n +"$start" "$1" > "$section"
      if [ "$start" -gt 1 ]; then
        exempt_output head -n "$((start-1))" "$1"
      fi
    else
      tail -n +"$((start+1))" "$1" > "$section"
      exempt_output head -n "$start" "$1"
    fi

    if [ -n "$BETWEEN_END" ]; then
      verbose "Searching for end pattern in $1"
      end=$(grep -inE "$BETWEEN_END" "$section" | head -n 1 | cut -f1 -d:)
      if [ -n "$end" ]; then
        verbose "Found end pattern '$BETWEEN_END' in '$1' at line ${start}+${end}"

        if [ "$BETWEEN_KEEP" = 1 ]; then
          exempt_output tail -n +"$((end+1))" "$section"
          head -n "$end" "$section" > "$1"
        else
          exempt_output tail -n +"$end" "$section"
          head -n "$((end-1))" "$section" > "$1"
        fi
      else
        cat "$section" > "$1"
      fi
    else
      verbose "No end pattern, keeping until the end of $1"
      cat "$section" > "$1"
    fi
    rm -f "$section"
  fi
}

if [ "$#" = 0 ]; then
  if [ -t 0 ]; then
    error "No files to process, run with -h for help"
  else
    # Use a temporary file to process the content of stdin
    tmp=$(mktemp)
    cat > "$tmp"
    truncate_exempt
    between_patterns "$tmp"
    cat "$tmp"
    rm -f "$tmp"
  fi
else
  truncate_exempt
  while [ "$#" != 0 ]; do
    between_patterns "$1"
    shift
  done
fi
