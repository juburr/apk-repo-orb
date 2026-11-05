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
# A pinned read: the index's bytes (a SHA-256 from an earlier receipt) and,
# in a versioned bucket, which version of it to read, so a pull can fetch
# that snapshot again. Packages are immutable, so the index fixes them too.
declare -A PIN_SHA256=() PIN_VERSION_ID=()
for arch in "${AR_ARCHES[@]}"; do
    PIN_SHA256[${arch}]=$(ar_index_sha256 index_sha256 "${INDEX_SHA256}" "${arch}") || exit $?
    PIN_VERSION_ID[${arch}]=$(ar_index_version_id index_version_id "${INDEX_VERSION_ID}" "${arch}") || exit $?
    if [[ -n "${PIN_VERSION_ID[${arch}]}" && -z "${PIN_SHA256[${arch}]}" ]]; then
        ar_usage "index_version_id needs index_sha256: the version says where to find the index, its SHA-256 which one to trust." \
            "Give both from the same receipt (index.sha256 and index.version_id)."
    fi
done
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

for arch in "${AR_ARCHES[@]}"; do
    stage="${AR_WORK}/stage/${arch}"
    mkdir -p "${stage}"
    key="${PREFIX}/${arch}/APKINDEX.tar.gz"
    pinned_sha256=${PIN_SHA256[${arch}]}
    pinned_version=${PIN_VERSION_ID[${arch}]}
    status=0
    ar_get_object "${key}" "${stage}/APKINDEX.tar.gz" "${pinned_version}" || status=$?
    case "${status}" in
        0) ;;
        "${AR_ABSENT}")
            if [[ -n "${pinned_version}" ]]; then
                ar_die "$(ar_s3_url "${key}") has no version ${pinned_version} (index_version_id)." \
                    "Check that it comes from a receipt for this bucket, prefix and arch, and that the version wasn't deleted or expired."
            fi
            ar_die "There is no repository at $(ar_s3_url "${PREFIX}/${arch}"): ${key} doesn't exist." \
                "Check bucket, prefix and arch, or publish to it first." ;;
        "${AR_DENIED}")
            if [[ -n "${pinned_version}" ]]; then
                ar_die "Access to version ${pinned_version} of $(ar_s3_url "${key}") was denied. It may not exist." \
                    "Reading a version needs s3:GetObjectVersion on $(ar_s3_url "${PREFIX}")/* as well as s3:GetObject (README: Bucket Setup)."
            fi
            ar_die "Access to $(ar_s3_url "${key}") was denied. It may not exist." "$(ar_denied_hint "${key}")" ;;
    esac
    etag=${AR_ETAG}
    version_id=${AR_VERSION_ID}
    echo "Read $(ar_s3_url "${key}") (ETag ${etag}${version_id:+, version ${version_id}})."
    # A service that ignores versionId would answer with the current index.
    # ar_get_object reports the version "null" as none.
    expected_version=${pinned_version}
    [[ "${expected_version}" == "null" ]] && expected_version=""
    if [[ -n "${pinned_version}" && "${version_id}" != "${expected_version}" ]]; then
        ar_die "Asked for version ${pinned_version} of $(ar_s3_url "${key}"), the service returned ${version_id:-an unversioned object}." \
            "The service may not support object versions; pin index_sha256 alone there."
    fi
    if [[ -n "${pinned_version}" ]]; then
        ar_check_pinned_index "${stage}/APKINDEX.tar.gz" "${pinned_sha256}" "$(ar_s3_url "${key}") version ${pinned_version}" \
            "That version isn't the index pinned: take index_sha256 and index_version_id from the same receipt."
    else
        ar_check_pinned_index "${stage}/APKINDEX.tar.gz" "${pinned_sha256}" "$(ar_s3_url "${key}")" \
            "The index has changed since. To read the pinned one again from a versioned bucket, set index_version_id too" \
            "(the receipt's index.version_id)."
    fi
    ar_verify_index "${stage}/APKINDEX.tar.gz" "${arch}" "${AR_WORK}/${arch}"

    # Only what the verified index lists: each package's sidecar and its
    # signatures by keyring keys, then the package itself, from the cache
    # when a cached copy matches the signed sidecar. Downloads run in
    # parallel; everything is verified here, one by one.
    fetched="${AR_WORK}/fetched/${arch}"
    mkdir -p "${fetched}"
    : > "${fetched}/sidecars"
    : > "${fetched}/packages"
    while IFS=$'\t' read -r name version _; do
        file="${name}-${version}.apk"
        printf '%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}.sha256" "${stage}/${file}.sha256" "${fetched}/${file}.sha256" >> "${fetched}/sidecars"
        for signer in "${AR_KEY_NAMES[@]}"; do
            printf '%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}.sha256.${signer}.sig" "${stage}/${file}.sha256.${signer}.sig" \
                "${fetched}/${file}.sha256.${signer}.sig" >> "${fetched}/sidecars"
        done
    done < "${AR_WORK}/${arch}/entries.tsv"
    ar_get_objects "${fetched}/sidecars"
    downloaded=0
    reused=0
    while IFS=$'\t' read -r name version _; do
        file="${name}-${version}.apk"
        ar_require_fetched "${fetched}/${file}.sha256" "${PREFIX}/${arch}/${file}.sha256" "${name} ${version}"
        for signer in "${AR_KEY_NAMES[@]}"; do
            ar_optional_fetched "${fetched}/${file}.sha256.${signer}.sig" "${PREFIX}/${arch}/${file}.sha256.${signer}.sig"
        done
        ar_verify_sidecar "${stage}" "${file}"
        cached="${CACHE_DIR:+${CACHE_DIR}/${arch}/${file}}"
        if [[ -n "${cached}" && -f "${cached}" && "$(ar_sha256 "${cached}")" == "${AR_SIDECAR_SHA256}" ]]; then
            cp -- "${cached}" "${stage}/${file}"
            reused=$((reused + 1))
        else
            printf '%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}" "${stage}/${file}" "${fetched}/${file}" >> "${fetched}/packages"
            downloaded=$((downloaded + 1))
        fi
    done < "${AR_WORK}/${arch}/entries.tsv"
    ar_get_objects "${fetched}/packages"
    while IFS=$'\t' read -r object package status_file; do
        ar_require_fetched "${status_file}" "${object}" "$(basename -- "${package}")"
    done < "${fetched}/packages"

    ar_verify_packages "${stage}" "${arch}" "${AR_WORK}/${arch}" "${AR_WORK}/receipt/arch/${arch}"
    printf '%s\t%s\n' key "${key}" sha256 "$(ar_sha256 "${stage}/APKINDEX.tar.gz")" etag "${etag}" \
        version_id "${version_id}" signature ".SIGN.RSA256.${AR_INDEX_KEY}.pub" \
        pinned "$([[ -n "${pinned_sha256}" ]] && echo true || echo false)" > "${AR_WORK}/receipt/arch/${arch}/index.tsv"
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
        if [[ -L "${CACHE_DIR}/${arch}" ]]; then
            ar_warn "cache_dir ${CACHE_DIR}/${arch} is a symbolic link; leaving it as it is."
        else
            for package in "${OUT_DIR}/${arch}"/*.apk; do
                [[ -f "${package}" ]] || continue
                target="${CACHE_DIR}/${arch}/$(basename -- "${package}")"
                [[ -d "${target}" ]] && continue
                # A new file of our own, renamed into place: a symbolic link
                # in a restored cache is replaced, never written through.
                partial=$(mktemp "${CACHE_DIR}/${arch}/.partial.XXXXXX")
                cp -- "${package}" "${partial}"
                mv -f -- "${partial}" "${target}"
            done
        fi
    fi
    echo "Pulled $(ar_s3_url "${PREFIX}/${arch}") into ${OUT_DIR}/${arch}."
done
ar_write_receipt "${RECEIPT_PATH}"
