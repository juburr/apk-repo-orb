#!/bin/bash
# shellcheck disable=SC2034 # the scripts that eval this file read its variables

# Helpers shared by apk-repo-orb's scripts. It only defines functions and
# variables: the scripts eval it, from SCRIPT_APK_REPO_LIB (CircleCI's
# << include() >>, and actions/run_script.sh on GitHub Actions) or from
# this file when they run standalone (ar_load in each script).
#
# Functions that a script's caller may name a failure for return a status
# instead of exiting: ar_get_object and ar_put_object return 0, or one of
# the AR_* codes below.

AR_TOOL_VERSION="0.1.0"

# The same patterns as apk_repo.py; tests/wiring_test.sh checks that.
AR_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
AR_VERSION_RE='^[0-9A-Za-z._+~-]+-r[0-9]+$'
AR_KEY_RE='^[A-Za-z0-9][A-Za-z0-9._-]*\.rsa$'
AR_SEGMENT_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# Status codes of ar_get_object and ar_put_object.
AR_ABSENT=3
AR_DENIED=4
AR_PRECONDITION=5
AR_CONFLICT=6

# The oldest AWS CLI v2 whose s3api put-object takes --if-match; 2.17.34
# added --if-none-match.
AR_AWS_MIN_VERSION="2.22.5"

# ar_die MESSAGE...: prints an ERROR: line per argument and exits 1.
ar_die() {
    local first=1 line
    for line in "$@"; do
        if [[ "${first}" -eq 1 ]]; then
            printf 'ERROR: %s\n' "${line}" >&2
            first=0
        else
            printf '  %s\n' "${line}" >&2
        fi
    done
    exit 1
}

# ar_usage MESSAGE...: as ar_die, for a parameter error (exit 2).
ar_usage() {
    local first=1 line
    for line in "$@"; do
        if [[ "${first}" -eq 1 ]]; then
            printf 'ERROR: %s\n' "${line}" >&2
            first=0
        else
            printf '  %s\n' "${line}" >&2
        fi
    done
    exit 2
}

ar_warn() {
    printf 'WARN: %s\n' "$1" >&2
}

# ar_subst VALUE: expands environment variables in VALUE with the CircleCI
# CLI, which reads it on stdin. Without the CLI (GitHub Actions, standalone
# runs) the value is used as it is.
ar_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# ar_bool NAME VALUE: prints true or false. CircleCI passes booleans as 1 or
# 0; GitHub Actions and standalone runs pass true or false.
ar_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) ar_usage "$1 must be true or false, not '$2'." ;;
    esac
}

# ar_match VALUE REGEX: [[ =~ ]] in the C locale, where [A-Z] is only A to Z.
ar_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

ar_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ar_sha256 FILE: the file's SHA-256, in hex.
ar_sha256() {
    local sum
    sum=$(sha256sum -- "$1")
    printf '%s\n' "${sum%% *}"
}

# ar_py COMMAND ARGS...: runs apk_repo.py.
ar_py() {
    python3 -I -c "${SCRIPT_APK_REPO_PY}" "$@"
}

# ar_need_tools TOOL...: fails when a tool is missing, naming where to get
# it. Python needs 3.8 or newer.
ar_need_tools() {
    local tool
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                python3) ar_die "python3 (3.8 or newer) is not on the PATH." "Use an executor image that has it, such as cimg/python or a machine executor, or install it in an earlier step." ;;
                openssl) ar_die "openssl is not on the PATH. Install the OpenSSL CLI in an earlier step." ;;
                aws) ar_die "The AWS CLI (aws, v2 ${AR_AWS_MIN_VERSION} or newer) is not on the PATH." "Install it in an earlier step, for example with the circleci/aws-cli orb." ;;
                melange) ar_die "melange is not on the PATH. Run melange-orb's install command (or its GitHub Action) in an earlier step." ;;
                *) ar_die "${tool} is not on the PATH." ;;
            esac
        fi
    done
    if [[ " $* " == *" python3 "* ]] && ! python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
        ar_die "$(python3 --version 2>&1) is too old; apk-repo-orb needs Python 3.8 or newer."
    fi
}

