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
#   PARAM_INDEX_SHA256  The SHA-256 each architecture's index must have, as
#                       an earlier receipt records it: one value for one
#                       architecture, or <arch>=<sha256> pairs (default:
#                       none, any index the keyring verifies).
#   PARAM_INDEX_VERSION_ID
#                       The S3 version of each architecture's index to
#                       read, in the same forms; needs PARAM_INDEX_SHA256
#                       (default: none, the current version).
#   PARAM_PACKAGES      Only these packages, as <name>=<version> entries
#                       separated by spaces, each listed in the index
#                       (default: none, every package the index lists).
#   PARAM_RECEIPT_PATH  Where to write the JSON receipt (default
#                       apk-repo-receipt.json).
# Environment variables in them are expanded when the CircleCI CLI is on
# the PATH. AWS credentials come from the AWS CLI's own chain.
#
# Shared code: SCRIPT_APK_REPO_LIB and SCRIPT_APK_REPO_PY hold
# lib/apk_repo.sh and apk_repo.py, from CircleCI's include directive or
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
ENDPOINT_URL=$(ar_configured_endpoint "$(ar_subst "${PARAM_ENDPOINT_URL:-}")")
REGION=$(ar_subst "${PARAM_REGION:-}")
ARCH=$(ar_subst "${PARAM_ARCH:-}")
KEYRING=$(ar_subst "${PARAM_KEYRING:-}")
OUT_DIR=$(ar_subst "${PARAM_OUT_DIR:-packages}")
CACHE_DIR=$(ar_subst "${PARAM_CACHE_DIR:-}")
INDEX_SHA256=$(ar_subst "${PARAM_INDEX_SHA256:-}")
PACKAGES=$(ar_subst "${PARAM_PACKAGES:-}")
INDEX_VERSION_ID=$(ar_subst "${PARAM_INDEX_VERSION_ID:-}")
RECEIPT_PATH=$(ar_subst "${PARAM_RECEIPT_PATH:-apk-repo-receipt.json}")

ar_check_backend "${BACKEND}"
ar_check_bucket "${BUCKET}"
ar_check_prefix "${PREFIX}"
ar_check_endpoint "${ENDPOINT_URL}"
ar_check_region "${REGION}"
ARCH=$(ar_default_arch "${ARCH}") || exit $?
ar_arches "${ARCH}"
ar_check_receipt_path "${RECEIPT_PATH}"
if [[ -z "${OUT_DIR}" ]]; then
    ar_usage "out_dir is required."
fi
# A path that starts with - is a path, not an option, to every tool below.
[[ "${OUT_DIR}" == -* ]] && OUT_DIR="./${OUT_DIR}"
[[ "${CACHE_DIR}" == -* ]] && CACHE_DIR="./${CACHE_DIR}"
# out_dir and cache_dir are checked now, before anything is downloaded, so a
# pull that has done its work can't fail on them after out_dir is filled.
if [[ -e "${OUT_DIR}" && ! -d "${OUT_DIR}" ]]; then
    ar_usage "out_dir ${OUT_DIR} exists and isn't a directory."
fi
if [[ -n "${CACHE_DIR}" && -e "${CACHE_DIR}" && ! -d "${CACHE_DIR}" ]]; then
    ar_usage "cache_dir ${CACHE_DIR} exists and isn't a directory."
fi
# A pinned read: the index's bytes (a SHA-256 from an earlier receipt) and,
# in a versioned bucket, which version of it to read, so a pull can fetch
# that snapshot again. Packages are immutable, so the index fixes them too.
# shellcheck disable=SC2034 # filled and read by the lib
declare -A AR_PIN_SHA256=() AR_PIN_VERSION_ID=()
ar_index_pins "${INDEX_SHA256}" "${INDEX_VERSION_ID}"
ar_selection "${PACKAGES}"
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
    # A symbolic link there, even a dangling one, is left alone (below).
    if [[ -n "${CACHE_DIR}" && ! -L "${CACHE_DIR}/${arch}" && -e "${CACHE_DIR}/${arch}" && ! -d "${CACHE_DIR}/${arch}" ]]; then
        ar_usage "cache_dir ${CACHE_DIR}/${arch} exists and isn't a directory."
    fi
