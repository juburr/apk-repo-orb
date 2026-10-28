#!/bin/bash
# shellcheck disable=SC2034 # the scripts that eval this file read its variables

# Helpers shared by apk-repo-orb's scripts. It only defines functions and
# variables: the scripts eval it, from SCRIPT_APK_REPO_LIB (CircleCI's
# include directive, and actions/run_script.sh on GitHub Actions) or from
# this file when they run standalone (see the top of each script).
#
# Functions that a script's caller may name a failure for return a status
# instead of exiting: ar_get_object and ar_put_object return 0, or one of
# the AR_* codes below.

AR_TOOL_VERSION="0.1.1"

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
# How many downloads ar_get_objects runs at once.
AR_PARALLEL=8
# Signatures ar_verify_sidecar has warned about, so each is reported once.
declare -A AR_SIG_WARNED=()

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
# aarch64, without repeats. An empty list is a usage error: a command that
# checked no architecture must never succeed.
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
    if [[ ${#AR_ARCHES[@]} -eq 0 ]]; then
        ar_usage "arch lists no architecture; give x86_64 and/or aarch64."
    fi
}

# ar_default_arch VALUE: VALUE, or the machine's architecture when VALUE is
# empty or only spaces. Run it as ARCH=$(ar_default_arch ...) || exit $?,
# since ar_usage only ends the command substitution's subshell.
ar_default_arch() {
    if [[ -n "${1//[[:space:]]/}" ]]; then
        printf '%s\n' "$1"
    else
        ar_machine_arch
    fi
}

# ar_check_prefix VALUE: F-2's prefix rule, matched against the whole value
# (so no newline, empty segment, leading or trailing /, or . or .. segment).
ar_check_prefix() {
    local segment=${AR_SEGMENT_RE#^}
    segment=${segment%\$}
    if [[ -z "$1" ]]; then
        ar_usage "prefix is required, for example my-org/os."
    fi
    if ! ar_match "$1" "^${segment}(/${segment})*\$"; then
        ar_usage "prefix '$1' must be /-separated segments of letters, digits, '.', '_' and '-', each starting with a letter or digit," \
            "with no leading, trailing or doubled /."
    fi
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

# ar_configured_endpoint VALUE: VALUE, or when it is empty the endpoint the
# AWS CLI would take from AWS_ENDPOINT_URL_S3 or AWS_ENDPOINT_URL, so that
# one is checked like endpoint_url and named in the receipt too.
ar_configured_endpoint() {
    if [[ -n "$1" || "${AWS_IGNORE_CONFIGURED_ENDPOINT_URLS:-}" == "true" ]]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "${AWS_ENDPOINT_URL_S3:-${AWS_ENDPOINT_URL:-}}"
    fi
}

# ar_check_receipt_path VALUE: a file to write, never a directory.
ar_check_receipt_path() {
    if [[ -z "$1" ]]; then
        ar_usage "receipt_path is required."
    fi
    if [[ -d "$1" ]]; then
        ar_usage "receipt_path $1 is a directory; give the path of the JSON file to write."
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
    # apko only verifies RSA signatures, so another key type must not pass here.
    if ! openssl rsa -pubin -in "$1" -noout 2> /dev/null; then
        ar_usage "keyring file $1 is not a PEM RSA public key."
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

# ar_verify_index FILE ARCH WORKDIR: V-3 and V-4. Splits the signed index
# FILE for ARCH, verifies its signature, and only then reads its entries
# into WORKDIR/entries.tsv. Sets AR_INDEX_KEY to the key that signed it.
ar_verify_index() {
    local file=$1 arch=$2 work=$3
    mkdir -p "${work}"
    AR_INDEX_KEY=$(ar_py index-split "${file}" "${work}") || exit 1
    if [[ -z "${AR_KEYS[${AR_INDEX_KEY}]:-}" ]]; then
        ar_die "${file} is signed with ${AR_INDEX_KEY}, and the keyring has no ${AR_INDEX_KEY}.pub." \
            "Add ${AR_INDEX_KEY}.pub to keyring if you trust that key."
    fi
    if ! ar_openssl_verify "${AR_KEYS[${AR_INDEX_KEY}]}" "${work}/signature" "${work}/signed"; then
        ar_die "${file}'s signature doesn't verify with ${AR_KEYS[${AR_INDEX_KEY}]}: the index was changed, or signed with another key."
    fi
    ar_py index-entries "${file}" "${arch}" "${work}" || exit 1
}

# ar_verify_sidecar DIR FILE: the FILE.sha256 sidecar in DIR is exactly the
# line '<sha256>  FILE', and a signature on it by a keyring key verifies.
# One that doesn't is only a warning when another does: signature objects
# are immutable, so a stray one must not make the package unreadable for
# good. Sets AR_SIDECAR_SHA256 and AR_SIDECAR_KEYS (the keys whose
# signature verified).
ar_verify_sidecar() {
    local dir=$1 file=$2 key signature
    local -a failed=()
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
        if ar_openssl_verify "${AR_KEYS[${key}]}" "${signature}" "${dir}/${file}.sha256"; then
            AR_SIDECAR_KEYS+=("${key}")
        else
            failed+=("${key}")
        fi
    done
    if [[ ${#AR_SIDECAR_KEYS[@]} -eq 0 ]]; then
        if [[ ${#failed[@]} -gt 0 ]]; then
            ar_die "${dir}/${file}.sha256.${failed[0]}.sig doesn't verify with ${failed[0]}.pub: the sidecar or its signature was changed."
        fi
        ar_die "${dir}/${file}.sha256 has no signature by a keyring key (${file}.sha256.<key>.sig)."
    fi
    for key in ${failed[@]+"${failed[@]}"}; do
        if [[ -z "${AR_SIG_WARNED[${file}.${key}]:-}" ]]; then
            AR_SIG_WARNED[${file}.${key}]=1
            ar_warn "${file}.sha256.${key}.sig doesn't verify with ${key}.pub; ${file} is trusted for its signature by ${AR_SIDECAR_KEYS[0]}."
        fi
    done
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
    local key=$1 out=$2 status result err kind
    # Its own error file, since ar_get_objects runs several at once.
    err=$(mktemp "${AR_WORK}/aws.XXXXXX")
    status=0
    result=$(aws s3api get-object ${AR_AWS_OPTIONS[@]+"${AR_AWS_OPTIONS[@]}"} --bucket "${AR_BUCKET}" --key "${key}" \
        --query '[ETag, VersionId]' --output text "${out}" 2> "${err}") || status=$?
    if [[ "${status}" -eq 0 ]]; then
        rm -f -- "${err}"
        AR_ETAG=${result%%$'\t'*}
        AR_VERSION_ID=${result#*$'\t'}
        [[ "${AR_VERSION_ID}" == "None" || "${AR_VERSION_ID}" == "null" ]] && AR_VERSION_ID=""
        return 0
    fi
    rm -f -- "${out}"
    kind=$(ar_aws_status "${err}")
    case "${kind}" in
        absent) rm -f -- "${err}"; return "${AR_ABSENT}" ;;
        denied) rm -f -- "${err}"; return "${AR_DENIED}" ;;
    esac
    cat "${err}" >&2
    ar_die "Couldn't read $(ar_s3_url "${key}"): the AWS CLI's GetObject exited ${status}, with the message above."
}

# ar_get_objects LIST: downloads every "KEY<TAB>OUT<TAB>STATUS" line of LIST,
# AR_PARALLEL at a time, and writes each ar_get_object status (0, AR_ABSENT
# or AR_DENIED) to its STATUS file. A STATUS file left empty means another
# failure, whose error is printed already. Check them with
# ar_require_fetched and ar_optional_fetched. Batches rather than wait -n,
# which bash before 4.3 lacks.
ar_get_objects() {
    local key out status_file count=0
    while IFS=$'\t' read -r key out status_file; do
        : > "${status_file}"
        (
            status=0
            ar_get_object "${key}" "${out}" || status=$?
            printf '%s\n' "${status}" > "${status_file}"
        ) &
        count=$((count + 1))
        if (( count % AR_PARALLEL == 0 )); then
            wait
        fi
    done < "$1"
    wait
}

# ar_require_fetched STATUS KEY WHAT: KEY, which the index requires for WHAT,
# was downloaded; anything else is fatal.
ar_require_fetched() {
    case "$(cat -- "$1")" in
        0) ;;
        "${AR_ABSENT}") ar_die "$(ar_s3_url "$2") is missing, though the index lists $3." \
            "The repository is incomplete; publish the package again." ;;
        "${AR_DENIED}") ar_die "Access to $(ar_s3_url "$2") was denied." "$(ar_denied_hint "$2")" ;;
        *) ar_die "Couldn't read $(ar_s3_url "$2"); the error is above." ;;
    esac
}

# ar_optional_fetched STATUS KEY: KEY, a signature that may not exist, was
# downloaded or is absent; denied or another failure is fatal.
ar_optional_fetched() {
    case "$(cat -- "$1")" in
        0 | "${AR_ABSENT}") ;;
        "${AR_DENIED}") ar_die "Access to $(ar_s3_url "$2") was denied." "$(ar_denied_hint "$2")" ;;
        *) ar_die "Couldn't read $(ar_s3_url "$2"); the error is above." ;;
    esac
}

# ar_put_object KEY FILE CONTENT_TYPE CACHE_CONTROL CONDITION: uploads FILE
# to KEY with put-object, the only write this orb makes (U-12). CONDITION
# is '*' (If-None-Match: *) or an ETag (If-Match); every put-object names
# one of them literally, as tests/wiring_test.sh checks. Returns 0 (setting
# AR_ETAG and AR_VERSION_ID), AR_PRECONDITION, AR_CONFLICT, AR_ABSENT
# (If-Match on a missing key) or AR_DENIED; any other error is fatal.
ar_put_object() {
    local key=$1 file=$2 status result err kind
    local -a options checksum=()
    if [[ "${AR_S3_CHECKSUMS:-true}" == "true" ]]; then
        checksum=(--checksum-sha256 "$(openssl dgst -sha256 -binary "${file}" | base64)")
        if [[ "${checksum[1]}" != *= ]]; then
            ar_die "Couldn't compute the SHA-256 of ${file} for S3 to check."
        fi
    fi
    options=(${AR_AWS_OPTIONS[@]+"${AR_AWS_OPTIONS[@]}"} --bucket "${AR_BUCKET}" --key "${key}" --body "${file}"
        --content-type "$3" --cache-control "$4" ${checksum[@]+"${checksum[@]}"} --query '[ETag, VersionId]' --output text)
    status=0
    err=$(mktemp "${AR_WORK}/aws.XXXXXX")
    if [[ "$5" == "*" ]]; then
        result=$(aws s3api put-object "${options[@]}" --if-none-match "*" 2> "${err}") || status=$?
    else
        result=$(aws s3api put-object "${options[@]}" --if-match "$5" 2> "${err}") || status=$?
    fi
    if [[ "${status}" -eq 0 ]]; then
        rm -f -- "${err}"
        AR_ETAG=${result%%$'\t'*}
        AR_VERSION_ID=${result#*$'\t'}
        [[ "${AR_VERSION_ID}" == "None" || "${AR_VERSION_ID}" == "null" ]] && AR_VERSION_ID=""
        return 0
    fi
    kind=$(ar_aws_status "${err}")
    case "${kind}" in
        precondition) rm -f -- "${err}"; return "${AR_PRECONDITION}" ;;
        conflict) rm -f -- "${err}"; return "${AR_CONFLICT}" ;;
        absent) rm -f -- "${err}"; return "${AR_ABSENT}" ;;
        denied) rm -f -- "${err}"; return "${AR_DENIED}" ;;
    esac
    cat "${err}" >&2
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
