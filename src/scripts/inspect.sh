#!/bin/bash
set -euo pipefail
#
# inspect: reads a signed APK repository's index from an S3 bucket and
# reports which packages it lists, without downloading any package. For
# each architecture it reads <prefix>/<arch>/APKINDEX.tar.gz, verifies its
# signature with the keyring, and writes every package it lists (name,
# version, file, size) to the receipt, so a pipeline can build only what
# the repository doesn't have yet. It never lists the bucket, and writes
# nothing but the receipt.
#
# Parameters, as environment variables (the orb command and the GitHub
# Action set them; a standalone run sets them itself):
#   PARAM_BACKEND       Storage backend: s3 (default s3).
#   PARAM_BUCKET        The bucket. Required.
#   PARAM_PREFIX        Key prefix of the repository, such as my-org/os.
#                       Required.
#   PARAM_ENDPOINT_URL  An S3-compatible endpoint (default: AWS).
#   PARAM_REGION        The bucket's region (default: the AWS CLI's).
#   PARAM_ARCH          Architectures, space-separated x86_64 and aarch64
#                       (default: this machine's).
#   PARAM_KEYRING       Public key files (<key>.rsa.pub) and directories of
#                       them to trust, space-separated. Required.
#   PARAM_INDEX_SHA256  The SHA-256 each architecture's index must have, as
#                       an earlier receipt records it: one value for one
#                       architecture, or <arch>=<sha256> pairs (default:
#                       none, any index the keyring verifies).
#   PARAM_INDEX_VERSION_ID
#                       The S3 version of each architecture's index to
#                       read, in the same forms; needs PARAM_INDEX_SHA256
#                       (default: none, the current version).
#   PARAM_ALLOW_MISSING Report an architecture with no index yet as an
#                       empty repository instead of failing (default
#                       false).
#   PARAM_RECEIPT_PATH  Where to write the JSON receipt (default
#                       apk-repo-receipt.json).
# Environment variables in them are expanded when the CircleCI CLI is on
# the PATH. AWS credentials come from the AWS CLI's own chain.
#
# Shared code: SCRIPT_APK_REPO_LIB and SCRIPT_APK_REPO_PY hold
# lib/apk_repo.sh and apk_repo.py, from CircleCI's include directive or
# actions/run_script.sh. A standalone run (bash src/scripts/inspect.sh)
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

BACKEND=$(ar_subst "${PARAM_BACKEND:-s3}")
BUCKET=$(ar_subst "${PARAM_BUCKET:-}")
PREFIX=$(ar_subst "${PARAM_PREFIX:-}")
ENDPOINT_URL=$(ar_configured_endpoint "$(ar_subst "${PARAM_ENDPOINT_URL:-}")")
REGION=$(ar_subst "${PARAM_REGION:-}")
ARCH=$(ar_subst "${PARAM_ARCH:-}")
KEYRING=$(ar_subst "${PARAM_KEYRING:-}")
INDEX_SHA256=$(ar_subst "${PARAM_INDEX_SHA256:-}")
INDEX_VERSION_ID=$(ar_subst "${PARAM_INDEX_VERSION_ID:-}")
ALLOW_MISSING=$(ar_bool allow_missing "${PARAM_ALLOW_MISSING:-false}")
RECEIPT_PATH=$(ar_subst "${PARAM_RECEIPT_PATH:-apk-repo-receipt.json}")

ar_check_backend "${BACKEND}"
ar_check_bucket "${BUCKET}"
ar_check_prefix "${PREFIX}"
ar_check_endpoint "${ENDPOINT_URL}"
ar_check_region "${REGION}"
ARCH=$(ar_default_arch "${ARCH}") || exit $?
ar_arches "${ARCH}"
ar_check_receipt_path "${RECEIPT_PATH}"
# shellcheck disable=SC2034 # filled and read by the lib
declare -A AR_PIN_SHA256=() AR_PIN_VERSION_ID=()
ar_index_pins "${INDEX_SHA256}" "${INDEX_VERSION_ID}"
ar_need_tools python3 openssl
ar_need_aws
# shellcheck disable=SC2034 # filled and read by the lib
declare -A AR_KEYS=()
ar_keyring "${KEYRING}"
rm -f -- "${RECEIPT_PATH}"

ar_aws_init "${BUCKET}" "${ENDPOINT_URL}" "${REGION}"
mkdir -p "${AR_WORK}/receipt"
ar_receipt_meta tool_version "${AR_TOOL_VERSION}" operation inspect dry_run false backend "${BACKEND}" \
    endpoint_url "${ENDPOINT_URL}" bucket "${BUCKET}" prefix "${PREFIX}" started "$(ar_now)"

for arch in "${AR_ARCHES[@]}"; do
    key="${PREFIX}/${arch}/APKINDEX.tar.gz"
    out="${AR_WORK}/receipt/arch/${arch}"
    mkdir -p "${out}" "${AR_WORK}/index/${arch}"
    status=0
    ar_read_index "${arch}" "${key}" "${AR_WORK}/index/${arch}/APKINDEX.tar.gz" "${AR_WORK}/${arch}" \
        "${ALLOW_MISSING}" || status=$?
    if [[ "${status}" -eq "${AR_ABSENT}" ]]; then
        # An architecture with nothing published yet: no index, no packages.
        printf '%s\t%s\n' key "${key}" missing true > "${out}/index.tsv"
        : > "${out}/packages.tsv"
        echo "There is no repository at $(ar_s3_url "${PREFIX}/${arch}") yet; allow_missing reports it as empty."
        continue
    fi
    # Only the index is read: a package's SHA-256 is in its sidecar, which
    # isn't fetched, so the receipt has none.
    : > "${out}/packages.tsv"
    while IFS=$'\t' read -r name version _ size _; do
        printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${version}" "${name}-${version}.apk" "" "${size}" >> "${out}/packages.tsv"
    done < "${AR_WORK}/${arch}/entries.tsv"
    printf '%s\t%s\n' key "${key}" sha256 "$(ar_sha256 "${AR_WORK}/index/${arch}/APKINDEX.tar.gz")" \
        etag "${AR_INDEX_ETAG}" version_id "${AR_INDEX_VERSION_ID}" signature ".SIGN.RSA256.${AR_INDEX_KEY}.pub" \
        pinned "$([[ -n "${AR_PIN_SHA256[${arch}]}" ]] && echo true || echo false)" > "${out}/index.tsv"
    count=$(wc -l < "${AR_WORK}/${arch}/entries.tsv")
    echo "Inspected ${arch}: an index signed with ${AR_INDEX_KEY} that lists ${count// /} package(s)."
done
ar_write_receipt "${RECEIPT_PATH}"
