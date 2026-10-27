#!/bin/bash
set -euo pipefail
#
# publish: adds the packages melange built (<packages_dir>/<arch>/*.apk) to
# a signed APK repository in an S3 bucket. Each package is re-signed with
# the production key and gets a signed SHA-256 sidecar; the packages are
# uploaded first, and then the index, merged with the remote one and
# signed, replaces it only if nobody else changed it meanwhile
# (compare-and-swap with If-Match). Published objects never change: every
# write is a put-object with If-None-Match or If-Match, and nothing is ever
# deleted.
#
# Parameters, as environment variables (the orb command and the GitHub
# Action set them; a standalone run sets them itself):
#   PARAM_BACKEND             Storage backend: s3 (default s3).
#   PARAM_BUCKET              The bucket. Required.
#   PARAM_PREFIX              Key prefix of the repository, such as
#                             my-org/os. Required.
#   PARAM_ENDPOINT_URL        An S3-compatible endpoint (default: AWS).
#   PARAM_REGION              The bucket's region (default: the AWS CLI's).
#   PARAM_ARCH                Architectures to publish, space-separated
#                             x86_64 and aarch64 (default: every
#                             <packages_dir>/<arch> holding packages).
#   PARAM_KEYRING             Public key files (<key>.rsa.pub) and
#                             directories of them to trust, space-separated.
#                             Must hold <key_name>.pub. Required.
#   PARAM_PACKAGES_DIR        melange's output directory (default packages).
#   PARAM_SIGNING_KEY         The NAME of the environment variable holding
#                             the PEM private key (default APK_SIGNING_KEY).
#   PARAM_KEY_NAME            The key's name, <name>.rsa. Required.
#   PARAM_RESIGN              Re-sign the packages with it (default true).
#   PARAM_ALLOW_CREATE        Create the repository if it has no index yet
#                             (default false).
#   PARAM_MAX_ATTEMPTS        Compare-and-swap attempts per architecture
#                             (default 5).
#   PARAM_PUBLISH_PUBLIC_KEY  Upload <prefix>/<key_name>.pub too (default
#                             false).
#   PARAM_S3_CHECKSUMS        Send each upload's SHA-256 for S3 to check
#                             (default true).
#   PARAM_DRY_RUN             Do everything but write (default false).
#   PARAM_RECEIPT_PATH        Where to write the JSON receipt (default
#                             apk-repo-receipt.json).
# Environment variables in the string parameters are expanded when the
# CircleCI CLI is on the PATH. AWS credentials come from the AWS CLI's own
# chain.
#
# Shared code: SCRIPT_APK_REPO_LIB and SCRIPT_APK_REPO_PY hold
# lib/apk_repo.sh and apk_repo.py, from CircleCI's include directive or
# actions/run_script.sh. A standalone run (bash src/scripts/publish.sh)
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

# The private key lives in AR_WORK/key, which this trap removes on every
# exit, failures included.
AR_WORK=$(mktemp -d)
trap 'rm -rf "${AR_WORK}"' EXIT

IMMUTABLE_CACHE="max-age=31536000, immutable"
PROBE_BYTES="apk-repo-orb conditional write probe v1"
FIVE_GIB=$((5 * 1024 * 1024 * 1024))

BACKEND=$(ar_subst "${PARAM_BACKEND:-s3}")
BUCKET=$(ar_subst "${PARAM_BUCKET:-}")
PREFIX=$(ar_subst "${PARAM_PREFIX:-}")
ENDPOINT_URL=$(ar_configured_endpoint "$(ar_subst "${PARAM_ENDPOINT_URL:-}")")
REGION=$(ar_subst "${PARAM_REGION:-}")
ARCH=$(ar_subst "${PARAM_ARCH:-}")
KEYRING=$(ar_subst "${PARAM_KEYRING:-}")
PACKAGES_DIR=$(ar_subst "${PARAM_PACKAGES_DIR:-packages}")
SIGNING_KEY=${PARAM_SIGNING_KEY:-APK_SIGNING_KEY}
KEY_NAME=$(ar_subst "${PARAM_KEY_NAME:-}")
RESIGN=$(ar_bool resign "${PARAM_RESIGN:-true}")
ALLOW_CREATE=$(ar_bool allow_create "${PARAM_ALLOW_CREATE:-false}")
MAX_ATTEMPTS=$(ar_subst "${PARAM_MAX_ATTEMPTS:-5}")
PUBLISH_PUBLIC_KEY=$(ar_bool publish_public_key "${PARAM_PUBLISH_PUBLIC_KEY:-false}")
# shellcheck disable=SC2034 # read by ar_put_object
AR_S3_CHECKSUMS=$(ar_bool s3_checksums "${PARAM_S3_CHECKSUMS:-true}")
DRY_RUN=$(ar_bool dry_run "${PARAM_DRY_RUN:-false}")
RECEIPT_PATH=$(ar_subst "${PARAM_RECEIPT_PATH:-apk-repo-receipt.json}")

