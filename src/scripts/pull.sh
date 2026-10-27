#!/bin/bash
set -euo pipefail
#
# pull: downloads a signed APK repository from an S3 bucket into a local
# directory that apko (or apk) can use as a file-path repository. For each
# architecture it reads <prefix>/<arch>/APKINDEX.tar.gz, verifies it with
# the keyring, downloads only the packages that index lists, with their
# signed sidecars, and verifies all of them in a private staging directory
# before moving anything into out_dir. It never lists the bucket.
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
#   PARAM_OUT_DIR       Where to put the repository (default packages).
#                       Each out_dir/<arch> must be absent or empty.
#   PARAM_CACHE_DIR     A directory of verified packages to reuse and add
#                       to (default: none).
#   PARAM_RECEIPT_PATH  Where to write the JSON receipt (default
#                       apk-repo-receipt.json).
# Environment variables in them are expanded when the CircleCI CLI is on
# the PATH. AWS credentials come from the AWS CLI's own chain.
#
# Shared code: SCRIPT_APK_REPO_LIB and SCRIPT_APK_REPO_PY hold
# lib/apk_repo.sh and apk_repo.py, from CircleCI's << include() >> or
# actions/run_script.sh. A standalone run (bash src/scripts/pull.sh) reads
# them from beside this script.

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
ENDPOINT_URL=$(ar_subst "${PARAM_ENDPOINT_URL:-}")
REGION=$(ar_subst "${PARAM_REGION:-}")
ARCH=$(ar_subst "${PARAM_ARCH:-}")
KEYRING=$(ar_subst "${PARAM_KEYRING:-}")
OUT_DIR=$(ar_subst "${PARAM_OUT_DIR:-packages}")
CACHE_DIR=$(ar_subst "${PARAM_CACHE_DIR:-}")
RECEIPT_PATH=$(ar_subst "${PARAM_RECEIPT_PATH:-apk-repo-receipt.json}")

ar_check_backend "${BACKEND}"
ar_check_bucket "${BUCKET}"
ar_check_prefix "${PREFIX}"
ar_check_endpoint "${ENDPOINT_URL}"
ar_check_region "${REGION}"
ar_arches "${ARCH:-$(ar_machine_arch)}"
if [[ -z "${OUT_DIR}" ]]; then
    ar_usage "out_dir is required."
fi
ar_need_tools python3 openssl
ar_need_aws
# shellcheck disable=SC2034 # filled and read by the lib
declare -A AR_KEYS=()
ar_keyring "${KEYRING}"

# P-1: never mix a pull with what's already there.
for arch in "${AR_ARCHES[@]}"; do
    if [[ -e "${OUT_DIR}/${arch}" || -L "${OUT_DIR}/${arch}" ]]; then
        if [[ ! -d "${OUT_DIR}/${arch}" || -L "${OUT_DIR}/${arch}" || -n "$(ls -A -- "${OUT_DIR}/${arch}")" ]]; then
            ar_usage "${OUT_DIR}/${arch} already exists and isn't an empty directory; pull only fills an empty one." \
                "Pull into a fresh out_dir, or remove ${OUT_DIR}/${arch} first."
        fi
    fi
done
rm -f -- "${RECEIPT_PATH}"

ar_aws_init "${BUCKET}" "${ENDPOINT_URL}" "${REGION}"
mkdir -p "${AR_WORK}/receipt"
ar_receipt_meta tool_version "${AR_TOOL_VERSION}" operation pull dry_run false backend "${BACKEND}" \
    endpoint_url "${ENDPOINT_URL}" bucket "${BUCKET}" prefix "${PREFIX}" started "$(ar_now)"

# fetch KEY OUT WHAT: downloads a file the index requires.
fetch() {
    local status=0
    ar_get_object "$1" "$2" || status=$?
    case "${status}" in
        0) ;;
        "${AR_ABSENT}") ar_die "$(ar_s3_url "$1") is missing, though the index lists $3." \
            "The repository is incomplete; publish the package again." ;;
        "${AR_DENIED}") ar_die "Access to $(ar_s3_url "$1") was denied." "$(ar_denied_hint "$1")" ;;
    esac
}

