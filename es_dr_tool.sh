#!/usr/bin/env bash

# filename          : es_dr_tool.sh
# description       : Manage AppDynamics Events Service automatic backup & restore
# author            : Alexander Agbidinoukoun
# email             : aagbidin@cisco.com
# date              : 14/11/2024
# version           : 0.1
# usage             : ./es_dr_tool.sh -c config.cfg -m primary|secondary
# notes             :

#==============================================================================

set -Euo pipefail

# check for curl
if ! command -v curl >/dev/null; then
  echo "Please install curl to use this tool (sudo yum install -y curl)"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
LOG_FILE=$(echo ${BASH_SOURCE[0]} | sed 's/sh$/log/')

primary_snapshot_id_filename=primary_snapshot.id
secondary_snapshot_id_filename=secondary_snapshot.id

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-d] [-f frequency] -m primary|secondary -c config_file

Manage AppDynamics Events Service automatic backup & restore

Available options:

-h, --help        Print this help and exit
-v, --verbose     Print script debug info
-c, --config      Path to config file
-m, --mode        primary or secondary
-d, --daemon      Daemon mode. Default: false
-f, --frequency   In daemon mode, set the frequency in seconds at which the update is performed. Default: 60

EOF
  exit
}

setup_colors() {
  if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != "dumb" ]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[0;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

log() {
  echo >&2 -e "${1-}" >>${LOG_FILE}
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  local date=$(date '+%Y-%m-%d %H:%M:%S')
  msg "${date} ${RED}ERROR${NOFORMAT} $msg"
  log "${date} ERROR $msg"
  exit $code
}

warn() {
  local msg=$1
  local date=$(date '+%Y-%m-%d %H:%M:%S')
  msg "${date} ${YELLOW}WARN${NOFORMAT} $msg"
  log "${date} WARN $msg"
}

info() {
  local msg=$1
  local date=$(date '+%Y-%m-%d %H:%M:%S')
  msg "${date} ${GREEN}INFO${NOFORMAT} $msg"
  log "${date} INFO $msg"
}

parse_params() {
  # default values of variables set from params
  daemon=0
  frequency=60

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -d | --daemon) daemon=1 ;;
    -c | --config)
      config="${2-}"
      shift
      ;;
    -f | --frequency)
      frequency="${2-}"
      shift
      ;;
    -m | --mode)
      mode="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [ -z "${config-}" ] && warn "Missing required parameter: config" && usage
  [ -z "${mode-}" ] && warn "Missing required parameter: mode" && usage
  [ $mode == "primary" ] || [ $mode == "secondary" ] || die "Unknown mode: $mode"

  #[ ${#args[@]} -eq 0 ] && die "Missing script arguments"

  return 0
}

trap cleanup SIGINT SIGTERM EXIT
cleanup() {
  trap - SIGINT SIGTERM EXIT
  # script cleanup here
  if [ "$daemon" -eq 1 ]; then
    exit 255
  fi
}

setup_colors
parse_params "$@"

# script logic here

function do_snapshot() {
    # check required config entries
    [ -z "${primary_es_path-}" ] && die "Missing required config entry: primary_es_path"
    response=$(${primary_es_path}/processor/bin/events-service.sh snapshot-run -p ${primary_es_path}/processor/conf/events-service-api-store.properties)
    [ -z "$(echo $response | grep 'request executed successfully')" ] && die "Snapshot failed: $response"
    info "Snapshot intiated successfully."
}

function do_restore() {
    # check required config entries
    [ -z "${secondary_es_path-}" ] && die "Missing required config entry: secondary_es_path"
    response=$(${secondary_es_path}/processor/bin/events-service.sh snapshot-restore -p ${secondary_es_path}/processor/conf/events-service-api-store.properties)
    [ -z "$(echo $response | grep 'request executed successfully')" ] && die "Snapshot restore failed: $response"
    info "Snapshot restore intiated successfully."
}

function configure_repo() {
  info "Configuring snapshot repository."
  # source config file
  [ ! -r $config ] && die "$config is not readable"
  . $config

  # check required config entries
  [ -z "${primary_es_url-}" ] && die "Missing required config entry: primary_es_url"
  [ -z "${secondary_es_url-}" ] && die "Missing required config entry: secondary_es_url"
  [ -z "${primary_es_repo_path-}" ] && die "Missing required config entry: primary_es_repo_path"
  [ -z "${secondary_es_repo_path-}" ] && die "Missing required config entry: secondary_es_repo_path"

  readonly="false"
  [ $mode == "secondary" ] && readonly="true"
  es_url=${primary_es_url}
  [ $mode == "secondary" ] && es_url=${secondary_es_url}
  es_repo_path=${primary_es_repo_path}
  [ $mode == "secondary" ] && es_repo_path=${secondary_es_repo_path}
  es_repo_name=$(basename $es_repo_path)

  response=$(curl -s -X PUT ${es_url}/_snapshot/${es_repo_name} \
    -H 'Content-Type: application/json' \
    -d "
    {
        \"type\": \"fs\",
        \"settings\": {
            \"location\": \"${es_repo_path}\",
            \"readonly\": \"${readonly}\"
        }
    }")
  # validate response
  [ -z "$(echo $response | grep '"acknowledged":true')" ] && die "Configuring snapshot repository failed: $response"
}