# ar_need_aws: the AWS CLI must make conditional writes. Its put-object
# skeleton lists IfMatch and IfNoneMatch when it can, with no credentials
# or network needed ('help' would need groff, which cimg/base lacks).
ar_need_aws() {
    local skeleton version
    ar_need_tools aws
    skeleton=$(aws s3api put-object --generate-cli-skeleton 2> /dev/null) || true
    if [[ "${skeleton}" != *'"IfMatch"'* || "${skeleton}" != *'"IfNoneMatch"'* ]]; then
        version=$(aws --version 2>&1 | awk 'NR == 1') || true
        ar_die "The AWS CLI on the PATH (${version:-version unknown}) can't make conditional writes (put-object --if-match and --if-none-match)." \
            "Install AWS CLI v2 ${AR_AWS_MIN_VERSION} or newer in an earlier step."
    fi
}

# ar_machine_arch: the machine's architecture, as APK names it.
ar_machine_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) ar_usage "This machine is $(uname -m); apk-repo-orb handles x86_64 and aarch64." ;;
    esac
}

# ar_arches VALUE: sets AR_ARCHES from a space-separated list of x86_64 and
# aarch64, without repeats. An empty list is left empty.
ar_arches() {
    local arch
    AR_ARCHES=()
    for arch in $1; do
        case "${arch}" in
            x86_64 | aarch64) ;;
            *) ar_usage "arch must list x86_64 and/or aarch64, not '${arch}'." ;;
        esac
        if [[ " ${AR_ARCHES[*]+${AR_ARCHES[*]}} " != *" ${arch} "* ]]; then
            AR_ARCHES+=("${arch}")
        fi
    done
}

