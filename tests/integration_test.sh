#!/usr/bin/env bash
#
# Integration tests against an S3-compatible server that enforces
# conditional writes (T-4), with the real AWS CLI and melange, and the race
# test (T-5): two publishes of different packages at once, RACE_ROUNDS
# times, each ending with both packages in the index and a pull and verify
# that pass. tests/s3_server.sh starts the server and proves its 412s
# first. The commands run through tests/run_command.sh, with their YAML
# defaults; the packages come from tests/apk_fixtures.py, signed with a
# build key, and keys are made at test time.
#
# Environment:
#   APK_REPO_BUCKET    the bucket (required); each scenario uses its own prefix
#   APK_REPO_ENDPOINT  the server (default http://localhost:7070)
#   RACE_ROUNDS        rounds of the race test (default 20)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#
# Needs the AWS CLI v2 (2.22.5 or newer), melange, python3 and openssl. Run
# from a checkout:
#   APK_REPO_BUCKET=apk-repo-test bash tests/integration_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
BUCKET=${APK_REPO_BUCKET:?ERROR: set APK_REPO_BUCKET}
ENDPOINT=${APK_REPO_ENDPOINT:-http://localhost:7070}
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

# s3_etag KEY: the object's ETag, or "absent".
s3_etag() {
    aws s3api get-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "$1" \
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

CASES=0
new_case() {
    CASES=$((CASES + 1))
    CASE="${WORK}/case-${CASES}"
    PREFIX="it/${CASES}-$1"
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
aws s3api get-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "${PREFIX}/test-apk.rsa.pub" "${WORK}/public.pub" > /dev/null 2>&1
check "byte for byte" cmp -s "${WORK}/public.pub" "${WORK}/keys/test-apk.rsa.pub"

begin "T-4: pull and verify"
run pull arch="x86_64 aarch64" out_dir=pulled
check "pull succeeds for both architectures" succeeded
check "P-3: recording the index's ETag" receipt_is 'r["architectures"]["x86_64"]["index"]["etag"].strip("\"") == "'"${before//\"/}"'"' "True"
run verify arch="x86_64 aarch64" dir=pulled
check "verify accepts what pull wrote" succeeded
run pull arch=x86_64 out_dir=first cache_dir=cache
run pull arch=x86_64 out_dir=second cache_dir=cache
check "P-6: a second pull takes the packages from cache_dir" said "0 package(s) downloaded, 2 from the cache"

begin "U-8: allow_create"
new_case missing
package x86_64 hello 1.0-r0
run publish
check "publishing to a prefix with no repository fails without allow_create" failed
check "saying so" said "set allow_create to create it"
check "creating no index" [ "$(s3_etag "${PREFIX}/x86_64/APKINDEX.tar.gz")" == absent ]

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
# can; the orb never would.
aws s3api put-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "${key}" \
    --body "${WORK}/tampered.apk" --if-match "${etag}" > /dev/null
run pull arch=x86_64 out_dir=pulled
check "pull refuses it" failed
check "on its signed sidecar" said "its signed sidecar names"
check "leaving out_dir empty" [ ! -e "${CASE}/pulled/x86_64" ]

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
