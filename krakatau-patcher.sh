#!/usr/bin/env bash
set -euo pipefail
trap 'exit 8' INT

# -- Search for dependencies (or crash)
AWK=${AWK:-$(which awk)}
CAT=${CAT:-$(which cat)}
CMP=${CMP:-$(which cmp)}
DIFF=${DIFF:-$(which diff)}
DIRNAME=${DIRNAME:-$(which dirname)}
FIND=${FIND:-$(which find)}
KRAK=${KRAK:-$(which krak2)}
MKDIR=${MKDIR:-$(which mkdir)}
MKTEMP=${MKTEMP:-$(which mktemp)}
PATCH=${PATCH:-$(which patch)}
REALPATH=${REALPATH:-$(which realpath)}
RM=${RM:-$(which rm)}
RSYNC=${RSYNC:-$(which rsync)}
TEE=${TEE:-$(which tee)}
UNZIP=${UNZIP:-$(which unzip)}
ZIP=${ZIP:-$(which zip)} # Info-ZIP one
[ -n "${TESTING_DEPS:-}" ] && PATH=""

# -- Error enum
ERR_NO_CHANGES=1
ERR_INTERRUPT=8
ERR_WRONG_USAGE=10
ERR_UNZIP_FAILED=11
ERR_DIFF_FAILED=12
ERR_PATCH_FAILED=13
ERR_ZIP_FAILED=14
ERR_ORIGINAL_NOT_FILE=20
ERR_ORIGINAL_INVALID_EXT=21
ERR_ORIGINAL_WITHOUT_CLASSES=22
ERR_EDITED_NOT_DIRECTORY=30
ERR_EDITED_WITHOUT_CLASSES=31
ERR_PATCH_NOT_FILE=40
ERR_PATCH_WITHOUT_FILES=41

# -- Options
VERBOSITY="${VERBOSITY:-0}"
KRAK_MODE="${KRAK_MODE:---roundtrip}"
DIFF_OPTS="${DIFF_OPTS:--rNu}"

# -- Functions
function err() {
  if [ "$VERBOSITY" -lt '1' ]
  then $CAT > /dev/null
  else $CAT > /dev/stderr
  fi
}
function pfx_err() {
  $AWK '{print "Error:\n  "$0"\n"}' | err
}
function debug() {
  if [ "$VERBOSITY" -lt '2' ]
  then $CAT > /dev/null
  else $CAT > /dev/stderr
  fi
}

function show_usage() {
  err << HERE
Usage:
  $0 diff [original-file] [edited-directory] > bundle.patch
  $0 patch [original-file] bundle.patch > [output-file]

Options:
  [original-file]:
    Original ".jar" file.
  [edited-directory]:
    Directory with the edited files, same structure as the JAR when unziped.
  [output-file]:
    Patched ".jar" file.
HERE
}

function critical_usage() {
  show_usage
  return $ERR_WRONG_USAGE
}

function check_original_file() {
  debug <<< "** Checking original file \"$1\""

  if ! [ -f "$1" ]; then
    pfx_err <<< "\"$1\" is not a file."
    show_usage
    return $ERR_ORIGINAL_NOT_FILE
  fi

  case "${1:(-4)}" in
    ".jar")
      echo "jar"
      ;;
    ".zip")
      echo "zip"
      ;;
    *)
    pfx_err <<< "\"$1\" neither ends in \".jar\" nor \".zip\"."
    show_usage
    return $ERR_ORIGINAL_INVALID_EXT
    ;;
  esac
}

