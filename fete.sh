#!/bin/sh


set -eu
# shellcheck disable=SC3040 # now part of POSIX, but not everywhere yet!
if set -o | grep -q 'pipefail'; then set -o pipefail; fi

# Number of days around today to include in the calendar. Default is 7 (one week
# before and one week after today). When empty, the entire year is included.
: "${FETE_DAYS:="7"}"

# You (external) IP address. Will be guessed if not provided.
: "${FETE_IP:=""}"

# Key for your IP address, obtained from https://fetedujour.fr/api. Will be
# acquired if not provided.
: "${FETE_KEY:=""}"

# Base URL for FeteDuJour API (no version)
: "${FETE_DUJOUR_API:="https://fetedujour.fr/api"}"

# How to guess the IP address, can be "icanhazip" or "ifconfigme"
: "${FETE_IP_GUESS:="https://icanhazip.com"}"

# Language for entries in the calendar. Default is "fr-FR" (French), there is
# little point in changing this.
: "${FETE_LANGUAGE:="fr-FR"}"

# Verbosity level, can be increased with -v option
: "${FETE_VERBOSE:=0}"

usage() {
  # This uses the comments behind the options to show the help. Not extremely
  # correct, but effective and simple.
  echo "$0 generates ICS for surnames" && \
    grep "[[:space:]].)[[:space:]][[:space:]]*#" "$0" |
    sed 's/#//' |
    sed -E 's/([a-zA-Z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^FETE_' | sed 's/^FETE_/    FETE_/g'
  exit "${1:-0}"
}

# Parse named arguments using getopts
while getopts ":d:k:i:vh-" opt; do
  case "$opt" in
    d) # Number of days around today to include in the calendar. Empty means entire year.
      FETE_DAYS=$OPTARG;;
    k) # API key for your IP address. Will be acquired if not provided.
      FETE_KEY=$OPTARG;;
    i) # Your (external) IP address. Will be guessed if not provided.
      FETE_IP=$OPTARG;;
    v) # Increase verbosity each time repeated
      FETE_VERBOSE=$(( FETE_VERBOSE + 1 ));;
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
trace() { [ "$FETE_VERBOSE" -ge "2" ] && _log DBG "$@" || true ; }
info() { [ "$FETE_VERBOSE" -ge "1" ] && _log NFO "$@" || true ; }
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
  for i in $(seq 1 $1); do
    date -u -d "@$_secs" +"${3:-"%Y-%m-%d"}"
    _secs=$(( _secs + 86400 ))
  done
}


ics_line_endings() { tr -d '\r' | sed 's/$/\r/'; }


ics_localized() {
  if [ -n "$FETE_LANGUAGE" ]; then
    printf '%s;LANGUAGE=%s' "$1" "$FETE_LANGUAGE"
  else
    printf '%s' "$1" "$FETE_LANGUAGE"
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
PRODID:-//fetedujour.fr//Fetes ou Saints//FR
CALSCALE:GREGORIAN
METHOD:PUBLISH
X-WR-CALNAME:Fetes ou Saints
X-WR-CALDESC:Fetes ou Saints issues de fetedujour.fr
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
  tomorrow=$(date_span 1 "$today" "%Y-%m-%d %H:%M:%S" | tail -n1)

  # Generate the ICS entry
  cat <<EOF
BEGIN:VEVENT
CLASS:PUBLIC
UID:$(date -u -d "$today" +'%Y%m%d')-${month}-${day}@fetedujour.fr
DTSTAMP:$(date -u +'%Y%m%dT%H%M%SZ')
DTSTART;VALUE=DATE:$(date -u -d "$today" +'%Y%m%d')
RRULE:FREQ=YEARLY;INTERVAL=1;BYMONTH=$month;BYMONTHDAY=$day
X-MICROSOFT-CDO-ALLDAYEVENT:TRUE
$(printf '%s:Nous fêtons les "%s"' "$(ics_localized "SUMMARY")" "$name" | ics_fold)
STATUS:CONFIRMED
END:VEVENT
EOF
}


# Output ICS entries for all persons born on the given dates. Dates are read
# from stdin, one per line in YYYY-MM-DD format, as typically output by
# date_span or date_interval.
ics_entries() {
  while IFS= read -r d; do
    birthday=$(date -d "$d" +%d-%m)
    info "Getting name for birthday %s" "$birthday"
    name=$( run_curl "${FETE_DUJOUR_API%%/}/v2/${FETE_KEY}/json-normal-${birthday}" |
            jq -r '.name' || true )
    if [ -n "$name" ]; then
      ics_entry "$d" "$name"
    else
      warn "No name found for birthday %s" "$birthday"
    fi
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

# Acquire API key if not provided, this parses the HTML page so may break if the
# page layout changes.
if [ -z "$FETE_KEY" ]; then
  [ -z "$FETE_IP" ] && FETE_IP=$(run_curl "$FETE_IP_GUESS" | tr -d '\n')
  [ -z "$FETE_IP" ] && error "No IP address provided or found"

  FETE_KEY=$( run_curl -d "ip=${FETE_IP}" "${FETE_DUJOUR_API%%/}/#apiKey" |
              grep -F 'Voici votre clé' |
              grep -Eo '>[A-Za-z0-9]+<' |
              sed -E 's/>([A-Za-z0-9]+)</\1/' )
  [ -z "$FETE_KEY" ] && error "Could not obtain API key for IP address %s" "$FETE_IP"
  info "Obtained API key for IP %s: %s" "$FETE_IP" "$FETE_KEY"
fi

if [ -n "$FETE_DAYS" ] && [ "$FETE_DAYS" -gt 0 ]; then
  {
    ics_header
    date_span "$FETE_DAYS" | ics_entries
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