ar_check_backend "${BACKEND}"
ar_check_bucket "${BUCKET}"
ar_check_prefix "${PREFIX}"
ar_check_endpoint "${ENDPOINT_URL}"
ar_check_region "${REGION}"
ar_check_key_name "${KEY_NAME}"
ar_check_receipt_path "${RECEIPT_PATH}"
if ! ar_match "${MAX_ATTEMPTS}" '^[1-9][0-9]?$'; then
    ar_usage "max_attempts must be a number from 1 to 99, not '${MAX_ATTEMPTS}'."
fi
if ! ar_match "${SIGNING_KEY}" '^[A-Za-z_][A-Za-z0-9_]*$'; then
    ar_usage "signing_key must be the name of the environment variable that holds the private key, not '${SIGNING_KEY}'."
fi
if [[ ! -d "${PACKAGES_DIR}" ]]; then
    ar_usage "packages_dir ${PACKAGES_DIR} is not a directory."
fi

# U-3: the architectures, and their packages.
if [[ -n "${ARCH//[[:space:]]/}" ]]; then
    ar_arches "${ARCH}"
else
    found=""
    for directory in "${PACKAGES_DIR}"/*/; do
        [[ -d "${directory}" ]] || continue
        name=$(basename -- "${directory}")
        if compgen -G "${PACKAGES_DIR}/${name}/*.apk" > /dev/null; then
            case "${name}" in
                x86_64 | aarch64) found+=" ${name}" ;;
                *) ar_usage "${PACKAGES_DIR}/${name} holds packages, but ${name} is not x86_64 or aarch64." ;;
            esac
        fi
    done
    if [[ -z "${found}" ]]; then
        ar_usage "${PACKAGES_DIR} has no packages: publish takes melange's output, <packages_dir>/<arch>/*.apk."
    fi
    ar_arches "${found}"
fi

# U-1: the tools, then the private key, in a private directory.
ar_need_tools python3 openssl melange
ar_need_aws
# shellcheck disable=SC2034 # filled and read by the lib
declare -A AR_KEYS=()
ar_keyring "${KEYRING}"
if [[ -z "${AR_KEYS[${KEY_NAME}]:-}" ]]; then
    ar_usage "The keyring has no ${KEY_NAME}.pub, the public key of the key that signs the repository (key_name ${KEY_NAME})."
fi
KEY_DIR="${AR_WORK}/key"
KEY_FILE="${KEY_DIR}/${KEY_NAME}"
(umask 077 && mkdir -m 700 -- "${KEY_DIR}")
# The private key: xtrace stays off, and it is only ever written to KEY_FILE.
set +o xtrace
if [[ -z "${!SIGNING_KEY:-}" ]]; then
    ar_usage "${SIGNING_KEY}, the environment variable signing_key names, is empty." \
        "Set it to the PEM private key (or the PEM base64-encoded) from a CircleCI context or a GitHub secret."
fi
(umask 077 && printf '%s\n' "${!SIGNING_KEY}" > "${KEY_FILE}")
if ! grep -q -- '-----BEGIN' "${KEY_FILE}"; then
    if ! (umask 077 && base64 -d < "${KEY_FILE}" > "${KEY_FILE}.pem" 2> /dev/null); then
        ar_usage "${SIGNING_KEY} holds neither a PEM private key nor a base64-encoded one."
    fi
    mv -- "${KEY_FILE}.pem" "${KEY_FILE}"
fi
# -passin pass: makes an encrypted key fail here instead of prompting.
if ! openssl rsa -in "${KEY_FILE}" -passin pass: -noout 2> /dev/null; then
    ar_usage "${SIGNING_KEY} doesn't hold an unencrypted RSA private key in PEM form (melange keygen makes one)."
fi
# melange reads only PKCS#1 keys (BEGIN RSA PRIVATE KEY), which OpenSSL 3
# writes only when asked to; OpenSSL 1.1 has no -traditional and writes it
# anyway.
if ! (umask 077 && { openssl rsa -in "${KEY_FILE}" -passin pass: -traditional -out "${KEY_FILE}.pkcs1" 2> /dev/null \
    || openssl rsa -in "${KEY_FILE}" -passin pass: -out "${KEY_FILE}.pkcs1" 2> /dev/null; }); then
    ar_die "openssl couldn't rewrite the private key in ${SIGNING_KEY} in PKCS#1 form, which melange needs."
fi
mv -- "${KEY_FILE}.pkcs1" "${KEY_FILE}"
# The key is in KEY_FILE now; the tools this script runs (aws, melange,
# python3, and whatever runs them) don't inherit it.
unset -v "${SIGNING_KEY}"
# U-2: it must be the key the keyring names, so no job signs with another.
openssl rsa -in "${KEY_FILE}" -pubout -outform DER -out "${AR_WORK}/derived.der" 2> /dev/null
if ! openssl rsa -pubin -in "${AR_KEYS[${KEY_NAME}]}" -outform DER -out "${AR_WORK}/keyring.der" 2> /dev/null \
    || ! cmp -s -- "${AR_WORK}/derived.der" "${AR_WORK}/keyring.der"; then
    ar_die "The private key in ${SIGNING_KEY} doesn't match ${AR_KEYS[${KEY_NAME}]}, the keyring's ${KEY_NAME}.pub." \
        "Use the private key of ${KEY_NAME}.pub, or put that key's public key in the keyring."
fi

rm -f -- "${RECEIPT_PATH}"
ar_aws_init "${BUCKET}" "${ENDPOINT_URL}" "${REGION}"
mkdir -p "${AR_WORK}/receipt"
ar_receipt_meta tool_version "${AR_TOOL_VERSION}" operation publish dry_run "${DRY_RUN}" backend "${BACKEND}" \
    endpoint_url "${ENDPOINT_URL}" bucket "${BUCKET}" prefix "${PREFIX}" key_name "${KEY_NAME}" started "$(ar_now)"

# signed_by_key: whether the package inspect read last is signed with
# key_name alone, by a signature that verifies (U-4).
signed_by_key() {
    [[ "${INSPECT_SIGNATURES}" == ".SIGN.RSA256.${KEY_NAME}.pub" ]] \
        && ar_openssl_verify "${AR_KEYS[${KEY_NAME}]}" "${AR_WORK}/inspect/signature" "${AR_WORK}/inspect/control"
}

# Staged copies: packages_dir is never modified, and its APKINDEX.tar.gz,
# signed with a build-time key, is never read (U-17).
declare -A PKG_NAME=() PKG_VERSION=() PKG_SHA=() PKG_SIZE=() PKG_CHECKSUM=()

# pkg_key FILE: the PKG_* arrays' key for a staged package, <arch>/<file>,
# since the same file name can be staged for each architecture.
pkg_key() {
    printf '%s/%s\n' "$(basename -- "$(dirname -- "$1")")" "$(basename -- "$1")"
}

# inspect FILE: reads a staged package into the PKG_* arrays.
inspect() {
    local file=$1 key field value size=""
    key=$(pkg_key "${file}")
    mkdir -p "${AR_WORK}/inspect"
    while IFS=$'\t' read -r field value; do
        case "${field}" in
            pkgname) PKG_NAME[${key}]=${value} ;;
            pkgver) PKG_VERSION[${key}]=${value} ;;
            arch) INSPECT_ARCH=${value} ;;
            signatures) INSPECT_SIGNATURES=${value} ;;
            checksum) PKG_CHECKSUM[${key}]=${value} ;;
            size)
                size=${value}
                PKG_SIZE[${key}]=${value}
                ;;
        esac
    done < <(ar_py apk "${file}" "${AR_WORK}/inspect" || echo "failed")
    if [[ -z "${size}" ]]; then
        ar_die "Couldn't read ${file} as an APK package; the error is above."
    fi
}

# write_sidecars FILE: FILE.sha256 and its signature, FILE.sha256.<key_name>.sig.
write_sidecars() {
    local file=$1 key base
    key=$(pkg_key "${file}")
    base=$(basename -- "${file}")
    PKG_SHA[${key}]=$(ar_sha256 "${file}")
    printf '%s  %s\n' "${PKG_SHA[${key}]}" "${base}" > "${file}.sha256"
    if ! openssl dgst -sha256 -sign "${KEY_FILE}" -out "${file}.sha256.${KEY_NAME}.sig" "${file}.sha256"; then
        ar_die "openssl couldn't sign ${base}.sha256 with ${KEY_NAME}."
    fi
}

for arch in "${AR_ARCHES[@]}"; do
    stage="${AR_WORK}/stage/${arch}"
    mkdir -p "${stage}"
    if ! compgen -G "${PACKAGES_DIR}/${arch}/*.apk" > /dev/null; then
        ar_usage "${PACKAGES_DIR}/${arch} has no packages (*.apk)."
    fi
    for package in "${PACKAGES_DIR}/${arch}"/*.apk; do
        base=$(basename -- "${package}")
        if [[ "$(stat -L -c %s -- "${package}")" -gt "${FIVE_GIB}" ]]; then
            ar_die "${package} exceeds 5 GiB; multipart upload is not supported yet."
        fi
        cp -- "${package}" "${stage}/${base}"
        inspect "${stage}/${base}"
        name=${PKG_NAME[${arch}/${base}]}
        version=${PKG_VERSION[${arch}/${base}]}
        if ! ar_match "${name}" "${AR_NAME_RE}" || ! ar_match "${version}" "${AR_VERSION_RE}"; then
            ar_die "${package} is ${name} ${version}; names must match ${AR_NAME_RE} and versions ${AR_VERSION_RE}."
        fi
        if [[ "${base}" != "${name}-${version}.apk" ]]; then
            ar_die "${package} holds ${name} ${version}, so it must be named ${name}-${version}.apk."
        fi
        if [[ "${INSPECT_ARCH}" != "${arch}" ]]; then
            ar_die "${package} is built for ${INSPECT_ARCH}, but it is in ${PACKAGES_DIR}/${arch}."
        fi
    done
    # U-4: re-signed with the production key, which must be the only signer.
    if [[ "${RESIGN}" == "true" ]]; then
        if ! melange sign --signing-key "${KEY_FILE}" "${stage}"/*.apk > "${AR_WORK}/melange.log" 2>&1; then
            cat "${AR_WORK}/melange.log" >&2
            ar_die "melange sign failed for the ${arch} packages; its output is above."
        fi
        for package in "${stage}"/*.apk; do
            inspect "${package}"
            if ! signed_by_key; then
                ar_die "After melange sign, ${package##*/} is signed as '${INSPECT_SIGNATURES}', not only by ${KEY_NAME}," \
                    "or its signature doesn't verify with ${KEY_NAME}.pub."
            fi
        done
    fi
    # U-5: a signed SHA-256 sidecar for each.
    for package in "${stage}"/*.apk; do
        write_sidecars "${package}"
    done
    echo "Prepared $(find "${stage}" -maxdepth 1 -name '*.apk' | wc -l | tr -d ' ') ${arch} package(s) from ${PACKAGES_DIR}/${arch}."
done

# ------------------------------------------------------------------ writes

# backoff ATTEMPT: sleeps a random time up to min(30, 2^(ATTEMPT-1)) seconds.
backoff() {
    local cap=$((1 << ($1 - 1))) milliseconds
    (( cap > 30 )) && cap=30
    milliseconds=$((RANDOM * 32768 + RANDOM))
    milliseconds=$((milliseconds % (cap * 1000 + 1)))
    sleep "$((milliseconds / 1000)).$(printf '%03d' $((milliseconds % 1000)))"
}

# put_immutable KEY FILE CONTENT_TYPE: uploads FILE to KEY, which must not
# exist yet; if it does with the same bytes (an earlier attempt's), that is
# fine. Sets PUT_RESULT to uploaded or existing.
put_immutable() {
    local key=$1 file=$2 type=$3 status attempt=1
    while true; do
        status=0
        ar_put_object "${key}" "${file}" "${type}" "${IMMUTABLE_CACHE}" "*" || status=$?
        case "${status}" in
            0)
                PUT_RESULT=uploaded
                return 0
                ;;
            "${AR_PRECONDITION}" | "${AR_CONFLICT}")
                status=0
                ar_get_object "${key}" "${AR_WORK}/existing" || status=$?
                if [[ "${status}" -eq 0 ]]; then
                    if cmp -s -- "${AR_WORK}/existing" "${file}"; then
                        PUT_RESULT=existing
                        return 0
                    fi
                    PUT_RESULT=different
                    return 0
                fi
                if [[ "${status}" -eq "${AR_DENIED}" ]]; then
                    ar_die "Access to $(ar_s3_url "${key}") was denied." "$(ar_denied_hint "${key}")"
                fi
                ;;
            "${AR_DENIED}") ar_die "Writing $(ar_s3_url "${key}") was denied." \
                "publish needs s3:PutObject and s3:GetObject on $(ar_s3_url "${PREFIX}")/* (README: Bucket Setup)." ;;
            *) ar_die "Writing $(ar_s3_url "${key}") failed unexpectedly (status ${status})." ;;
        esac
        # A concurrent write that hasn't landed yet: wait and look again.
        if (( attempt >= MAX_ATTEMPTS )); then
            ar_die "$(ar_s3_url "${key}") kept conflicting with another write; giving up after ${MAX_ATTEMPTS} attempts."
        fi
        backoff "${attempt}"
        attempt=$((attempt + 1))
    done
}

# probe: F-13 to F-16. Proves the backend enforces both preconditions,
# with byte-identical writes only.
probe() {
    local key="${PREFIX}/.apk-repo-orb/probe" status
    printf '%s\n' "${PROBE_BYTES}" > "${AR_WORK}/probe"
    status=0
    ar_put_object "${key}" "${AR_WORK}/probe" application/octet-stream "${IMMUTABLE_CACHE}" "*" || status=$?
    case "${status}" in
        0 | "${AR_PRECONDITION}" | "${AR_CONFLICT}") ;;
        "${AR_DENIED}") ar_die "Writing $(ar_s3_url "${key}") was denied." \
            "publish needs s3:PutObject and s3:GetObject on $(ar_s3_url "${PREFIX}")/* (README: Bucket Setup)." ;;
        *) ar_die "Writing $(ar_s3_url "${key}") failed unexpectedly (status ${status})." ;;
    esac
    status=0
    ar_put_object "${key}" "${AR_WORK}/probe" application/octet-stream "${IMMUTABLE_CACHE}" "*" || status=$?
    if [[ "${status}" -eq 0 ]]; then
        ar_die "${ENDPOINT_URL:-AWS S3} does not enforce S3 conditional writes; refusing to publish." \
            "A second write of $(ar_s3_url "${key}") with If-None-Match: * succeeded, so packages could be overwritten."
    elif [[ "${status}" -ne "${AR_PRECONDITION}" && "${status}" -ne "${AR_CONFLICT}" ]]; then
        ar_die "The If-None-Match probe of $(ar_s3_url "${key}") failed unexpectedly (status ${status})."
    fi
    status=0
    ar_put_object "${key}" "${AR_WORK}/probe" application/octet-stream "${IMMUTABLE_CACHE}" \
        '"00000000000000000000000000000000"' || status=$?
    if [[ "${status}" -eq 0 ]]; then
        ar_die "${ENDPOINT_URL:-AWS S3} does not enforce S3 conditional writes; refusing to publish." \
            "A write of $(ar_s3_url "${key}") with an If-Match that can't match succeeded, so the index could lose updates."
    elif [[ "${status}" -ne "${AR_PRECONDITION}" && "${status}" -ne "${AR_CONFLICT}" ]]; then
        ar_die "The If-Match probe of $(ar_s3_url "${key}") failed unexpectedly (status ${status})."
    fi
    echo "${ENDPOINT_URL:-AWS S3} enforces conditional writes (If-None-Match and If-Match)."
}

# remote_sidecar ARCH FILE DIR: downloads FILE's sidecar and its signatures
# by keyring keys into DIR, and verifies them (S-4). Sets AR_SIDECAR_SHA256.
remote_sidecar() {
    local arch=$1 file=$2 dir=$3 status signer
    mkdir -p "${dir}"
    status=0
    ar_get_object "${PREFIX}/${arch}/${file}.sha256" "${dir}/${file}.sha256" || status=$?
    case "${status}" in
        0) ;;
        "${AR_ABSENT}") ar_die "$(ar_s3_url "${PREFIX}/${arch}/${file}.sha256") is missing, though the index lists ${file}." ;;
        *) ar_die "Access to $(ar_s3_url "${PREFIX}/${arch}/${file}.sha256") was denied." "$(ar_denied_hint "${PREFIX}/${arch}/${file}")" ;;
    esac
    for signer in "${AR_KEY_NAMES[@]}"; do
        status=0
        ar_get_object "${PREFIX}/${arch}/${file}.sha256.${signer}.sig" "${dir}/${file}.sha256.${signer}.sig" || status=$?
        if [[ "${status}" -eq "${AR_DENIED}" ]]; then
            ar_die "Access to $(ar_s3_url "${PREFIX}/${arch}/${file}.sha256.${signer}.sig") was denied."
        fi
    done
    ar_verify_sidecar "${dir}" "${file}"
}

# segments FILE: "<control SHA-256> <data SHA-256>" of a package, or
# nothing when it isn't one.
segments() {
    local field value control="" data=""
    mkdir -p "${AR_WORK}/segments"
    while IFS=$'\t' read -r field value; do
        case "${field}" in
            control_sha256) control=${value} ;;
            data_sha256) data=${value} ;;
        esac
    done < <(ar_py apk "$1" "${AR_WORK}/segments" 2> /dev/null || true)
    if [[ -n "${control}" ]]; then
        printf '%s %s\n' "${control}" "${data}"
    fi
}

# same_package A B: whether two packages have the same control and data
# segments: the same package, whatever signs it.
same_package() {
    local a b
    a=$(segments "$1")
    b=$(segments "$2")
    [[ -n "${a}" && "${a}" == "${b}" ]]
}

# adopt ARCH FILE: FILE's key already holds AR_WORK/existing, which isn't
# the staged package: left by a publish that never reached the index (U-7).
# It is used instead of the staged copy only when it is the same package,
# signed with key_name alone (U-4), so a sidecar never vouches for another
# signature; anything else is immutable and fails.
adopt() {
    local arch=$1 file=$2 stage="${AR_WORK}/stage/$1" url
    url=$(ar_s3_url "${PREFIX}/${arch}/${file}")
    if ! same_package "${AR_WORK}/existing" "${stage}/${file}"; then
        ar_die "${url} already exists with different contents; packages are immutable." \
            "Publish this build under a new version or epoch (-r<N>)."
    fi
    if [[ "${RESIGN}" != "true" ]]; then
        ar_die "${url} already exists, the same package signed differently, and resign is off; packages are immutable." \
            "Publish with resign, or under a new version or epoch (-r<N>)."
    fi
    cp -- "${AR_WORK}/existing" "${stage}/${file}"
    inspect "${stage}/${file}"
    if ! signed_by_key; then
        ar_die "${url} already exists, the same package signed as '${INSPECT_SIGNATURES}', not only by ${KEY_NAME}; packages are immutable." \
            "Publish this build under a new version or epoch (-r<N>)."
    fi
    write_sidecars "${stage}/${file}"
    echo "${arch}: ${file} was already uploaded by an earlier publish that didn't finish; using it."
}

# sidecar_ok ARCH FILE OBJECT: whether AR_WORK/existing, found at the key of
# OBJECT (FILE's .sha256 or its key_name signature), is acceptable though it
# isn't the staged copy: only a signature that verifies over the staged
# sidecar with key_name.pub, as one made earlier would. Anything else is
# immutable and must not be replaced.
sidecar_ok() {
    [[ "$3" == *.sig ]] && ar_openssl_verify "${AR_KEYS[${KEY_NAME}]}" "${AR_WORK}/existing" "${AR_WORK}/stage/$1/$2.sha256"
}

# receipt_shas ARCH ENTRIES: the SHA-256 of every package ENTRIES lists, from
# its sidecar, verified (S-4), for the receipt. Fetched before the index is
# written, so nothing after that can fail, and kept across attempts.
receipt_shas() {
    local arch=$1 name version file signer dir="${AR_WORK}/receipt-sidecars/$1" list
    local -a missing=()
    mkdir -p "${dir}"
    list=$(mktemp "${AR_WORK}/fetch.XXXXXX")
    while IFS=$'\t' read -r name version _; do
        file="${name}-${version}.apk"
        [[ -n "${PKG_SHA[${arch}/${file}]:-}" ]] && continue
        missing+=("${file}")
        printf '%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}.sha256" "${dir}/${file}.sha256" "${dir}/${file}.sha256.status" >> "${list}"
        for signer in "${AR_KEY_NAMES[@]}"; do
            printf '%s\t%s\t%s\n' "${PREFIX}/${arch}/${file}.sha256.${signer}.sig" "${dir}/${file}.sha256.${signer}.sig" \
                "${dir}/${file}.sha256.${signer}.sig.status" >> "${list}"
        done
    done < "$2"
    # Fetched in parallel (an index can list hundreds of packages), then
    # verified one by one.
    ar_get_objects "${list}"
    for file in ${missing[@]+"${missing[@]}"}; do
        ar_require_fetched "${dir}/${file}.sha256.status" "${PREFIX}/${arch}/${file}.sha256" "${file}"
        for signer in "${AR_KEY_NAMES[@]}"; do
            ar_optional_fetched "${dir}/${file}.sha256.${signer}.sig.status" "${PREFIX}/${arch}/${file}.sha256.${signer}.sig"
        done
        ar_verify_sidecar "${dir}" "${file}"
        PKG_SHA[${arch}/${file}]=${AR_SIDECAR_SHA256}
    done
}

# publish_arch ARCH: the compare-and-swap loop for one architecture (U-6 to
# U-10). Runs in a subshell, so a failure ends only this architecture.
publish_arch() {
    local arch=$1 attempt=0 key status creating etag version_id="" index_key remote build="" out file name version
    local stage="${AR_WORK}/stage/${arch}" receipt="${AR_WORK}/receipt/arch/${arch}" entries
    local -a new skipped
    key="${PREFIX}/${arch}/APKINDEX.tar.gz"
    mkdir -p "${receipt}"
    while true; do
        attempt=$((attempt + 1))
        remote="${AR_WORK}/remote/${arch}/${attempt}"
        mkdir -p "${remote}"
        # U-6: the remote index, verified before anything relies on it.
        status=0
        ar_get_object "${key}" "${remote}/APKINDEX.tar.gz" || status=$?
        case "${status}" in
            0)
                creating=false
                etag=${AR_ETAG}
                version_id=${AR_VERSION_ID}
                ar_verify_index "${remote}/APKINDEX.tar.gz" "${arch}" "${remote}/index"
                index_key=${AR_INDEX_KEY}
                ;;
            "${AR_ABSENT}")
                if [[ "${ALLOW_CREATE}" != "true" ]]; then
                    ar_die "no repository at $(ar_s3_url "${PREFIX}/${arch}"); set allow_create to create it."
                fi
                creating=true
                etag=""
                mkdir -p "${remote}/index"
                : > "${remote}/index/entries.tsv"
                ;;
            *) ar_die "Access to $(ar_s3_url "${key}") was denied. It may not exist." "$(ar_denied_hint "${key}")" ;;
        esac
        declare -A listed=()
        while IFS=$'\t' read -r name version _; do
            listed[${name}-${version}.apk]=1
        done < "${remote}/index/entries.tsv"
        new=()
        skipped=()
        for package in "${stage}"/*.apk; do
            file=$(basename -- "${package}")
            if [[ -z "${listed[${file}]:-}" ]]; then
                new+=("${file}")
                continue
            fi
            # Already published: it must be this very package.
            remote_sidecar "${arch}" "${file}" "${remote}/packages"
            if [[ "${AR_SIDECAR_SHA256}" != "${PKG_SHA[${arch}/${file}]}" ]]; then
                status=0
                ar_get_object "${PREFIX}/${arch}/${file}" "${remote}/packages/${file}" || status=$?
                case "${status}" in
                    0) ;;
                    "${AR_ABSENT}") ar_die "$(ar_s3_url "${PREFIX}/${arch}/${file}") is missing, though the index lists it." \
                        "The repository is incomplete; restore the object, or publish under a new version or epoch (-r<N>)." ;;
                    *) ar_die "Access to $(ar_s3_url "${PREFIX}/${arch}/${file}") was denied." "$(ar_denied_hint "${PREFIX}/${arch}/${file}")" ;;
                esac
                if [[ "$(ar_sha256 "${remote}/packages/${file}")" != "${AR_SIDECAR_SHA256}" ]] \
                    || ! same_package "${remote}/packages/${file}" "${package}"; then
                    ar_die "$(ar_s3_url "${PREFIX}/${arch}/${file}") is already published with different contents; packages are immutable." \
                        "Publish this build under a new version or epoch (-r<N>)."
                fi
                # The same package, signed differently: keep the published one.
                PKG_SHA[${arch}/${file}]=${AR_SIDECAR_SHA256}
            fi
            skipped+=("${file}")
        done
        unset listed
        # U-7: the new packages' objects before the index, so no index ever
        # lists a package that isn't there.
        if [[ "${DRY_RUN}" == "true" ]]; then
            # What a real run would find at the new packages' keys.
            for file in ${new[@]+"${new[@]}"}; do
                status=0
                ar_get_object "${PREFIX}/${arch}/${file}" "${AR_WORK}/existing" || status=$?
                case "${status}" in
                    0) cmp -s -- "${AR_WORK}/existing" "${stage}/${file}" || adopt "${arch}" "${file}" ;;
                    "${AR_ABSENT}") ;;
                    *) ar_die "Access to $(ar_s3_url "${PREFIX}/${arch}/${file}") was denied." "$(ar_denied_hint "${PREFIX}/${arch}/${file}")" ;;
                esac
                for object in "${file}.sha256" "${file}.sha256.${KEY_NAME}.sig"; do
                    status=0
                    ar_get_object "${PREFIX}/${arch}/${object}" "${AR_WORK}/existing" || status=$?
                    case "${status}" in
                        0)
                            if ! cmp -s -- "${AR_WORK}/existing" "${stage}/${object}" && ! sidecar_ok "${arch}" "${file}" "${object}"; then
                                ar_die "$(ar_s3_url "${PREFIX}/${arch}/${object}") already exists with different contents; it is immutable."
                            fi
                            ;;
                        "${AR_ABSENT}") ;;
                        *) ar_die "Access to $(ar_s3_url "${PREFIX}/${arch}/${object}") was denied." "$(ar_denied_hint "${PREFIX}/${arch}/${object}")" ;;
                    esac
                done
            done
        else
            for file in ${new[@]+"${new[@]}"}; do
                put_immutable "${PREFIX}/${arch}/${file}" "${stage}/${file}" application/octet-stream
                if [[ "${PUT_RESULT}" == "different" ]]; then
                    adopt "${arch}" "${file}"
                fi
                for object in "${file}.sha256" "${file}.sha256.${KEY_NAME}.sig"; do
                    put_immutable "${PREFIX}/${arch}/${object}" "${stage}/${object}" application/octet-stream
                    if [[ "${PUT_RESULT}" == "different" ]] && ! sidecar_ok "${arch}" "${file}" "${object}"; then
                        ar_die "$(ar_s3_url "${PREFIX}/${arch}/${object}") already exists with different contents; it is immutable."
                    fi
                done
            done
        fi
        if [[ ${#new[@]} -eq 0 && "${creating}" == "true" ]]; then
            ar_die "No ${arch} index exists, and there are no packages to create it with."
        fi
        if [[ ${#new[@]} -eq 0 && "${index_key}" == "${KEY_NAME}" ]]; then
            echo "${arch}: every package is already published; the index stays as it is."
            out="${remote}/APKINDEX.tar.gz"
            entries="${remote}/index/entries.tsv"
            receipt_shas "${arch}" "${entries}"
            break
        fi
        build="${AR_WORK}/build/${arch}/${attempt}"
        mkdir -p "${build}"
        out="${build}/APKINDEX.tar.gz"
        if [[ ${#new[@]} -eq 0 ]]; then
            # S-8: key_name changed, and the index is still signed with the
            # old key. The same entries, signed with key_name.
            echo "${arch}: every package is already published, but the index is signed with ${index_key}; signing it with ${KEY_NAME}."
            if ! openssl dgst -sha256 -sign "${KEY_FILE}" -out "${build}/signature" "${remote}/index/signed"; then
                ar_die "openssl couldn't sign the ${arch} index with ${KEY_NAME}."
            fi
            ar_py index-sign "${KEY_NAME}" "${build}/signature" "${remote}/index/signed" "${out}" || exit 1
        else
            # U-9: the merged index, written to a fresh path and checked.
            local -a args=(index --output "${out}" --signing-key "${KEY_FILE}")
            if [[ "${creating}" != "true" ]]; then
                args+=(--merge --source "${remote}/APKINDEX.tar.gz")
            fi
            local -a paths=()
            for file in "${new[@]}"; do
                paths+=("${stage}/${file}")
            done
            if ! melange "${args[@]}" "${paths[@]}" > "${build}/melange.log" 2>&1; then
                cat "${build}/melange.log" >&2
                ar_die "melange index failed for ${arch}; its output is above."
            fi
            if [[ ! -s "${out}" ]]; then
                ar_die "melange index wrote no ${arch} index."
            fi
        fi
        ar_verify_index "${out}" "${arch}" "${build}/index"
        if [[ "${AR_INDEX_KEY}" != "${KEY_NAME}" ]]; then
            ar_die "The new ${arch} index is signed with ${AR_INDEX_KEY}, not ${KEY_NAME}."
        fi
        check_merge "${arch}" "${remote}/index/entries.tsv" "${build}/index/entries.tsv" ${new[@]+"${new[@]}"}
        index_key=${KEY_NAME}
        entries="${build}/index/entries.tsv"
        receipt_shas "${arch}" "${entries}"
        if [[ "${DRY_RUN}" == "true" ]]; then
            if [[ ${#new[@]} -eq 0 ]]; then
                echo "${arch}: would sign the index with ${KEY_NAME}."
            else
                echo "${arch}: would publish ${new[*]}${skipped[0]:+ (already published: ${skipped[*]})}."
            fi
            etag=""
            version_id=""
            break
        fi
        # U-10: replace the index only if it is still the one read above.
        status=0
        ar_put_object "${key}" "${out}" application/gzip no-cache "${etag:-*}" || status=$?
        case "${status}" in
            0)
                etag=${AR_ETAG}
                version_id=${AR_VERSION_ID}
                echo "${arch}: published ${new[*]:-no new packages} ($(ar_s3_url "${key}") is now ETag ${etag}, signed with ${KEY_NAME})."
                break
                ;;
            "${AR_PRECONDITION}" | "${AR_CONFLICT}" | "${AR_ABSENT}")
                if (( attempt >= MAX_ATTEMPTS )); then
                    ar_die "$(ar_s3_url "${key}") kept changing while ${arch} was being published; gave up after ${MAX_ATTEMPTS} attempts." \
                        "Another publish is writing the same repository; run this one again, or raise max_attempts."
                fi
                echo "${arch}: the index changed while publishing (attempt ${attempt}); merging again."
                backoff "${attempt}"
                ;;
            *) ar_die "Writing $(ar_s3_url "${key}") was denied." \
                "publish needs s3:PutObject and s3:GetObject on $(ar_s3_url "${PREFIX}")/* (README: Bucket Setup)." ;;
        esac
    done

    # The receipt: the resulting index (in a dry run, the one that would
    # have been uploaded), and every package it lists.
    printf '%s\t%s\n' key "${key}" sha256 "$(ar_sha256 "${out}")" etag "${etag}" version_id "${version_id}" \
        signature ".SIGN.RSA256.${index_key}.pub" > "${receipt}/index.tsv"
    : > "${receipt}/packages.tsv"
    while IFS=$'\t' read -r name version _ size _; do
        file="${name}-${version}.apk"
        printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${version}" "${file}" "${PKG_SHA[${arch}/${file}]}" "${size}" >> "${receipt}/packages.tsv"
    done < "${entries}"
    printf '%s\n' ${new[@]+"${new[@]}"} > "${receipt}/published"
    printf '%s\n' ${skipped[@]+"${skipped[@]}"} > "${receipt}/skipped_identical"
    echo "${attempt}" > "${receipt}/attempts"
}

# check_merge ARCH REMOTE_ENTRIES NEW_ENTRIES FILE...: U-9 (b) and (c).
# The new index holds exactly the remote entries, unchanged, plus FILE...,
# each with the size and checksum of the package staged for ARCH.
check_merge() {
    local target=$1 remote=$2 built=$3 file name version arch size checksum digest expected
    shift 3
    local -A have=()
    while IFS=$'\t' read -r name version arch size checksum digest; do
        have[${name}-${version}.apk]="${arch} ${size} ${checksum} ${digest}"
    done < "${built}"
    expected=$(( $(wc -l < "${remote}") + $# ))
    if [[ ${#have[@]} -ne ${expected} ]]; then
        ar_die "melange's merged index has ${#have[@]} packages, not the ${expected} expected; refusing to publish it."
    fi
    while IFS=$'\t' read -r name version arch size checksum digest; do
        if [[ "${have[${name}-${version}.apk]:-}" != "${arch} ${size} ${checksum} ${digest}" ]]; then
            ar_die "melange's merged index changed or dropped ${name} ${version}; refusing to publish it."
        fi
    done < "${remote}"
    # Bash 4.0 takes an empty "$@" for an unbound variable.
    [[ $# -gt 0 ]] || return 0
    for file in "$@"; do
        read -r arch size checksum digest <<< "${have[${file}]:-}"
        if [[ "${size}" != "${PKG_SIZE[${target}/${file}]}" || "${checksum}" != "${PKG_CHECKSUM[${target}/${file}]}" ]]; then
            ar_die "melange's merged index lists ${file} with a size or checksum that isn't the package's; refusing to publish it."
        fi
    done
}

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Dry run: nothing will be written."
else
    probe
    if [[ "${PUBLISH_PUBLIC_KEY}" == "true" ]]; then
        put_immutable "${PREFIX}/${KEY_NAME}.pub" "${AR_KEYS[${KEY_NAME}]}" application/octet-stream
        if [[ "${PUT_RESULT}" == "different" ]]; then
            ar_die "$(ar_s3_url "${PREFIX}/${KEY_NAME}.pub") already exists with a different key; it is immutable."
        fi
        echo "Uploaded $(ar_s3_url "${PREFIX}/${KEY_NAME}.pub"), a convenience copy that is never a trust anchor."
    fi
fi

published=()
failed=()
for arch in "${AR_ARCHES[@]}"; do
    # Not "if (publish_arch ...)": bash ignores errexit inside a condition,
    # so the subshell sets it itself, outside one.
    set +e
    (
        set -e
        publish_arch "${arch}"
    )
    status=$?
    set -e
    if [[ "${status}" -eq 0 ]]; then
        published+=("${arch}")
    else
        failed+=("${arch}")
    fi
done
if [[ ${#failed[@]} -gt 0 ]]; then
    ar_die "Publishing failed for ${failed[*]}${published[0]:+; ${published[*]} published}."
fi
ar_write_receipt "${RECEIPT_PATH}"
