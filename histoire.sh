#!/bin/sh


set -eu
# shellcheck disable=SC3040 # now part of POSIX, but not everywhere yet!
if set -o | grep -q 'pipefail'; then set -o pipefail; fi

# Root directory where this script is located
: "${HISTOIRE_ROOTDIR:="$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}"


# Number of days around today to include in the calendar. Default is 7 (one week
# before and one week after today). When empty, the entire year is included.
: "${HISTOIRE_DAYS:="7"}"

# Base URL for calagenanda
: "${HISTOIRE_DUJOUR_ROOT:="https://www.calagenda.fr/histoire-du-jour"}"

: "${HISTOIRE_HTML2TEXT:="html2text"}"

: "${HISTOIRE_BETWEEN:="${HISTOIRE_ROOTDIR%%/}/between.sh"}"

# Language for entries in the calendar. Default is "fr-FR" (French), there is
# little point in changing this.
: "${HISTOIRE_LANGUAGE:="fr-FR"}"

# Verbosity level, can be increased with -v option
: "${HISTOIRE_VERBOSE:=0}"

usage() {
  # This uses the comments behind the options to show the help. Not extremely
  # correct, but effective and simple.
  echo "$0 generates ICS with this day in history" && \
    grep "[[:space:]].)[[:space:]][[:space:]]*#" "$0" |
    sed 's/#//' |
    sed -E 's/([a-zA-Z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^HISTOIRE_' | sed 's/^HISTOIRE_/    HISTOIRE_/g'
  exit "${1:-0}"
}

# Parse named arguments using getopts
while getopts ":d:k:i:vh-" opt; do
  case "$opt" in
    d) # Number of days around today to include in the calendar. Empty means entire year.
      HISTOIRE_DAYS=$OPTARG;;
    v) # Increase verbosity each time repeated
      HISTOIRE_VERBOSE=$(( HISTOIRE_VERBOSE + 1 ));;
    h) # Show this help
      usage 0;;
    -) # Takes name of destination file as argument, empty or "-" means stdout
      break;;
    *)
      usage 1;;
  esac
done
shift $((OPTIND -1))


# PML: Poor Man's Logging on stderr
_log() {
  printf '[%s] [%s] [%s] ' \
    "$(basename "$0")" \
    "${1:-LOG}" \
    "$(date +'%Y%m%d-%H%M%S')" \
    >&2
  shift
  _fmt="$1"
  shift
  # shellcheck disable=SC2059 # ok, we want to use printf format
  printf "${_fmt}\n" "$@" >&2
}
trace() { [ "$HISTOIRE_VERBOSE" -ge "2" ] && _log DBG "$@" || true ; }
info() { [ "$HISTOIRE_VERBOSE" -ge "1" ] && _log NFO "$@" || true ; }
warn() { _log WRN "$@"; }
error() { _log ERR "$@" && exit 1; }


# Output a list of dates around a given date.
# $1: span in days
# $2: center date in a format recognized by -d, defaults to now
# $3: output date format, defaults to "%Y-%m-%d"
date_span() {
  # Default to now if no date given
  [ -z "${2:-}" ] && set -- "$1" "$(date -u +'%Y-%m-%d %H:%M:%S')"

  # Compute the "center" of the date span in seconds since epoch
  _now=$(date -u -d "$2" +%s)
  # Pick the span from the parameters.
  _span=$1
  # Compute the start date in seconds since epoch
  _start=$(( _now - _span * 86400 ))
  # How many days to output, i.e. the days before and after the center date,
  # including the center date.
  _days=$(( 1 + _span * 2))
  date_interval $_days "@$_start" "${3:-}"
}


# Output a list of dates starting from a given date.
# $1: number of days to output
# $2: start date in a format recognized by -d, defaults to now
# $3: output date format, defaults to "%Y-%m-%d"
date_interval() {
  # Default to now if no date given
  [ -z "${2:-}" ] && set -- "$1" "$(date -u +'%Y-%m-%d %H:%M:%S')"

  # Compute the start of the interval in seconds since epoch
  _secs=$(date -u -d "$2" +%s)
  # Output the dates in YYYY-MM-DD format
  for i in $(seq 1 "$1"); do
    date -u -d "@$_secs" +"${3:-"%Y-%m-%d"}"
    _secs=$(( _secs + 86400 ))
  done
}


all_events() {
  eng_daymonth=$(LC_ALL=C date -u -d "$1" +%d-%B)
  fr_daymonth=$(  printf %s\\n "$eng_daymonth" | \
                  sed -E 's/January/janvier/; s/February/février/; s/March/mars/; s/April/avril/; s/May/mai/; s/June/juin/; s/July/juillet/; s/August/août/; s/September/septembre/; s/October/octobre/; s/November/novembre/; s/December/décembre/' )
  _url="${HISTOIRE_DUJOUR_ROOT}-${fr_daymonth}.html"
  info "Downloading page for %s from %s" "$fr_daymonth" "$_url"
  tmp=$(mktemp)
  run_curl "$_url" |
    "${HISTOIRE_HTML2TEXT}" \
      --ignore-emphasis \
      --body-width 0 \
      --ignore-links \
      --ignore-mailto-links \
      --ignore-images \
      --ignore-tables \
      --unicode-snob \
      > "$tmp"
  trace "Downloaded page for %s to %s" "$fr_daymonth" "$tmp"

  "$HISTOIRE_BETWEEN" \
    -s '^[#]+ Les évènements du' \
    -e '^[0-9]+ évènements pour le' \
    "$tmp"

  outdir=$(mktemp -d)
  while IFS= read -r line || [ -n "${line:-}" ]; do
    if [ -n "$line" ]; then
      if printf %s\\n "$line" | grep -qE '^[#]+ '; then
        fname=$(printf '%s' "$line" | sed -E 's/^[#]+ //; s/ /-/g;').txt
      elif [ -n "$fname" ]; then
        printf '%s\n' "$line" >> "${outdir%%/}/$fname"
      fi
    fi
  done < "$tmp"

  rm -f "$tmp"
  info "Extracted events to %s" "$outdir"
  printf '%s\n' "$outdir"
}

