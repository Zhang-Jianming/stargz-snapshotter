#!/bin/bash

#   Copyright The containerd Authors.

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

set -euo pipefail

LEGACY_MODE="legacy"
STARGZ_MODE="stargz"
ESTARGZ_MODE="estargz"

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
REPO="${CONTEXT}../../../"

# NOTE: The entire contents of containerd/stargz-snapshotter are located in
# the testing container so utils.sh is visible from this script during runtime.
# TODO: Refactor the code dependencies and pack them in the container without
#       expecting and relying on volumes.
source "${REPO}/script/util/utils.sh"

MEASURING_SCRIPT="${REPO}/script/benchmark/hello-bench/src/hello.py"
REBOOT_CONTAINERD_SCRIPT="${REPO}/script/benchmark/hello-bench/reboot_containerd.sh"
REPO_CONFIG_DIR="${REPO}/script/benchmark/hello-bench/config/"
CONTAINERD_CONFIG_DIR=/etc/containerd/
REMOTE_SNAPSHOTTER_CONFIG_DIR=/etc/containerd-stargz-grpc/
BENCHMARKOUT_MARK_OUTPUT="BENCHMARK_OUTPUT: "

if [ $# -lt 1 ] ; then
    echo "Specify benchmark target."
    echo "Ex) ${0} <YOUR_ACCOUNT_NAME> --all"
    echo "Ex) ${0} <YOUR_ACCOUNT_NAME> alpine busybox"
    exit 1
fi
TARGET_REPOUSER="${1}"
TARGET_IMAGES=${@:2}
NUM_OF_SAMPLES="${BENCHMARK_SAMPLES_NUM:-1}"

TMP_LOG_FILE=$(mktemp)
WORKLOADS_LIST=$(mktemp)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${TMP_LOG_FILE}" || true
    rm "${WORKLOADS_LIST}"
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

function output {
    echo "${BENCHMARKOUT_MARK_OUTPUT}${1}"
}

function set_noprefetch {
    local NOPREFETCH="${1}"
    sed -i 's/noprefetch = .*/noprefetch = '"${NOPREFETCH}"'/g' "${REMOTE_SNAPSHOTTER_CONFIG_DIR}config.toml"
}

function measure {
    local OPTION="${1}"
    local USER="${2}"
    "${MEASURING_SCRIPT}" ${OPTION} --user=${USER} --op=run --experiments=1 ${@:3}
}

echo "========="
echo "SPEC LIST"
echo "========="
uname -r
cat /etc/os-release
cat /proc/cpuinfo
cat /proc/meminfo
mount
df

echo "========="
echo "BENCHMARK"
echo "========="

output "["

for SAMPLE_NO in $(seq ${NUM_OF_SAMPLES}) ; do
    echo -n "" > "${WORKLOADS_LIST}"
    # Randomize workloads
    for IMAGE in ${TARGET_IMAGES} ; do
        for MODE in ${LEGACY_MODE} ${STARGZ_MODE} ${ESTARGZ_MODE} ; do
            echo "${IMAGE},${MODE}" >> "${WORKLOADS_LIST}"
        done
    done
    sort -R -o "${WORKLOADS_LIST}" "${WORKLOADS_LIST}"
    echo "Workloads of iteration [${SAMPLE_NO}]"
    cat "${WORKLOADS_LIST}"

    # Run the workloads
    for THEWL in $(cat "${WORKLOADS_LIST}") ; do
        echo "The workload is ${THEWL}"

        IMAGE=$(echo "${THEWL}" | cut -d ',' -f 1)
        MODE=$(echo "${THEWL}" | cut -d ',' -f 2)

        echo "===== Measuring [${SAMPLE_NO}] ${IMAGE} (${MODE}) ====="

        if [ "${MODE}" == "${LEGACY_MODE}" ] ; then
            NO_STARGZ_SNAPSHOTTER="true" "${REBOOT_CONTAINERD_SCRIPT}"
            measure "--mode=legacy" ${TARGET_REPOUSER} ${IMAGE}
        fi

        if [ "${MODE}" == "${STARGZ_MODE}" ] ; then
            echo -n "" > "${TMP_LOG_FILE}"
            set_noprefetch "true" # disable prefetch
            LOG_FILE="${TMP_LOG_FILE}" "${REBOOT_CONTAINERD_SCRIPT}"
            measure "--mode=stargz" ${TARGET_REPOUSER} ${IMAGE}
            check_remote_snapshots "${TMP_LOG_FILE}"
        fi

        if [ "${MODE}" == "${ESTARGZ_MODE}" ] ; then
            echo -n "" > "${TMP_LOG_FILE}"
            set_noprefetch "false" # enable prefetch
            LOG_FILE="${TMP_LOG_FILE}" "${REBOOT_CONTAINERD_SCRIPT}"
            measure "--mode=estargz" ${TARGET_REPOUSER} ${IMAGE}
            check_remote_snapshots "${TMP_LOG_FILE}"
        fi
    done
done

output "]"