function diff() {
  [ $# -eq 2 ] || critical_usage

  ORIGINAL_EXT=$(check_original_file "$1")

  debug <<< "** Searching edited directory"

  if ! [ -d "$2" ]; then
    pfx_err <<< "\"$2\" is not a directory."
    show_usage
    return $ERR_EDITED_NOT_DIRECTORY
  fi

  readarray -t EDITED_CLASSES < <($FIND "$2" -type f -name '*.class' -printf '%P\n')
  debug <<< "Found edited classes: ${EDITED_CLASSES[@]}"

  readarray -t EDITED_FILES < <($FIND "$2" -type f -not -name '*.class' -printf '%P\n')
  debug <<< "Found other edited files: ${EDITED_FILES[@]}"

  if [ "${#EDITED_CLASSES[@]}" -eq 0 ]; then
    pfx_err <<< "\"$2\" does not contain \".class\" files."
    show_usage
    return $ERR_EDITED_WITHOUT_CLASSES
  fi

  WORKDIR=$($MKTEMP -d --suffix="kdiff")
  debug <<< "** Working in $WORKDIR"

  $MKDIR "$WORKDIR/"{a,b}

  debug <<< "** Unzipping original jar"
  if ! $UNZIP -n "$1" -d "$WORKDIR/a/" 2>&1 | err; then
    pfx_err <<< "Unable to unzip \"$1\""
    return $ERR_UNZIP_FAILED
  fi

  debug <<< "** Searching unziped directory"
  readarray -t ORIGINAL_CLASSES < <($FIND "$WORKDIR/a/" -type f -name '*.class' -printf '%P\n')
  debug <<< "Found edited classes: ${ORIGINAL_CLASSES[@]}"

  if [ "${#ORIGINAL_CLASSES[@]}" -eq 0 ]; then
    pfx_err <<< "\"$1\" does not contain \".class\" files."
    show_usage
    return $ERR_ORIGINAL_WITHOUT_CLASSES
  fi

  if [ "${#EDITED_FILES[@]}" -gt 0 ]; then
    debug <<< "** Copying other files"
    (cd "$2"; $RSYNC -vR "${EDITED_FILES[@]}" -d "$WORKDIR/b" 2>&1 | err)
  fi

  TMP_WORKCLASS="$WORKDIR/work.class"
  debug <<< "** Looping through edited classes"
  for CLASS in "${EDITED_CLASSES[@]}"; do
    [ -f "$WORKDIR/a/$CLASS" ] && ($CMP "$2/$CLASS" "$WORKDIR/a/$CLASS" | err) && continue
    $MKDIR -p "$WORKDIR/b/$($DIRNAME "$CLASS")"
    $KRAK dis --out "$WORKDIR/b/${CLASS%.class}.j" $KRAK_MODE "$2/$CLASS" 2>&1 | err
  done

  debug <<< "** Looping through original classes"
  for CLASS in "${ORIGINAL_CLASSES[@]}"; do
    if ! ([ -f "$2/$CLASS" ] && ($CMP "$2/$CLASS" "$WORKDIR/a/$CLASS" | err)); then
      $KRAK dis --out "$WORKDIR/a/${CLASS%.class}.j" $KRAK_MODE "$WORKDIR/a/$CLASS" 2>&1 | err
    fi
    $RM "$WORKDIR/a/$CLASS"
  done

  debug <<< "** Generating patch"

  if ! (cd "$WORKDIR"; ($DIFF $DIFF_OPTS a b || [ $? -lt 2 ]) | $TEE bundle.patch); then
    pfx_err <<< "DIFF exit code returned an error code."
    return $ERR_DIFF_FAILED
  fi

  if [ -s "$WORKDIR/bundle.patch" ]; then
    debug <<< "** Finished successfully!"
    $RM -r "$WORKDIR"
    debug <<< "** Cleaned!"
    return 0
  else
    pfx_err <<< "No changes to report."
    return $ERR_NO_CHANGES
  fi
}

function patch() {
  [ $# -eq 2 ] || critical_usage

  ORIGINAL_EXT=$(check_original_file "$1")

  debug <<< "** Searching edited directory"

  if ! [ -f "$2" ]; then
    pfx_err <<< "\"$2\" is not a file."
    show_usage
    return $ERR_PATCH_NOT_FILE
  fi

  readarray -t INTERESTING_FILES < <($AWK '/--- a\//{gsub(/^a\//, "",$2); print $2}' "$2")
  debug <<< "Found interesting files: ${INTERESTING_FILES[@]}"

  if [ "${#INTERESTING_FILES[@]}" -eq 0 ]; then
    pfx_err <<< "\"$2\" does not patch files."
    show_usage
    return $ERR_PATCH_WITHOUT_FILES
  fi

  WORKDIR=$($MKTEMP -d --suffix="kpatch")
  debug <<< "** Working in $WORKDIR"

  debug <<< "** Unzipping original jar"
  if ! $UNZIP -n "$1" -d "$WORKDIR/" 2>&1 | err; then
    pfx_err <<< "Unable to unzip \"$1\""
    return $ERR_UNZIP_FAILED
  fi

  debug <<< "** Looping through interesting files (dis)"
  DISASSEMBLED_FILES=()
  for FILE in "${INTERESTING_FILES[@]}"; do
    if [ "${FILE:(-2)}" == '.j' ]; then
      $KRAK dis --out "$WORKDIR/$FILE" $KRAK_MODE "$WORKDIR/${FILE%.j}.class" 2>&1 | err
      $RM "$WORKDIR/${FILE%.j}.class"
      DISASSEMBLED_FILES+=("$FILE")
    fi
  done

  FULL_PATCH=$($REALPATH "$2")
  if ! (cd "$WORKDIR"; $PATCH -p1 -i "$FULL_PATCH") | err; then
    pfx_err <<< "PATCH exit code returned an error code"
    return $ERR_PATCH_FAILED
  fi

  debug <<< "** Looping through interesting files (asm)"
  for FILE in "${DISASSEMBLED_FILES[@]}"; do
    $KRAK asm --out "$WORKDIR/${FILE%.j}.class" "$WORKDIR/$FILE" 2>&1 | err
    $RM "$WORKDIR/$FILE"
  done

  if ! (cd "$WORKDIR"; $ZIP -r - .);then
    pfx_err <<< "ZIP exit code returned an error code"
    return $ERR_ZIP_FAILED
  fi

  debug <<< "** Finished successfully!"
  $RM -r "$WORKDIR"
  debug <<< "** Cleaned!"
  return 0
}

# -- Main
function main() {
  trap "exit $ERR_INTERRUPT" INT
  debug <<< "Path: $PATH #"
  case "${1:-}" in
  "diff" | "d")
    diff "${@:2}"
    ;;
  "patch" | "p")
    patch "${@:2}"
    ;;
  "--help" | "\\?")
    show_usage
    ;;
  *)
    critical_usage
    ;;
  esac
  trap - INT
}

trap - INT
(return 0 2>/dev/null) || main "$@"