random_number() {
  awk -v max="$1" 'BEGIN{srand(); print int(rand()*max)}'
}

choose_event() {
  _nfiles=$( find "$1" -type f -name '*.txt' | wc -l )
  _event=$( random_number "$_nfiles" )
  _i=0
  find "$1" -type f -name '*.txt' | while IFS= read -r f; do
    if [ "$_i" -eq "$_event" ]; then
      printf '%s\n' "$f"
      break
    fi
    _i=$(( _i + 1 ))
  done
}


ics_line_endings() { tr -d '\r' | sed 's/$/\r/'; }


ics_localized() {
  if [ -n "$HISTOIRE_LANGUAGE" ]; then
    printf '%s;LANGUAGE=%s' "$1" "$HISTOIRE_LANGUAGE"
  else
    printf '%s' "$1" "$HISTOIRE_LANGUAGE"
  fi
}


# Generate an ICS entry language parameter if a language is provided.
# $1: language code
ics_language() { [ -n "$1" ] && printf ';LANGUAGE:%s' "$1"; }


# Output ICS header
ics_header() {
  trace "Generating ICS header"
  cat <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//www.calagenda.fr//Ce jour dand l'histoire//FR
CALSCALE:GREGORIAN
METHOD:PUBLISH
X-WR-CALNAME:Ce jour dand l'histoire
X-WR-CALDESC:Un événement historique pour chaque jour de l'année issu de calagenda.fr
EOF
}


# Output ICS footer
ics_footer() {
  trace "Generating ICS footer"
  cat <<EOF
END:VCALENDAR
EOF
}

ics_fold() { fold -s -w 74 | sed 's/^/ /; 1s/^ //'; }

# Output an ICS entry for a given person file. Content will be pinpointed to the
# language if provided.
# $1: path to person file
ics_entry() {
  # Extract month and day from birthday to setup the yearly recurrence and when
  # the event starts and stops.
  month=$(date -u -d "$1" +%m)
  day=$(date -u -d "$1" +%d)
  today="$(date -u +%Y)-$month-$day 12:00:00"

  day=$(basename "$2")
  day=$(printf %s\\n "${day%%.txt}"| sed 's/-/ /g')

  # Generate the ICS entry
  cat <<EOF
BEGIN:VEVENT
CLASS:PUBLIC
UID:$(date -u -d "$today" +'%Y%m%d')-${month}-${day}@fetedujour.fr
DTSTAMP:$(date -u +'%Y%m%dT%H%M%SZ')
DTSTART;VALUE=DATE:$(date -u -d "$today" +'%Y%m%d')
RRULE:FREQ=YEARLY;INTERVAL=1;BYMONTH=$month;BYMONTHDAY=$day
X-MICROSOFT-CDO-ALLDAYEVENT:TRUE
$(printf '%s:%s' "$(ics_localized "SUMMARY")" "$day" | ics_fold)
$(printf '%s:%s' "$(ics_localized "DESCRIPTION")" "$(cat "$2")" | ics_fold)
STATUS:CONFIRMED
END:VEVENT
EOF
}


# Output ICS entries for all persons born on the given dates. Dates are read
# from stdin, one per line in YYYY-MM-DD format, as typically output by
# date_span or date_interval.
ics_entries() {
  while IFS= read -r d; do
    # Find all events for that date at the remove site, then pick one randomly
    _dir=$(all_events "$d")
    _evt=$(choose_event "$_dir")

    if [ -n "$_evt" ]; then
      ics_entry "$d" "$_evt"
    else
      warn "No event found for date %s" "$d"
    fi

    rm -rf "$_dir"
  done
}


# Silently download a file using curl
# $1: URL
# $2: output file (optional, default: basename of URL)
download() { run_curl -o "${2:-$(basename "$1")}" "$1"; }


# Wrapper around curl to add common options. No -f so that we can handle errors
# $@: curl arguments
run_curl() {
  curl -sSL --retry 5 --retry-delay 3 "$@"
}


# Silence the command passed as an argument.
silent() { "$@" >/dev/null 2>&1 </dev/null; }



# Verify required commands are available
silent command -v fold || error "fold command not found"
silent command -v jq || error "jq command not found"
[ -x "$HISTOIRE_BETWEEN" ] || error "between.sh script not found or not executable at %s" "$HISTOIRE_BETWEEN"
silent command -v "$HISTOIRE_HTML2TEXT" || error "%s command not found. See: %s" "$HISTOIRE_HTML2TEXT" "https://github.com/Alir3z4/html2text"

if [ -n "$HISTOIRE_DAYS" ] && [ "$HISTOIRE_DAYS" -gt 0 ]; then
  {
    ics_header
    date_span "$HISTOIRE_DAYS" | ics_entries
    ics_footer
  } | ics_line_endings
else
  {
    ics_header
    year=$(date +%Y)
    date_interval 365 "${year}-01-01 00:00:00" | ics_entries
    ics_footer
  } | ics_line_endings
fi