# ar_check_prefix VALUE: F-2's prefix rule.
ar_check_prefix() {
    local segment
    local -a segments
    if [[ -z "$1" ]]; then
        ar_usage "prefix is required, for example my-org/os."
    fi
    if [[ "$1" == /* || "$1" == */ || "$1" == *//* ]]; then
        ar_usage "prefix '$1' must not start or end with / or have an empty segment."
    fi
    IFS=/ read -r -a segments <<< "$1"
    for segment in "${segments[@]}"; do
        if [[ "${segment}" == ".." ]] || ! ar_match "${segment}" "${AR_SEGMENT_RE}"; then
            ar_usage "prefix '$1' has a segment, '${segment}', that isn't letters, digits, '.', '_' and '-' starting with a letter or digit."
        fi
    done
}

ar_check_bucket() {
    if [[ -z "$1" ]]; then
        ar_usage "bucket is required."
    fi
    if (( ${#1} > 255 )) || ! ar_match "$1" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        ar_usage "bucket '$1' isn't a bucket name (letters, digits, '.', '_' and '-')."
    fi
}

ar_check_key_name() {
    if [[ -z "$1" ]]; then
        ar_usage "key_name is required, for example my-org-apk.rsa."
    fi
    if ! ar_match "$1" "${AR_KEY_RE}"; then
        ar_usage "key_name '$1' must be letters, digits, '.', '_' and '-' ending in .rsa, such as my-org-apk.rsa." \
            "apko only accepts index signatures named .SIGN.RSA256.<name>.rsa.pub."
    fi
}

ar_check_backend() {
    if [[ "$1" != "s3" ]]; then
        ar_usage "backend must be s3, not '$1'."
    fi
}

# ar_check_endpoint VALUE: https://, or http:// to this machine.
ar_check_endpoint() {
    local rest host
    [[ -z "$1" ]] && return 0
    if [[ "$1" == *[[:space:]]* || "$1" == *[?#]* ]]; then
        ar_usage "endpoint_url '$1' must be a plain URL, without spaces, a query or a fragment."
    fi
    case "$1" in
        https://*) rest=${1#https://} ;;
        http://*)
            rest=${1#http://}
            host=${rest%%/*}
            host=${host%:*}
            case "${host}" in
                localhost | 127.0.0.1 | '[::1]') ;;
                *) ar_usage "endpoint_url '$1' must be https://; http:// is only allowed to this machine (localhost)." ;;
            esac
            ;;
        *) ar_usage "endpoint_url '$1' must start with https://." ;;
    esac
    host=${rest%%/*}
    if [[ -z "${host}" || "${host}" == *@* ]]; then
        ar_usage "endpoint_url '$1' must name a host, without credentials."
    fi
}

ar_check_region() {
    if [[ -n "$1" ]] && ! ar_match "$1" '^[a-z0-9-]+$'; then
        ar_usage "region '$1' isn't a region name such as us-east-1."
    fi
}

# ar_keyring VALUE: loads the keyring: space-separated public key files
# named <key>.rsa.pub, and directories whose *.rsa.pub files are added.
# Sets AR_KEYS[<key>.rsa]=path and AR_KEY_NAMES (sorted). The keyring only
# ever comes from these paths, never from the bucket (S-3).
ar_keyring() {
    local entry file base found
    AR_KEYS=()
    AR_KEY_NAMES=()
    if [[ -z "${1//[[:space:]]/}" ]]; then
        ar_usage "keyring is required: the public key files (<key>.rsa.pub), or directories of them, to trust."
    fi
    for entry in $1; do
        if [[ -d "${entry}" ]]; then
            found=0
            for file in "${entry}"/*.rsa.pub; do
                [[ -f "${file}" ]] || continue
                ar_keyring_add "${file}"
                found=1
            done
            if [[ "${found}" -eq 0 ]]; then
                ar_usage "keyring directory ${entry} holds no *.rsa.pub files."
            fi
        elif [[ -f "${entry}" ]]; then
            ar_keyring_add "${entry}"
        else
            ar_usage "keyring entry ${entry} is not a file or directory."
        fi
    done
    for base in "${!AR_KEYS[@]}"; do
        AR_KEY_NAMES+=("${base}")
    done
    # The keys' order only decides which signatures pull fetches first.
    IFS=$'\n' read -r -d '' -a AR_KEY_NAMES < <(printf '%s\n' "${AR_KEY_NAMES[@]}" | LC_ALL=C sort && printf '\0') || true
}

ar_keyring_add() {
    local base key
    base=$(basename -- "$1")
    key=${base%.pub}
    if [[ "${base}" != *.rsa.pub ]] || ! ar_match "${key}" "${AR_KEY_RE}"; then
        ar_usage "keyring file $1 must be named <key>.rsa.pub, with <key> letters, digits, '.', '_' and '-'."
    fi
    if ! openssl pkey -pubin -in "$1" -noout 2> /dev/null; then
        ar_usage "keyring file $1 is not a PEM public key."
    fi
    if [[ -n "${AR_KEYS[${key}]:-}" ]] && ! cmp -s -- "${AR_KEYS[${key}]}" "$1"; then
        ar_usage "The keyring has two different files named ${base}: ${AR_KEYS[${key}]} and $1."
    fi
    AR_KEYS["${key}"]=$1
}

# ar_openssl_verify PUBKEY SIGNATURE FILE: RSA PKCS#1 v1.5 with SHA-256.
ar_openssl_verify() {
    openssl dgst -sha256 -verify "$1" -signature "$2" "$3" > /dev/null 2>&1
}

# ar_verify_index FILE ARCH WORKDIR: V-3 and V-4. Splits and checks the
# signed index FILE for ARCH, leaving WORKDIR/entries.tsv (apk_repo.py's
# index) and setting AR_INDEX_KEY to the key that signed it.
ar_verify_index() {
    local file=$1 arch=$2 work=$3
    mkdir -p "${work}"
    AR_INDEX_KEY=$(ar_py index "${file}" "${arch}" "${work}") || exit 1
    if [[ -z "${AR_KEYS[${AR_INDEX_KEY}]:-}" ]]; then
        ar_die "${file} is signed with ${AR_INDEX_KEY}, and the keyring has no ${AR_INDEX_KEY}.pub." \
            "Add ${AR_INDEX_KEY}.pub to keyring if you trust that key."
    fi
    if ! ar_openssl_verify "${AR_KEYS[${AR_INDEX_KEY}]}" "${work}/signature" "${work}/signed"; then
        ar_die "${file}'s signature doesn't verify with ${AR_KEYS[${AR_INDEX_KEY}]}: the index was changed, or signed with another key."
    fi
}

# ar_verify_sidecar DIR FILE: the FILE.sha256 sidecar in DIR is exactly the
# line '<sha256>  FILE', and a signature on it by a keyring key verifies.
# Sets AR_SIDECAR_SHA256 and AR_SIDECAR_KEYS (the keys whose signature
# verified).
ar_verify_sidecar() {
    local dir=$1 file=$2 key signature
    if [[ ! -f "${dir}/${file}.sha256" || -L "${dir}/${file}.sha256" ]]; then
        ar_die "${dir}/${file}.sha256 is missing."
    fi
    AR_SIDECAR_SHA256=$(head -c 64 -- "${dir}/${file}.sha256")
    printf '%s  %s\n' "${AR_SIDECAR_SHA256}" "${file}" > "${AR_WORK}/expected.sha256"
    if ! ar_match "${AR_SIDECAR_SHA256}" '^[0-9a-f]{64}$' || ! cmp -s -- "${AR_WORK}/expected.sha256" "${dir}/${file}.sha256"; then
        ar_die "${dir}/${file}.sha256 isn't exactly the line '<sha256>  ${file}'."
    fi
    AR_SIDECAR_KEYS=()
    for key in ${AR_KEY_NAMES[@]+"${AR_KEY_NAMES[@]}"}; do
        signature="${dir}/${file}.sha256.${key}.sig"
        [[ -f "${signature}" ]] || continue
        if ! ar_openssl_verify "${AR_KEYS[${key}]}" "${signature}" "${dir}/${file}.sha256"; then
            ar_die "${signature} doesn't verify with ${AR_KEYS[${key}]}: the sidecar or its signature was changed."
        fi
        AR_SIDECAR_KEYS+=("${key}")
    done
    if [[ ${#AR_SIDECAR_KEYS[@]} -eq 0 ]]; then
        ar_die "${dir}/${file}.sha256 has no signature by a keyring key (${file}.sha256.<key>.sig)."
    fi
}

# ar_verify_packages DIR ARCH WORKDIR RECEIPT_DIR: V-6 and V-7 for the
# entries in WORKDIR/entries.tsv, writing RECEIPT_DIR/packages.tsv.
ar_verify_packages() {
    local dir=$1 work=$3 out=$4 name version arch size checksum file actual entry field value package_checksum
    local -A referenced=([APKINDEX.tar.gz]=1)
    mkdir -p "${out}" "${AR_WORK}/package"
    : > "${out}/packages.tsv"
    while IFS=$'\t' read -r name version arch size checksum _; do
        file="${name}-${version}.apk"
        referenced[${file}]=1
        referenced[${file}.sha256]=1
        if [[ ! -f "${dir}/${file}" || -L "${dir}/${file}" ]]; then
            ar_die "${dir}/${file} is missing; the index lists ${name} ${version}."
        fi
        ar_verify_sidecar "${dir}" "${file}"
        actual=$(ar_sha256 "${dir}/${file}")
        if [[ "${actual}" != "${AR_SIDECAR_SHA256}" ]]; then
            ar_die "${dir}/${file}'s SHA-256 is ${actual}, not the ${AR_SIDECAR_SHA256} its signed sidecar names."
        fi
        if [[ "$(stat -c %s -- "${dir}/${file}")" != "${size}" ]]; then
            ar_die "${dir}/${file} is $(stat -c %s -- "${dir}/${file}") bytes; the index says ${size}."
        fi
        # apko installs a package only if the SHA-1 of its control segment
        # is the index's C:; check it here too, so verify fails where apko
        # would.
        package_checksum=""
        while IFS=$'\t' read -r field value; do
            [[ "${field}" == "checksum" ]] && package_checksum=${value}
        done < <(ar_py apk "${dir}/${file}" "${AR_WORK}/package" || true)
        if [[ -z "${package_checksum}" ]]; then
            ar_die "Couldn't read ${dir}/${file} as an APK package; the error is above."
        fi
        if [[ "${package_checksum}" != "${checksum}" ]]; then
            ar_die "${dir}/${file}'s control segment doesn't match the index's checksum (C:${checksum}); apko would refuse it."
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${version}" "${file}" "${actual}" "${size}" >> "${out}/packages.tsv"
    done < "${work}/entries.tsv"
    for entry in "${dir}"/* "${dir}"/.[!.]*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        file=$(basename -- "${entry}")
        if [[ -n "${referenced[${file}]:-}" ]]; then
            continue
        fi
        if [[ "${file}" == *.apk.sha256.*.sig && -n "${referenced[${file%.sha256.*.sig}.sha256]:-}" ]]; then
            continue
        fi
        ar_warn "${dir}/${file} is not part of the index."
    done
}

# ---------------------------------------------------------------- S3 calls

# ar_aws_init BUCKET ENDPOINT REGION: the options every S3 call takes.
ar_aws_init() {
    AR_BUCKET=$1
    AR_AWS_OPTIONS=()
    if [[ -n "$2" ]]; then
        AR_AWS_OPTIONS+=(--endpoint-url "$2")
    fi
    if [[ -n "$3" ]]; then
        AR_AWS_OPTIONS+=(--region "$3")
    fi
}

# ar_aws_status FILE: classifies the AWS CLI's error in FILE (E-2). Prints
# absent, denied, precondition, conflict, or other.
ar_aws_status() {
    if grep -qE '\((PreconditionFailed|412)\)' "$1"; then
        echo precondition
    elif grep -qE '\((ConditionalRequestConflict|409)\)' "$1"; then
        echo conflict
    elif grep -qE '\((NoSuchKey|404)\)' "$1"; then
        echo absent
    elif grep -qE '\((AccessDenied|403|Forbidden)\)' "$1"; then
        echo denied
    else
        echo other
    fi
}

# ar_s3_url KEY
ar_s3_url() {
    printf 's3://%s/%s\n' "${AR_BUCKET}" "$1"
}

# ar_denied_hint KEY: E-3's advice.
ar_denied_hint() {
    printf '%s\n' "S3 answers 403, not 404, for a missing key when the caller lacks s3:ListBucket." \
        "Grant s3:GetObject on $(ar_s3_url "${1%/*}")/* and s3:ListBucket on the bucket (README: Bucket Setup)."
}

# ar_get_object KEY OUT: downloads KEY to OUT. Returns 0 (setting AR_ETAG
# and AR_VERSION_ID), AR_ABSENT or AR_DENIED; any other error is fatal.
ar_get_object() {
    local key=$1 out=$2 status result
    status=0
    result=$(aws s3api get-object ${AR_AWS_OPTIONS[@]+"${AR_AWS_OPTIONS[@]}"} --bucket "${AR_BUCKET}" --key "${key}" \
        --query '[ETag, VersionId]' --output text "${out}" 2> "${AR_WORK}/aws.err") || status=$?
    if [[ "${status}" -eq 0 ]]; then
        AR_ETAG=${result%%$'\t'*}
        AR_VERSION_ID=${result#*$'\t'}
        [[ "${AR_VERSION_ID}" == "None" || "${AR_VERSION_ID}" == "null" ]] && AR_VERSION_ID=""
        return 0
    fi
    rm -f -- "${out}"
    case "$(ar_aws_status "${AR_WORK}/aws.err")" in
        absent) return "${AR_ABSENT}" ;;
        denied) return "${AR_DENIED}" ;;
    esac
    cat "${AR_WORK}/aws.err" >&2
    ar_die "Couldn't read $(ar_s3_url "${key}"): the AWS CLI's GetObject exited ${status}, with the message above."
}

# ar_put_object KEY FILE CONTENT_TYPE CACHE_CONTROL CONDITION: uploads FILE
# to KEY with put-object, the only write this orb makes (U-12). CONDITION
# is '*' (If-None-Match: *) or an ETag (If-Match); every put-object names
# one of them literally, as tests/wiring_test.sh checks. Returns 0 (setting
# AR_ETAG and AR_VERSION_ID), AR_PRECONDITION, AR_CONFLICT, AR_ABSENT
# (If-Match on a missing key) or AR_DENIED; any other error is fatal.
ar_put_object() {
    local key=$1 file=$2 status result
    local -a options checksum=()
    if [[ "${AR_S3_CHECKSUMS:-true}" == "true" ]]; then
        checksum=(--checksum-sha256 "$(openssl dgst -sha256 -binary "${file}" | base64)")
    fi
    options=(${AR_AWS_OPTIONS[@]+"${AR_AWS_OPTIONS[@]}"} --bucket "${AR_BUCKET}" --key "${key}" --body "${file}"
        --content-type "$3" --cache-control "$4" ${checksum[@]+"${checksum[@]}"} --query '[ETag, VersionId]' --output text)
    status=0
    if [[ "$5" == "*" ]]; then
        result=$(aws s3api put-object "${options[@]}" --if-none-match "*" 2> "${AR_WORK}/aws.err") || status=$?
    else
        result=$(aws s3api put-object "${options[@]}" --if-match "$5" 2> "${AR_WORK}/aws.err") || status=$?
    fi
    if [[ "${status}" -eq 0 ]]; then
        AR_ETAG=${result%%$'\t'*}
        AR_VERSION_ID=${result#*$'\t'}
        [[ "${AR_VERSION_ID}" == "None" || "${AR_VERSION_ID}" == "null" ]] && AR_VERSION_ID=""
        return 0
    fi
    case "$(ar_aws_status "${AR_WORK}/aws.err")" in
        precondition) return "${AR_PRECONDITION}" ;;
        conflict) return "${AR_CONFLICT}" ;;
        absent) return "${AR_ABSENT}" ;;
        denied) return "${AR_DENIED}" ;;
    esac
    cat "${AR_WORK}/aws.err" >&2
    ar_die "Couldn't write $(ar_s3_url "${key}"): the AWS CLI's PutObject exited ${status}, with the message above."
}

# ar_receipt_meta KEY VALUE...: adds lines to the receipt's meta.tsv.
ar_receipt_meta() {
    while [[ $# -ge 2 ]]; do
        printf '%s\t%s\n' "$1" "$2" >> "${AR_WORK}/receipt/meta.tsv"
        shift 2
    done
}

# ar_write_receipt PATH: writes the receipt and exports APK_REPO_RECEIPT.
ar_write_receipt() {
    local path=$1
    if [[ "${path}" != /* ]]; then
        path="$(pwd)/${path}"
    fi
    mkdir -p -- "$(dirname -- "${path}")"
    ar_receipt_meta finished "$(ar_now)"
    ar_py receipt "${path}" "${AR_WORK}/receipt" || exit 1
    echo "Wrote the receipt to ${path}."
    if [[ -n "${BASH_ENV:-}" ]]; then
        printf 'export %s=%q\n' APK_REPO_RECEIPT "${path}" >> "${BASH_ENV}"
    fi
}
