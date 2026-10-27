#!/bin/bash
set -euo pipefail
#
# verify: checks a local APK repository offline, against a keyring, with
# no network access and no AWS CLI. For each architecture, the signed
# <dir>/<arch>/APKINDEX.tar.gz must verify with a keyring key, and every
# package it lists must be in the directory with a sidecar signed by a
# keyring key, matching the package's bytes, the index's size and checksum
# (C:), and, for its data, the datahash in its .PKGINFO. Files the index
# doesn't list are reported, not refused.
#
# Parameters, as environment variables (the orb command and the GitHub
# Action set them; a standalone run sets them itself):
#   PARAM_DIR           The repository directory (default packages).
#   PARAM_ARCH          Architectures, space-separated x86_64 and aarch64
#                       (default: this machine's).
#   PARAM_KEYRING       Public key files (<key>.rsa.pub) and directories of
#                       them to trust, space-separated. Required.
#   PARAM_RECEIPT_PATH  Where to write the JSON receipt (default
#                       apk-repo-receipt.json).
# Environment variables in them are expanded when the CircleCI CLI is on
# the PATH.
#
# Shared code: SCRIPT_APK_REPO_LIB and SCRIPT_APK_REPO_PY hold
# lib/apk_repo.sh and apk_repo.py, from CircleCI's << include() >> or
# actions/run_script.sh. A standalone run (bash src/scripts/verify.sh)
# reads them from beside this script.

if ((BASH_VERSINFO[0] < 4)); then
    echo "ERROR: apk-repo-orb needs bash 4 or newer; this is bash ${BASH_VERSION}." >&2
    exit 1
fi
if [[ -z "${SCRIPT_APK_REPO_LIB:-}" ]]; then
    SCRIPT_APK_REPO_LIB=$(cat "$(dirname "${BASH_SOURCE[0]}")/lib/apk_repo.sh")
fi
if [[ -z "${SCRIPT_APK_REPO_PY:-}" ]]; then
    SCRIPT_APK_REPO_PY=$(cat "$(dirname "${BASH_SOURCE[0]}")/apk_repo.py")
fi
eval "${SCRIPT_APK_REPO_LIB}"

AR_WORK=$(mktemp -d)
trap 'rm -rf "${AR_WORK}"' EXIT

DIR=$(ar_subst "${PARAM_DIR:-packages}")
ARCH=$(ar_subst "${PARAM_ARCH:-}")
KEYRING=$(ar_subst "${PARAM_KEYRING:-}")
RECEIPT_PATH=$(ar_subst "${PARAM_RECEIPT_PATH:-apk-repo-receipt.json}")

ar_need_tools python3 openssl
ar_arches "${ARCH:-$(ar_machine_arch)}"
# shellcheck disable=SC2034 # filled and read by the lib
declare -A AR_KEYS=()
ar_keyring "${KEYRING}"
if [[ ! -d "${DIR}" ]]; then
    ar_usage "dir ${DIR} is not a directory."
fi

mkdir -p "${AR_WORK}/receipt"
ar_receipt_meta tool_version "${AR_TOOL_VERSION}" operation verify dry_run false started "$(ar_now)"

for arch in "${AR_ARCHES[@]}"; do
    index="${DIR}/${arch}/APKINDEX.tar.gz"
    if [[ ! -f "${index}" ]]; then
        ar_die "${index} is missing; ${DIR} has no ${arch} repository."
    fi
    ar_verify_index "${index}" "${arch}" "${AR_WORK}/${arch}"
    ar_verify_packages "${DIR}/${arch}" "${arch}" "${AR_WORK}/${arch}" "${AR_WORK}/receipt/arch/${arch}"
    printf '%s\t%s\n' key "${index}" sha256 "$(ar_sha256 "${index}")" signature ".SIGN.RSA256.${AR_INDEX_KEY}.pub" \
        > "${AR_WORK}/receipt/arch/${arch}/index.tsv"
    count=$(wc -l < "${AR_WORK}/${arch}/entries.tsv")
    echo "Verified ${DIR}/${arch}: an index signed with ${AR_INDEX_KEY} and its ${count// /} package(s)."
done
ar_write_receipt "${RECEIPT_PATH}"
