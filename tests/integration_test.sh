#!/usr/bin/env bash
#
# Integration tests against an S3-compatible server that enforces
# conditional writes (T-4), or Amazon S3 itself (T-7), with the real AWS CLI
# and melange, and the race
# test (T-5): two publishes of different packages at once, RACE_ROUNDS
# times, each ending with both packages in the index and a pull and verify
# that pass. tests/s3_server.sh starts the server and proves its 412s
# first. The commands run through tests/run_command.sh, with their YAML
# defaults; the packages come from tests/apk_fixtures.py, signed with a
# build key, and keys are made at test time.
#
# Environment:
#   APK_REPO_BUCKET    the bucket (required); each scenario uses its own prefix
#   APK_REPO_ENDPOINT  the server (default http://localhost:7070); set it
#                      empty for Amazon S3
#   APK_REPO_PREFIX    a prefix every scenario's prefix goes under (default
#                      none), so runs sharing a bucket never meet
#   APK_REPO_VERSIONED_BUCKET
#                      a bucket with versioning turned on, for pinned pulls
#                      of an earlier version of the index (default: none;
#                      APK_REPO_BUCKET is used, and that part is skipped
#                      unless it is versioned)
#   RACE_ROUNDS        rounds of the race test (default 20)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION or AWS_REGION
#
# Needs the AWS CLI v2 (2.22.5 or newer), melange, python3 and openssl. Run
# from a checkout:
#   APK_REPO_BUCKET=apk-repo-test bash tests/integration_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
BUCKET=${APK_REPO_BUCKET:?ERROR: set APK_REPO_BUCKET}
ENDPOINT=${APK_REPO_ENDPOINT-http://localhost:7070}
ROOT_PREFIX=${APK_REPO_PREFIX:-}
ROOT_PREFIX=${ROOT_PREFIX%/}
# The test's own AWS CLI calls go where the orb's do.
ENDPOINT_ARGS=()
if [[ -n "${ENDPOINT}" ]]; then
    ENDPOINT_ARGS=(--endpoint-url "${ENDPOINT}")
fi
ROUNDS=${RACE_ROUNDS:-20}
FIXTURES="python3 -I ${ROOT}/tests/apk_fixtures.py"
RUN="${ROOT}/tests/run_command.sh"

FAILURES=0
OUTPUT=""
RC=0

begin() {
    echo "--- $1"
}
check() {
    local description=$1
    shift
    if "$@"; then
        echo "  ok: ${description}"
    else
        echo "  FAIL: ${description}"
        while IFS= read -r line; do
            echo "    | ${line}"
        done <<< "${OUTPUT}"
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
# receipt_is EXPRESSION VALUE: a Python expression on the case's receipt as r.
receipt_is() {
    local got
    got=$(python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "${CASE}/receipt.json" "$1" 2>&1)
    [[ "${got}" == "$2" ]] || { OUTPUT+=$'\n'"receipt: $1 is ${got}, not $2"; return 1; }
}

# receipt_value EXPRESSION: prints a Python expression on the receipt as r.
receipt_value() {
    python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "${CASE}/receipt.json" "$1"
}

# multipart_etag KEY PARTS: KEY's ETag is a multipart upload's of PARTS parts
# ("<hex>-PARTS"), as S3 and versitygw give it.
multipart_etag() {
    local etag
    etag=$(s3_etag "$1")
    [[ "${etag}" == *"-$2\"" ]] || { OUTPUT+=$'\n'"$1's ETag is ${etag}"; return 1; }
}

# s3_etag KEY: the object's ETag, or "absent".
s3_etag() {
    aws s3api get-object ${ENDPOINT_ARGS[@]+"${ENDPOINT_ARGS[@]}"} --bucket "${BUCKET}" --key "$1" \
        --query ETag --output text "${WORK}/object" 2> /dev/null || echo absent
}

mkdir -p "${WORK}/keys" "${WORK}/keyring"
for key in test-apk.rsa other-apk.rsa build.rsa; do
    ${FIXTURES} keygen "${WORK}/keys/${key}"
done
cp "${WORK}/keys/test-apk.rsa.pub" "${WORK}/keyring/"
SIGNING_KEY_PEM=$(cat "${WORK}/keys/test-apk.rsa")
melange version 2>&1 | grep -i 'gitversion' || true
aws --version
echo "Testing s3://${BUCKET}/${ROOT_PREFIX:+${ROOT_PREFIX}/} at ${ENDPOINT:-Amazon S3}."

CASES=0
new_case() {
    CASES=$((CASES + 1))
    CASE="${WORK}/case-${CASES}"
    PREFIX="${ROOT_PREFIX:+${ROOT_PREFIX}/}it/${CASES}-$1"
    mkdir -p "${CASE}"
}

# package ARCH NAME VERSION [DIR] [TEXT]: a package signed with the build
# key, in CASE/DIR (default packages)/ARCH.
package() {
    local dir="${CASE}/${4:-packages}"
    mkdir -p "${dir}/$1"
    ${FIXTURES} build "${dir}/$1/$2-$3.apk" "$2" "$3" "$1" --key "${WORK}/keys/build.rsa" \
        --file "usr/share/$2/README=${5:-$2 $3}"
}

# run COMMAND [NAME=VALUE...]: runs the orb's command in the case directory,
# against the bucket and the case's prefix (verify takes neither). Sets RC
# and OUTPUT.
run() {
    local command=$1
    local -a settings=(keyring="${WORK}/keyring" receipt_path="${CASE}/receipt.json")
    shift
    if [[ "${command}" != "verify" ]]; then
        settings+=(bucket="${BUCKET}" prefix="${PREFIX}" endpoint_url="${ENDPOINT}")
    fi
    if [[ "${command}" == "publish" ]]; then
        settings+=(key_name=test-apk.rsa)
    fi
    if [[ $# -gt 0 ]]; then
        settings+=("$@")
    fi
    RC=0
    OUTPUT=$(cd "${CASE}" && APK_SIGNING_KEY="${SIGNING_KEY_PEM}" bash "${RUN}" "${command}" "${settings[@]}" 2>&1) || RC=$?
}

begin "T-4: create, append, re-publish"
new_case create
package x86_64 hello 1.0-r0
package aarch64 hello 1.0-r0
run publish allow_create=true
check "creating the repository succeeds for both architectures" succeeded
check "F-13: after the probe found conditional writes enforced" said "enforces conditional writes"
echo "  The index's version_id is $(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["architectures"]["x86_64"]["index"]["version_id"])' "${CASE}/receipt.json") (set only in a versioned bucket)."
check "publishing each package once" receipt_is '[r["architectures"][a]["published"] for a in ("aarch64", "x86_64")], r["architectures"]["x86_64"]["attempts"]' "([['hello-1.0-r0.apk'], ['hello-1.0-r0.apk']], 1)"
check "the probe object holds the fixed bytes" [ "$(s3_etag "${PREFIX}/.apk-repo-orb/probe")" != absent ]
package x86_64 world 2.0-r0 more
run publish packages_dir=more
check "appending to it succeeds" succeeded
check "with both packages in the index" receipt_is 'sorted(p["file"] for p in r["architectures"]["x86_64"]["packages"])' "['hello-1.0-r0.apk', 'world-2.0-r0.apk']"
before=$(s3_etag "${PREFIX}/x86_64/APKINDEX.tar.gz")
run publish
check "publishing the same packages again succeeds" succeeded
check "skipping them as identical" receipt_is '[r["architectures"][a]["skipped_identical"] for a in ("aarch64", "x86_64")]' "[['hello-1.0-r0.apk'], ['hello-1.0-r0.apk']]"
check "without replacing the index" [ "$(s3_etag "${PREFIX}/x86_64/APKINDEX.tar.gz")" == "${before}" ]
run publish resign=false
check "U-6: so is the same build with its build-time signature" receipt_is 'r["architectures"]["x86_64"]["skipped_identical"]' "['hello-1.0-r0.apk']"
package x86_64 hello 1.0-r0 conflict "another build"
run publish packages_dir=conflict
check "U-6: a different build of a published version fails" failed
check "saying packages are immutable" said "packages are immutable"
package x86_64 dry 3.0-r0 dry
run publish packages_dir=dry dry_run=true
check "U-13: a dry run succeeds" succeeded
check "uploading nothing" [ "$(s3_etag "${PREFIX}/x86_64/dry-3.0-r0.apk")" == absent ]
check "and leaving the index as it was" [ "$(s3_etag "${PREFIX}/x86_64/APKINDEX.tar.gz")" == "${before}" ]
run publish publish_public_key=true
check "U-16: publish_public_key uploads the public key" succeeded
aws s3api get-object ${ENDPOINT_ARGS[@]+"${ENDPOINT_ARGS[@]}"} --bucket "${BUCKET}" --key "${PREFIX}/test-apk.rsa.pub" "${WORK}/public.pub" > /dev/null 2>&1
check "byte for byte" cmp -s "${WORK}/public.pub" "${WORK}/keys/test-apk.rsa.pub"

begin "I-1, I-2: inspect"
run inspect arch="x86_64 aarch64"
check "inspect succeeds for both architectures" succeeded
check "listing every package of each index" receipt_is 'sorted((a, p["file"]) for a, x in r["architectures"].items() for p in x["packages"])' \
    "[('aarch64', 'hello-1.0-r0.apk'), ('x86_64', 'hello-1.0-r0.apk'), ('x86_64', 'world-2.0-r0.apk')]"
check "with their sizes and no SHA-256" receipt_is 'all(p["size"] > 0 and p["sha256"] is None for x in r["architectures"].values() for p in x["packages"])' "True"
check "and the index's ETag" receipt_is 'r["architectures"]["x86_64"]["index"]["etag"].strip("\"") == "'"${before//\"/}"'"' "True"

begin "T-4: pull and verify"
run pull arch="x86_64 aarch64" out_dir=pulled
check "pull succeeds for both architectures" succeeded
check "P-3: recording the index's ETag" receipt_is 'r["architectures"]["x86_64"]["index"]["etag"].strip("\"") == "'"${before//\"/}"'"' "True"
run verify arch="x86_64 aarch64" dir=pulled
check "verify accepts what pull wrote" succeeded
run pull arch=x86_64 out_dir=selected packages="world=2.0-r0"
check "P-10: a selective pull succeeds" succeeded
check "with only the selected package" [ -f "${CASE}/selected/x86_64/world-2.0-r0.apk" ] && [ ! -e "${CASE}/selected/x86_64/hello-1.0-r0.apk" ]
check "and the whole index" receipt_is 'r["architectures"]["x86_64"]["selection"], [p["file"] for p in r["architectures"]["x86_64"]["packages"]]' "(['world=2.0-r0'], ['world-2.0-r0.apk'])"
run verify arch=x86_64 dir=selected packages="world=2.0-r0"
check "V-9: verify accepts it with the same packages" succeeded
run pull arch=x86_64 out_dir=unlisted packages="world=9.9-r0"
check "P-10: a version the index doesn't list fails" failed
check "naming it" said "doesn't list world=9.9-r0"
run pull arch=x86_64 out_dir=first cache_dir=cache
run pull arch=x86_64 out_dir=second cache_dir=cache
check "P-6: a second pull takes the packages from cache_dir" said "0 package(s) downloaded, 2 from the cache"

begin "P-9: pinned reads"
new_case pinned
VERSIONED_BUCKET=${APK_REPO_VERSIONED_BUCKET:-${BUCKET}}
package x86_64 hello 1.0-r0
run publish allow_create=true bucket="${VERSIONED_BUCKET}"
check "publishing to ${VERSIONED_BUCKET} succeeds" succeeded
first_sha256=$(receipt_value 'r["architectures"]["x86_64"]["index"]["sha256"]')
first_version=$(receipt_value 'r["architectures"]["x86_64"]["index"]["version_id"] or ""')
package x86_64 world 2.0-r0 more
run publish packages_dir=more bucket="${VERSIONED_BUCKET}"
check "and so does a second publish, which replaces the index" succeeded
current_sha256=$(receipt_value 'r["architectures"]["x86_64"]["index"]["sha256"]')
current_version=$(receipt_value 'r["architectures"]["x86_64"]["index"]["version_id"] or ""')
run pull arch=x86_64 out_dir=current bucket="${VERSIONED_BUCKET}" index_sha256="${current_sha256}"
check "a pull pinned to the current index succeeds" succeeded
check "recording it as pinned" receipt_is 'r["architectures"]["x86_64"]["index"]["pinned"], r["architectures"]["x86_64"]["index"]["sha256"]' "(True, '${current_sha256}')"
run pull arch=x86_64 out_dir=stale bucket="${VERSIONED_BUCKET}" index_sha256="${first_sha256}"
check "a pull pinned to the replaced index, without its version, fails" failed
check "suggesting index_version_id" said "set index_version_id too"
check "leaving out_dir empty" [ ! -e "${CASE}/stale/x86_64" ]
if [[ -n "${first_version}" ]]; then
    run pull arch=x86_64 out_dir=snapshot bucket="${VERSIONED_BUCKET}" index_sha256="${first_sha256}" \
        index_version_id="${first_version}"
    check "with its version (${first_version}), the replaced index is pulled again" succeeded
    check "with the package it listed" [ -f "${CASE}/snapshot/x86_64/hello-1.0-r0.apk" ]
    check "and not the one published since" [ ! -e "${CASE}/snapshot/x86_64/world-2.0-r0.apk" ]
    check "recording that version" receipt_is 'r["architectures"]["x86_64"]["index"]["version_id"]' "${first_version}"
    run verify arch=x86_64 dir=snapshot index_sha256="${first_sha256}"
    check "verify accepts the snapshot with the same pin" succeeded
    run inspect arch=x86_64 bucket="${VERSIONED_BUCKET}" index_sha256="${first_sha256}" index_version_id="${first_version}"
    check "I-5: inspect reads the replaced index by its version too" receipt_is '[p["file"] for p in r["architectures"]["x86_64"]["packages"]]' "['hello-1.0-r0.apk']"
    run pull arch=x86_64 out_dir=mixed bucket="${VERSIONED_BUCKET}" index_sha256="${first_sha256}" \
        index_version_id="${current_version}"
    check "another version than the pinned index's fails" failed
    check "saying to take both from the same receipt" said "from the same receipt"
elif [[ -n "${APK_REPO_VERSIONED_BUCKET:-}" ]]; then
    OUTPUT="The receipt has no version_id."
    check "APK_REPO_VERSIONED_BUCKET ${VERSIONED_BUCKET} returns version IDs" false
else
    echo "  skipped: pulling a replaced index by its version, since ${VERSIONED_BUCKET} isn't versioned."
fi

begin "U-8, P-4: a prefix with no repository"
new_case missing
package x86_64 hello 1.0-r0
run publish
check "publishing to a prefix with no repository fails without allow_create" failed
check "saying so" said "set allow_create to create it"
check "creating no index" [ "$(s3_etag "${PREFIX}/x86_64/APKINDEX.tar.gz")" == absent ]
run pull arch=x86_64 out_dir=pulled
check "pulling from it fails" failed
check "P-4, E-3: saying there is no repository there (a 404, not a 403)" said "There is no repository at"
run inspect arch=x86_64
check "I-3: so does inspecting it" failed
run inspect arch=x86_64 allow_missing=true
check "I-3: unless allow_missing reports it as empty" receipt_is 'r["architectures"]["x86_64"]' "{'index': None, 'packages': []}"
run publish allow_create=true s3_checksums=false
check "s3_checksums=false: publishing without SHA-256 checksum headers succeeds" succeeded

begin "U-2: the signing key"
new_case wrong-key
package x86_64 hello 1.0-r0
SIGNING_KEY_PEM=$(cat "${WORK}/keys/other-apk.rsa") run publish allow_create=true
check "a signing key that isn't the keyring's test-apk.rsa.pub fails" failed
check "before any write" [ "$(s3_etag "${PREFIX}/.apk-repo-orb/probe")" == absent ]

begin "P-2: a tampered package in the bucket"
new_case tampered
package x86_64 hello 1.0-r0
run publish allow_create=true
key="${PREFIX}/x86_64/hello-1.0-r0.apk"
etag=$(s3_etag "${key}")
cp "${WORK}/object" "${WORK}/tampered.apk"
printf 'x' >> "${WORK}/tampered.apk"
# The test replaces the object the way only a writer with the current ETag
# can; the orb never would. A bucket with the README's bucket policy refuses
# that write, which leaves no tampered package to pull.
if aws s3api put-object ${ENDPOINT_ARGS[@]+"${ENDPOINT_ARGS[@]}"} --bucket "${BUCKET}" --key "${key}" \
    --body "${WORK}/tampered.apk" --if-match "${etag}" > /dev/null 2> "${WORK}/tamper.err"; then
    run pull arch=x86_64 out_dir=pulled
    check "pull refuses it" failed
    check "on its signed sidecar" said "its signed sidecar names"
    check "leaving out_dir empty" [ ! -e "${CASE}/pulled/x86_64" ]
else
    OUTPUT=$(cat "${WORK}/tamper.err")
    check "the bucket refuses to replace the package with AccessDenied (a bucket policy)" said "AccessDenied"
    check "and the package is unchanged" [ "$(s3_etag "${key}")" == "${etag}" ]
fi

begin "U-17, F-17: a package uploaded in parts"
new_case multipart
mkdir -p "${CASE}/packages/x86_64"
# About 12 MiB of random bytes: three parts at the smallest part size.
${FIXTURES} build "${CASE}/packages/x86_64/big-1.0-r0.apk" big 1.0-r0 x86_64 --key "${WORK}/keys/build.rsa" \
    --random "usr/share/big/blob=$((12 * 1024 * 1024))"
run publish allow_create=true multipart_threshold=5MB multipart_chunksize=5MB
check "publishing it in parts succeeds" succeeded
check "F-17: after proving CompleteMultipartUpload enforces If-None-Match" said "enforces If-None-Match on CompleteMultipartUpload too"
check "in three parts" said "big-1.0-r0.apk in 3 part(s) of up to 5 MiB."
check "U-17: its ETag is a multipart upload's, of three parts" multipart_etag "${PREFIX}/x86_64/big-1.0-r0.apk" 3
run pull arch=x86_64 out_dir=pulled
check "pull reads it back and verifies it" succeeded
run verify arch=x86_64 dir=pulled
check "and so does verify" succeeded
check "byte for byte as published" receipt_is 'r["architectures"]["x86_64"]["packages"][0]["size"] > 12 * 1024 * 1024' "True"
rm -rf "${CASE}/packages"
mkdir -p "${CASE}/packages/x86_64"
${FIXTURES} build "${CASE}/packages/x86_64/big-1.0-r0.apk" big 1.0-r0 x86_64 --key "${WORK}/keys/build.rsa" \
    --random "usr/share/big/blob=$((12 * 1024 * 1024))"
run publish multipart_threshold=5MB multipart_chunksize=5MB
check "U-6: another build of it fails" failed
check "saying packages are immutable" said "packages are immutable"

begin "T-5: concurrent publishes (${ROUNDS} rounds)"
new_case race
package x86_64 base 1.0-r0
run publish allow_create=true
check "the repository is created" succeeded
retried=0
for round in $(seq "${ROUNDS}"); do
    rm -rf "${CASE}/left" "${CASE}/right"
    package x86_64 "left${round}" 1.0-r0 left
    package x86_64 "right${round}" 1.0-r0 right
    for side in left right; do
        (run publish packages_dir="${side}" receipt_path="${CASE}/${side}.json"
            printf '%s\n' "${RC}" > "${CASE}/${side}.rc"
            printf '%s\n' "${OUTPUT}" > "${CASE}/${side}.log") &
    done
    wait
    OUTPUT=$(cat "${CASE}/left.log" "${CASE}/right.log")
    check "round ${round}: both publishes succeed" [ "$(cat "${CASE}/left.rc")$(cat "${CASE}/right.rc")" == "00" ]
    if grep -q 'merging again' <<< "${OUTPUT}"; then
        retried=$((retried + 1))
    fi
    rm -rf "${CASE}/pulled"
    run pull arch=x86_64 out_dir=pulled
    check "round ${round}: pull succeeds" succeeded
    check "round ${round}: with both packages" [ -f "${CASE}/pulled/x86_64/left${round}-1.0-r0.apk" ] && [ -f "${CASE}/pulled/x86_64/right${round}-1.0-r0.apk" ]
    run verify arch=x86_64 dir=pulled
    check "round ${round}: verify passes" succeeded
done
check "every package of every round is in the index" [ "$(find "${CASE}/pulled/x86_64" -name '*.apk' | wc -l)" -eq $((1 + 2 * ROUNDS)) ]
echo "  ${retried} of ${ROUNDS} round(s) merged again after the other publish changed the index first."

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All integration checks passed."