for arch in "${AR_ARCHES[@]}"; do
    stage="${AR_WORK}/stage/${arch}"
    mkdir -p "${stage}"
    key="${PREFIX}/${arch}/APKINDEX.tar.gz"
    status=0
    ar_get_object "${key}" "${stage}/APKINDEX.tar.gz" || status=$?
    case "${status}" in
        0) ;;
        "${AR_ABSENT}") ar_die "There is no repository at $(ar_s3_url "${PREFIX}/${arch}"): ${key} doesn't exist." \
            "Check bucket, prefix and arch, or publish to it first." ;;
        "${AR_DENIED}") ar_die "Access to $(ar_s3_url "${key}") was denied. It may not exist." "$(ar_denied_hint "${key}")" ;;
    esac
    etag=${AR_ETAG}
    version_id=${AR_VERSION_ID}
    echo "Read $(ar_s3_url "${key}") (ETag ${etag}${version_id:+, version ${version_id}})."
    ar_verify_index "${stage}/APKINDEX.tar.gz" "${arch}" "${AR_WORK}/${arch}"

    # Only what the verified index lists: each package's sidecar and its
    # signatures by keyring keys, then the package itself, from the cache
    # when a cached copy matches the signed sidecar.
    downloaded=0
    reused=0
    while IFS=$'\t' read -r name version _; do
        file="${name}-${version}.apk"
        fetch "${PREFIX}/${arch}/${file}.sha256" "${stage}/${file}.sha256" "${name} ${version}"
        for signer in "${AR_KEY_NAMES[@]}"; do
            status=0
            ar_get_object "${PREFIX}/${arch}/${file}.sha256.${signer}.sig" "${stage}/${file}.sha256.${signer}.sig" || status=$?
            if [[ "${status}" -eq "${AR_DENIED}" ]]; then
                ar_die "Access to $(ar_s3_url "${PREFIX}/${arch}/${file}.sha256.${signer}.sig") was denied." \
                    "$(ar_denied_hint "${PREFIX}/${arch}/${file}")"
            fi
        done
        ar_verify_sidecar "${stage}" "${file}"
        cached="${CACHE_DIR:+${CACHE_DIR}/${arch}/${file}}"
        if [[ -n "${cached}" && -f "${cached}" && "$(ar_sha256 "${cached}")" == "${AR_SIDECAR_SHA256}" ]]; then
            cp -- "${cached}" "${stage}/${file}"
            reused=$((reused + 1))
        else
            fetch "${PREFIX}/${arch}/${file}" "${stage}/${file}" "${name} ${version}"
            downloaded=$((downloaded + 1))
        fi
    done < "${AR_WORK}/${arch}/entries.tsv"

    ar_verify_packages "${stage}" "${arch}" "${AR_WORK}/${arch}" "${AR_WORK}/receipt/arch/${arch}"
    printf '%s\t%s\n' key "${key}" sha256 "$(ar_sha256 "${stage}/APKINDEX.tar.gz")" etag "${etag}" \
        version_id "${version_id}" signature ".SIGN.RSA256.${AR_INDEX_KEY}.pub" > "${AR_WORK}/receipt/arch/${arch}/index.tsv"
    echo "Verified ${arch}: an index signed with ${AR_INDEX_KEY}, ${downloaded} package(s) downloaded, ${reused} from the cache."
done

# P-2: only verified repositories reach out_dir, all architectures at once.
mkdir -p -- "${OUT_DIR}"
for arch in "${AR_ARCHES[@]}"; do
    if [[ -d "${OUT_DIR}/${arch}" ]]; then
        rmdir -- "${OUT_DIR}/${arch}"
    fi
    mv -- "${AR_WORK}/stage/${arch}" "${OUT_DIR}/${arch}"
    if [[ -n "${CACHE_DIR}" ]]; then
        mkdir -p -- "${CACHE_DIR}/${arch}"
        for package in "${OUT_DIR}/${arch}"/*.apk; do
            [[ -f "${package}" ]] || continue
            cp -- "${package}" "${CACHE_DIR}/${arch}/.$(basename -- "${package}").partial"
            mv -- "${CACHE_DIR}/${arch}/.$(basename -- "${package}").partial" "${CACHE_DIR}/${arch}/$(basename -- "${package}")"
        done
    fi
    echo "Pulled $(ar_s3_url "${PREFIX}/${arch}") into ${OUT_DIR}/${arch}."
done
ar_write_receipt "${RECEIPT_PATH}"
