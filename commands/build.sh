#!/usr/bin/env bash

if [ -z "$BASH_VERSION" ]; then
  >&2 echo "This needs to run in bash"
  exit 1
fi

FLAVOURS_DIR=""
DATE=$(date "+%Y-%m-%d")

function usage()
{
  echo "Usage: potman build [-hv] [-d flavourdir] flavour"
}

OPTIND=1
while getopts "hvd:" _o ; do
  case "$_o" in
  d)
    FLAVOURS_DIR="${OPTARG}"
    ;;
  h)
    usage
    exit 0
    ;;
  v)
    VERBOSE="YES"
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

shift "$((OPTIND-1))"

if [ $# -ne 1 ]; then
  usage
  exit 1
fi


function run_ssh {
  run_ssh_potbuilder "$@"
}

set -eE
trap 'echo error: $STEP failed' ERR
source "${INCLUDE_DIR}/common.sh"
common_init_vars

FLAVOUR=$1
if [[ ! "$FLAVOUR" =~ $FLAVOUR_REGEX ]]; then
  >&2 echo "Invalid flavour"
  exit 1
fi

mkdir -p _build/tmp _build/artifacts

step "Load potman config"
read_potman_config potman.ini
FREEBSD_VERSION="${config_freebsd_version}"
FBSD="${FREEBSD_VERSION}"
FBSD_TAG=${FREEBSD_VERSION//./_}

if [ -z "${FLAVOURS_DIR}" ]; then
  FLAVOURS_DIR="${config_flavours_dir}"
fi

step "Read flavour config"
read_flavour_config "${FLAVOURS_DIR}/${FLAVOUR}/${FLAVOUR}.ini"

VERSION="${config_version}"
VERSION_SUFFIX="_$VERSION"

ORIGIN="${config_origin}"

FLAVOUR_FILES=( "$FLAVOUR" )

POT_CREATE_FLAVOURS=( "-f" "fbsd-update")
POT_CREATE_FLAVOURS+=( "-f" "${FLAVOUR}_version" "-f" "${FLAVOUR}" )

if [ "${config_runs_in_nomad}" = "true" ]; then
    FLAVOUR_FILES+=( "$FLAVOUR+4" )
    POT_CREATE_FLAVOURS+=( "$FLAVOUR+4" )
fi

FLAVOUR_FILES+=( "$FLAVOUR.sh" "$FLAVOUR.d/distfile.tar" )

for file in "${FLAVOUR_FILES[@]}"; do
  if [[ ! -f "$FLAVOURS_DIR"/$FLAVOUR/"$file" ]]; then
    >&2 echo "$FLAVOURS_DIR/$FLAVOUR/$file missing"
    exit 1
  fi
done

step "Initialize"
init_potbuilder_ssh

step "Test SSH connection"
run_ssh true

step "Remove existing remote $FLAVOUR.d"
run_ssh "rm -rf /usr/local/etc/pot/flavours/\"${FLAVOUR}\".d"

step "Remove existing remote $FLAVOUR files"
run_ssh "rm -f /usr/local/etc/pot/flavours/\"$FLAVOUR\"*"

step "Copy flavour files"
tar -C "${FLAVOURS_DIR}/${FLAVOUR}" -cf - "${FLAVOUR_FILES[@]}" \
  | run_ssh tar -C /usr/local/etc/pot/flavours -xof -

step "Create remote version flavour"
run_ssh "echo '#!/bin/sh
set -e
mkdir -p /usr/local/etc
echo \"${FBSD_TAG}${VERSION_SUFFIX}\" \
>\"/usr/local/etc/${FLAVOUR}_version\"
' | tee \"/usr/local/etc/pot/flavours/${FLAVOUR}_version.sh\" \
>/dev/null
"

step "Set remote flavour permissions"
run_ssh "sudo chmod 775 \
  \"/usr/local/etc/pot/flavours/${FLAVOUR}_version.sh\" \
  \"/usr/local/etc/pot/flavours/$FLAVOUR.sh\" \
  \"/usr/local/etc/pot/flavours/$FLAVOUR.d\"
"

step "Destroy old pot images"
run_ssh "sudo pot destroy -F -p \"${FLAVOUR}_${FBSD_TAG}\" || true"

step "Verify pot images are gone"
run_ssh "! sudo pot info -p \"${FLAVOUR}_${FBSD_TAG}\" >/dev/null"

step "Build pot image"
if [ -z "$ORIGIN" ]; then
  run_ssh sudo "RUNS_IN_NOMAD=\"${config_runs_in_nomad}\" \
    pot create -b \"$FBSD\" -p \"${FLAVOUR}_${FBSD_TAG}\" \
    -t single -N public-bridge ${POT_CREATE_FLAVOURS[*]} -v"
else
  run_ssh sudo "RUNS_IN_NOMAD=\"${config_runs_in_nomad}\" \
    pot clone -P \"${ORIGIN}_${FBSD_TAG}\" \
    -p \"${FLAVOUR}_${FBSD_TAG}\" -F -v ${POT_CREATE_FLAVOURS[*]}"

#  if false; then
#  # XXX: THIS IS HORRIBLE AND SHOULD MOVE TO POT
#  OLD_IFS=$IFS
#  IFS=$'\n'
#  for line in $(egrep -h "^(set-cmd -c|set-attribute -A|copy-in -s) " \
#    "$FLAVOURS_DIR"/$FLAVOUR/$FLAVOUR);
#  do
#      # XXX: set-cmd needs special quoting
#      #echo run_ssh sudo pot $line -vp ${FLAVOUR}_"$FBSD_TAG"
#      run_ssh sudo pot $line -p ${FLAVOUR}_"$FBSD_TAG"
#  done
#  IFS=$OLD_IFS
#
#  run_ssh sudo pot copy-in -p ${FLAVOUR}_"$FBSD_TAG" \
#    -s /usr/local/etc/pot/flavours/${FLAVOUR}_version.sh \
#    -d /root
#
#  run_ssh sudo pot copy-in -p ${FLAVOUR}_"$FBSD_TAG" \
#    -s /usr/local/etc/pot/flavours/$FLAVOUR.sh \
#    -d /root
#
#  run_ssh sudo pot start ${FLAVOUR}_"$FBSD_TAG"
#
#  run_ssh sudo RUNS_IN_NOMAD=${config_runs_in_nomad}\
#    jexec ${FLAVOUR}_"$FBSD_TAG" /root/${FLAVOUR}_version.sh ${FLAVOUR}_"$FBSD_TAG"
#
#  run_ssh sudo RUNS_IN_NOMAD=${config_runs_in_nomad}\
#    jexec ${FLAVOUR}_"$FBSD_TAG" /root/$FLAVOUR.sh ${FLAVOUR}_"$FBSD_TAG"
#
#  run_ssh sudo pot stop ${FLAVOUR}_"$FBSD_TAG"
#
#  OLD_IFS=$IFS
#  IFS=$'\n'
#  for line in $(egrep -h "^(set-cmd -c|set-attribute -A|copy-in -s) " \
#    "$FLAVOURS_DIR"/$FLAVOUR/${FLAVOUR}+4);
#  do
#      # XXX: set-cmd needs special quoting
#      #echo run_ssh sudo pot $line -vp ${FLAVOUR}_"$FBSD_TAG"
#      run_ssh sudo pot $line -p ${FLAVOUR}_"$FBSD_TAG"
#  done
#  IFS=$OLD_IFS
#  fi
fi

step "Snapshot pot image"
run_ssh "sudo pot snapshot -p \"${FLAVOUR}_${FBSD_TAG}\""

step "Export pot"
run_ssh "sudo pot export -c -l 0 -p \"${FLAVOUR}_${FBSD_TAG}\" \
  -t \"$VERSION\" -D /tmp"

step "Copy pot image to local directory"
scp -qF "$SSHCONF_POTBUILDER" \
  "$POTBUILDER:/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz" \
  "$POTBUILDER:/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz.meta" \
  "$POTBUILDER:/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz.skein" \
  _build/tmp/.

step "Clean up build vm"

if [ "${config_keep}" != "true" ]; then
  run_ssh "sudo pot destroy -F -p \"${FLAVOUR}_${FBSD_TAG}\""
fi

run_ssh sudo rm -f \
  "/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz" \
  "/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz.meta" \
  "/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz.skein"

step "Move image into place"
mv \
  "_build/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz" \
  "_build/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz.meta" \
  "_build/tmp/${FLAVOUR}_${FBSD_TAG}${VERSION_SUFFIX}.xz.skein" \
  _build/artifacts/.

# if DEBUG is enabled, dump the variables
if [ "$DEBUG" -eq 1 ]; then
    printf "\n\n"
    echo "Dump of variables"
    echo "================="
    echo "FBSD: $FBSD"
    echo "FBSD_TAG: $FBSD_TAG"
    echo "Version: $VERSION with suffix: $VERSION_SUFFIX"
    printf "\n\n"
    echo "Date: $DATE"
    printf "\n\n"
fi

step "Success"