done
rm -f -- "${RECEIPT_PATH}"

ar_aws_init "${BUCKET}" "${ENDPOINT_URL}" "${REGION}"
mkdir -p "${AR_WORK}/receipt"
ar_receipt_meta tool_version "${AR_TOOL_VERSION}" operation pull dry_run false backend "${BACKEND}" \
    endpoint_url "${ENDPOINT_URL}" bucket "${BUCKET}" prefix "${PREFIX}" started "$(ar_now)"

# Every architecture's index is read, verified and checked against the pins
# and packages before any package is downloaded, so a mismatch in one
# architecture costs no other architecture's downloads.
declare -A INDEX_ETAG=() INDEX_VERSION_ID=() INDEX_KEY=()
for arch in "${AR_ARCHES[@]}"; do
    stage="${AR_WORK}/stage/${arch}"
    mkdir -p "${stage}" "${AR_WORK}/receipt/arch/${arch}"
    key="${PREFIX}/${arch}/APKINDEX.tar.gz"
    ar_read_index "${arch}" "${key}" "${stage}/APKINDEX.tar.gz" "${AR_WORK}/${arch}"
    # A selective pull: the signed index as it is, and only these packages.
    ar_select_entries "${AR_WORK}/${arch}" "$(ar_s3_url "${key}")"
    if [[ ${#AR_SELECTION[@]} -gt 0 ]]; then
        printf '%s\n' "${AR_SELECTION[@]}" > "${AR_WORK}/receipt/arch/${arch}/selection"
    fi
    INDEX_ETAG[${arch}]=${AR_INDEX_ETAG}
    INDEX_VERSION_ID[${arch}]=${AR_INDEX_VERSION_ID}
    INDEX_KEY[${arch}]=${AR_INDEX_KEY}
done

for arch in "${AR_ARCHES[@]}"; do
    stage="${AR_WORK}/stage/${arch}"
    key="${PREFIX}/${arch}/APKINDEX.tar.gz"
    # Only what the verified index lists: each package's sidecar and its
    # signatures by keyring keys, then the package itself, from the cache
    # when a cached copy matches the signed sidecar. Downloads run in
    # parallel, each held to the size it can be: a sidecar's exact line, a
    # signature's AR_SIG_MAX, and the package's size in the index.
    # Everything is verified here, one by one.
    fetched="${AR_WORK}/fetched/${arch}"
    mkdir -p "${fetched}"
    : > "${fetched}/sidecars"
    : > "${fetched}/packages"
    while IFS=$'\t' read -r name version _; do
        file="${name}-${version}.apk"
        printf '%s\t%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}.sha256" "${stage}/${file}.sha256" "${fetched}/${file}.sha256" \
            "$((64 + 2 + ${#file} + 1))" >> "${fetched}/sidecars"
        for signer in "${AR_KEY_NAMES[@]}"; do
            printf '%s\t%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}.sha256.${signer}.sig" "${stage}/${file}.sha256.${signer}.sig" \
                "${fetched}/${file}.sha256.${signer}.sig" "${AR_SIG_MAX}" >> "${fetched}/sidecars"
        done
    done < "${AR_WORK}/${arch}/entries.tsv"
    ar_get_objects "${fetched}/sidecars"
    downloaded=0
    reused=0
    while IFS=$'\t' read -r name version _ size _; do
        file="${name}-${version}.apk"
        ar_require_fetched "${fetched}/${file}.sha256" "${PREFIX}/${arch}/${file}.sha256" "${name} ${version}" \
            "$((64 + 2 + ${#file} + 1))"
        for signer in "${AR_KEY_NAMES[@]}"; do
            ar_optional_fetched "${fetched}/${file}.sha256.${signer}.sig" "${PREFIX}/${arch}/${file}.sha256.${signer}.sig"
        done
        ar_verify_sidecar "${stage}" "${file}"
        # A signature that didn't verify goes no further than here.
        ar_prune_signatures "${stage}" "${file}"
        cached="${CACHE_DIR:+${CACHE_DIR}/${arch}/${file}}"
        if [[ -n "${cached}" && -f "${cached}" && "$(ar_sha256 "${cached}")" == "${AR_SIDECAR_SHA256}" ]]; then
            cp -- "${cached}" "${stage}/${file}"
            reused=$((reused + 1))
        else
            printf '%s\t%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}" "${stage}/${file}" "${fetched}/${file}" "${size}" >> "${fetched}/packages"
            downloaded=$((downloaded + 1))
        fi
    done < "${AR_WORK}/${arch}/entries.tsv"
    ar_get_objects "${fetched}/packages"
    while IFS=$'\t' read -r object package status_file size; do
        ar_require_fetched "${status_file}" "${object}" "$(basename -- "${package}")" "${size}"
    done < "${fetched}/packages"

    ar_verify_packages "${stage}" "${arch}" "${AR_WORK}/${arch}" "${AR_WORK}/receipt/arch/${arch}"
    printf '%s\t%s\n' key "${key}" sha256 "$(ar_sha256 "${stage}/APKINDEX.tar.gz")" etag "${INDEX_ETAG[${arch}]}" \
        version_id "${INDEX_VERSION_ID[${arch}]}" signature ".SIGN.RSA256.${INDEX_KEY[${arch}]}.pub" \
        pinned "$([[ -n "${AR_PIN_SHA256[${arch}]}" ]] && echo true || echo false)" > "${AR_WORK}/receipt/arch/${arch}/index.tsv"
    echo "Verified ${arch}: an index signed with ${INDEX_KEY[${arch}]}, ${downloaded} package(s) downloaded, ${reused} from the cache."
done

# fill_cache ARCH: copies out_dir/ARCH's packages into cache_dir/ARCH. A
# convenience only: any failure is a warning, never a failed pull, since
# out_dir is filled already. Each file is new, renamed into place, so a
# symbolic link left in a restored cache is replaced, never written through,
# and a symbolic link at cache_dir/ARCH itself is left alone.
fill_cache() {
    local arch=$1 dir="${CACHE_DIR}/$1" package target partial
    if [[ -L "${dir}" ]]; then
        ar_warn "cache_dir ${dir} is a symbolic link; leaving it as it is."
        return 0
    fi
    if ! mkdir -p -- "${dir}"; then
        ar_warn "Couldn't create cache_dir ${dir}; the cache isn't updated."
        return 0
    fi
    for package in "${OUT_DIR}/${arch}"/*.apk; do
        [[ -f "${package}" ]] || continue
        target="${dir}/$(basename -- "${package}")"
        [[ -d "${target}" ]] && continue
        partial=""
        if ! partial=$(mktemp "${dir}/.partial.XXXXXX") || ! cp -- "${package}" "${partial}" \
            || ! mv -f -- "${partial}" "${target}"; then
            [[ -n "${partial}" ]] && rm -f -- "${partial}"
            ar_warn "Couldn't add $(basename -- "${package}") to cache_dir ${dir}."
        fi
    done
}

# P-2: only verified repositories reach out_dir, all architectures at once.
mkdir -p -- "${OUT_DIR}"
for arch in "${AR_ARCHES[@]}"; do
    if [[ -d "${OUT_DIR}/${arch}" ]]; then
        rmdir -- "${OUT_DIR}/${arch}"
    fi
    mv -- "${AR_WORK}/stage/${arch}" "${OUT_DIR}/${arch}"
    echo "Pulled $(ar_s3_url "${PREFIX}/${arch}") into ${OUT_DIR}/${arch}."
done
if [[ -n "${CACHE_DIR}" ]]; then
    for arch in "${AR_ARCHES[@]}"; do
        fill_cache "${arch}"
    done
fi
ar_write_receipt "${RECEIPT_PATH}"