function primary() {

    # source config file
    [ ! -r $config ] && die "$config is not readable"
    . $config

      # check required config entries
    [ -z "${primary_es_path-}" ] && die "Missing required config entry: primary_es_path"
    [ -z "${primary_es_repo_path-}" ] && die "Missing required config entry: primary_es_repo_path"


    # do snapshot if :
    # - there is no snapshot yet
    # - there is no snapshot in progress already
    # - secondary has restored previous snapshot

    info "Checking if snapshots exist..."
    snapshot_list=$(${primary_es_path}/processor/bin/events-service.sh snapshot-list -p ${primary_es_path}/processor/conf/events-service-api-store.properties)
    [ -z "$(echo $snapshot_list | grep 'No snapshots taken')" ] && snapshots_exist=true || snapshots_exist=false
    if  [ $snapshots_exist == false ]; then
        info "No snapshots exist. Doing full snapshot..."
        do_snapshot
        return $?
    fi

    info "Checking if snapshot is in progress..."
    snapshot_status=$(${primary_es_path}/processor/bin/events-service.sh snapshot-status -p ${primary_es_path}/processor/conf/events-service-api-store.properties)
    [ -z "$(echo $snapshot_status | grep 'Snapshot state is SUCCESS')" ] && snapshot_in_progress=true || snapshot_in_progress=false
    if  [ $snapshot_in_progress == true ]; then
        info "Snapshot already in progress. Cancelling."
        return 0
    fi

    info "Checking if secondary has restored latest snapshot..."
    latest_snapshot_id=$(echo $snapshot_list | grep -Eo "1. snapshot\S+" | cut -d' ' -f 2)
    secondary_snapshot_id_file=${primary_es_repo_path}/${secondary_snapshot_id_filename}
    if [ ! -r ${secondary_snapshot_id_file} ] || [ ! "$(cat ${secondary_snapshot_id_file})" == "$latest_snapshot_id" ]; then
        info "Snapshot not restored on secondary. Cancelling."
        return 0
    fi

    info "Doing incremental snapshot..."
    do_snapshot
    err=$?

    info "Updating snapshot id file..."
    snapshot_list=$(${primary_es_path}/processor/bin/events-service.sh snapshot-list -p ${primary_es_path}/processor/conf/events-service-api-store.properties)
    latest_snapshot_id=$(echo $snapshot_list | grep -Eo "1. snapshot\S+" | cut -d' ' -f 2)
    primary_snapshot_id_file=${primary_es_repo_path}/${primary_snapshot_id_filename}
    echo $latest_snapshot_id > ${primary_snapshot_id_file}

    return $err
}

function secondary() {

    # source config file
    [ ! -r $config ] && die "$config is not readable"
    . $config

      # check required config entries
    [ -z "${secondary_es_path-}" ] && die "Missing required config entry: primary_es_path"
    [ -z "${secondary_es_repo_path-}" ] && die "Missing required config entry: primary_es_repo_path"


    # do snapshot restore if :
    # - there is a snapshot to restore
    # - there is no snapshot restore in progress already
    # - there is a new snapshot that has not been restored already

    info "Checking if snapshots exist..."
    snapshot_list=$(${secondary_es_path}/processor/bin/events-service.sh snapshot-list -p ${secondary_es_path}/processor/conf/events-service-api-store.properties)
    [ -z "$(echo $snapshot_list | grep 'No snapshots taken')" ] && snapshots_exist=true || snapshots_exist=false
    if  [ $snapshots_exist == false ]; then
        info "No snapshots to restore. Cancelling."
        return 0
    fi

    info "Checking if snapshot restore is in progress..."
    latest_snapshot_id=$(echo $snapshot_list | grep -Eo "1. snapshot\S+" | cut -d' ' -f 2)
    secondary_snapshot_id_file=${secondary_es_repo_path}/${secondary_snapshot_id_filename}

    restore_status=$(${secondary_es_path}/processor/bin/events-service.sh snapshot-restore-status -p ${secondary_es_path}/processor/conf/events-service-api-store.properties)
    [ -z "$(echo $restore_status | grep 'Restore is complete')" ] && restore_in_progress=true || restore_in_progress=false
    if  [ $restore_in_progress == true ]; then
        info "Snapshot restore already in progress. Cancelling."
        return 0
    else
         # if we land here there was a previous snapshot restore and it has completed
         if [ -r ${secondary_snapshot_id_file} ] && [ -z "$(cat ${secondary_snapshot_id_file})" ]; then
            echo $latest_snapshot_id > ${secondary_snapshot_id_file}
            info "Previous snapshot restore has completed. Updating snapshot id file & cancelling."
            return 0
         fi
    fi

    info "Checking if a new snapshot is available..."
     # if we land here this is the first snapshot restore
    if [ ! -r ${secondary_snapshot_id_file} ] || \
     # if we land here there is a previous restore that has completed and a new snapshot is available
    [ -r ${secondary_snapshot_id_file} ] && [ ! -z "$(cat ${secondary_snapshot_id_file})" ] && [ ! "$(cat ${secondary_snapshot_id_file})" == "$latest_snapshot_id" ]; then
      info "Doing snapshot restore..."
      echo > ${secondary_snapshot_id_file} # we empty id file: it will be updated with latest id once the restore has completed
      do_restore
      return $?
    else
      info "No new snapshot to restore. Cancelling."
    fi
}

function run_mode() {
  if [ $mode == "primary" ]; then
    primary
    return $?
  elif [ $mode == "secondary" ]; then
    secondary
    return $?
  fi
}

if [ 0 -eq $daemon ]; then
  info "Running $mode once."
  configure_repo
  run_mode
else
  info "Running $mode in daemon mode (frequency = ${frequency}s)."
  configure_repo
  while true; do
    run_mode
    sleep $frequency
  done
fi
