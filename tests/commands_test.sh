#!/usr/bin/env bash
#
# Offline tests of verify, pull and publish (T-1, T-2). They run the real
# scripts against stand-ins on the PATH: tests/fake_aws.py for the AWS CLI
# (a bucket in a local directory, which can answer 403, 404, 409 and 412,
# or ignore conditions), tests/apk_fixtures.py for melange, and a sleep
# that returns at once. Packages, indexes and keys are made at test time;
# no private key is committed. Each check names the requirement it covers.
#
# Needs python3 (3.8 or newer), openssl, and coreutils.
#
# Run from a checkout:
#   bash tests/commands_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

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
exited() { [[ "${RC}" -eq "$1" ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }
file_has() { grep -qF -- "$2" "$1"; }
not_file_has() { ! grep -qF -- "$2" "$1" 2> /dev/null; }
# json_is FILE EXPRESSION VALUE: a Python expression on the JSON as r, in
# the case directory.
json_is() {
    local got
    got=$(cd "${CASE}" && python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>&1)
    [[ "${got}" == "$3" ]] || { OUTPUT+=$'\n'"$1: $2 is ${got}, not $3"; return 1; }
}
# logged PATTERN: the fake AWS CLI's log has a line matching PATTERN.
logged() { grep -qE -- "$1" "${CASE}/aws.log" 2> /dev/null; }
not_logged() { ! logged "$1"; }
# s3 KEY: the path of an object in the fake bucket.
s3() { printf '%s\n' "${CASE}/s3/bucket/$1"; }

# ------------------------------------------------------------------ set up
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}" "${WORK}/keys" "${WORK}/keyring" "${WORK}/other-keyring"
# Every tool the scripts run (the AWS CLI, melange, python3 and openssl)
# notes a run whose environment holds a private key, in any variable, in
# WORK/key-seen: publish must take the key out of its environment before it
# runs anything.
REAL_PYTHON3=$(command -v python3)
REAL_OPENSSL=$(command -v openssl)
# seen TOOL: the line each stand-in starts with.
# shellcheck disable=SC2016 # the stand-ins expand these, not this script
seen() {
    printf 'if env | grep -q -- "-----BEGIN .*PRIVATE KEY-----"; then echo "%s $*" >> "%s/key-seen"; fi\n' "$1" "${WORK}"
}
{ printf '#!/bin/sh\n'; seen aws; printf 'exec "%s" -I "%s/tests/fake_aws.py" "$@"\n' "${REAL_PYTHON3}" "${ROOT}"; } > "${STUBS}/aws"
{ printf '#!/bin/sh\n'; seen melange; printf 'exec "%s" -I "%s/tests/apk_fixtures.py" "$@"\n' "${REAL_PYTHON3}" "${ROOT}"; } > "${STUBS}/melange"
{ printf '#!/bin/sh\n'; seen python3; printf 'exec "%s" "$@"\n' "${REAL_PYTHON3}"; } > "${STUBS}/python3"
{ printf '#!/bin/sh\n'; seen openssl; printf 'exec "%s" "$@"\n' "${REAL_OPENSSL}"; } > "${STUBS}/openssl"
printf '#!/bin/sh\necho "$@" >> "%s/sleeps"\n' "${WORK}" > "${STUBS}/sleep"
chmod +x "${STUBS}"/*
FIXTURES="python3 -I ${ROOT}/tests/apk_fixtures.py"
for key in test-apk.rsa other-apk.rsa build.rsa; do
    ${FIXTURES} keygen "${WORK}/keys/${key}"
done
cp "${WORK}/keys/test-apk.rsa.pub" "${WORK}/keyring/"
cp "${WORK}/keys/other-apk.rsa.pub" "${WORK}/other-keyring/"
SIGNING_KEY_PEM=$(cat "${WORK}/keys/test-apk.rsa")
# A line from the middle of the private key, to look for in logs.
KEY_LINE=$(sed -n '5p' "${WORK}/keys/test-apk.rsa")

CASES=0
# new_case: a fresh directory, with an empty bucket, as the working directory.
new_case() {
    CASES=$((CASES + 1))
    CASE="${WORK}/case-${CASES}"
    mkdir -p "${CASE}/s3/bucket" "${CASE}/tmp"
    : > "${CASE}/bash_env"
    : > "${CASE}/aws.log"
    : > "${CASE}/rules"
}

# package ARCH NAME VERSION [DIR] [TEXT]: a package melange built, signed with
# the build key, in DIR (default CASE/packages)/ARCH.
package() {
    local dir=${4:-${CASE}/packages}
    mkdir -p "${dir}/$1"
    ${FIXTURES} build "${dir}/$1/$2-$3.apk" "$2" "$3" "$1" --key "${WORK}/keys/build.rsa" \
        --file "usr/share/$2/README=${5:-$2 $3}"
}

# run COMMAND [NAME=VALUE...]: runs src/scripts/COMMAND.sh in the case
# directory with the stand-ins, the bucket and the keyring. Sets RC and OUTPUT.
run() {
    local command=$1
    local -a vars=()
    shift
    if [[ $# -gt 0 ]]; then
        vars=("$@")
    fi
    RC=0
    OUTPUT=$(cd "${CASE}" && env PATH="${STUBS}:${PATH}" TMPDIR="${CASE}/tmp" BASH_ENV="${CASE}/bash_env" \
        FAKE_S3_DIR="${CASE}/s3" FAKE_AWS_LOG="${CASE}/aws.log" FAKE_AWS_RULES="${CASE}/rules" \
        APK_SIGNING_KEY="${SIGNING_KEY_PEM}" \
        PARAM_BUCKET=bucket PARAM_PREFIX=test/os PARAM_KEYRING="${WORK}/keyring" PARAM_KEY_NAME=test-apk.rsa \
        PARAM_ARCH=x86_64 ${vars[@]+"${vars[@]}"} bash "${ROOT}/src/scripts/${command}.sh" 2>&1) || RC=$?
}

# publish_new [NAME=VALUE...]: publish, creating the repository. (Bash 4.0
# takes an empty "$@" for an unbound variable.)
publish_new() {
    if [[ $# -gt 0 ]]; then
        run publish PARAM_ALLOW_CREATE=true "$@"
    else
        run publish PARAM_ALLOW_CREATE=true
    fi
}

# ------------------------------------------------------------------ verify
echo "=== verify"

# repo DIR ARCH NAME VERSION...: a published repository in DIR: packages
# re-signed with the test key, sidecars, and a signed index.
repo() {
    local dir=$1 arch=$2 name version file
    shift 2
    mkdir -p "${dir}/${arch}"
    local -a files=()
    while [[ $# -ge 2 ]]; do
        name=$1 version=$2
        shift 2
        file="${dir}/${arch}/${name}-${version}.apk"
        package "${arch}" "${name}" "${version}" "${dir}"
        ${FIXTURES} sign "${WORK}/keys/test-apk.rsa" "${file}"
        (cd "${dir}/${arch}" && sha256sum "${name}-${version}.apk" > "${name}-${version}.apk.sha256" \
            && openssl dgst -sha256 -sign "${WORK}/keys/test-apk.rsa" \
                -out "${name}-${version}.apk.sha256.test-apk.rsa.sig" "${name}-${version}.apk.sha256")
        files+=("${file}")
    done
    ${FIXTURES} index "${dir}/${arch}/APKINDEX.tar.gz" --key "${WORK}/keys/test-apk.rsa" "${files[@]}"
}

begin "V-8: a valid repository"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0 world 2.1-r3
run verify PARAM_DIR=repo
check "succeeds" succeeded
check "V-8: writes the receipt" json_is "${CASE}/apk-repo-receipt.json" 'r["operation"], r["schema_version"], r["dry_run"]' "('verify', 1, False)"
check "listing every package" json_is "${CASE}/apk-repo-receipt.json" '[p["file"] for p in r["architectures"]["x86_64"]["packages"]]' "['hello-1.0.0-r0.apk', 'world-2.1-r3.apk']"
check "with its SHA-256 and size" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["packages"][0]["sha256"] == open("repo/x86_64/hello-1.0.0-r0.apk.sha256").read()[:64]' "True"
check "and the index's signature" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["signature"]' ".SIGN.RSA256.test-apk.rsa.pub"
check "O-2: exports the receipt's path" file_has "${CASE}/bash_env" "export APK_REPO_RECEIPT=${CASE}/apk-repo-receipt.json"
check "V-1: makes no AWS call" not_logged '.'
run verify PARAM_DIR=repo PARAM_KEYRING="${WORK}/keyring/test-apk.rsa.pub"
check "a key file works as the keyring as well as a directory" succeeded

begin "V-7: files the index doesn't list"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
echo extra > "${CASE}/repo/x86_64/notes.txt"
run verify PARAM_DIR=repo
check "are reported" said "WARN: repo/x86_64/notes.txt is not part of the index."
check "and don't fail verify" succeeded

begin "V-2, V-4, F-4: the index"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
run verify PARAM_DIR=repo PARAM_ARCH=aarch64
check "V-2: a missing index fails" failed
check "naming it" said "repo/aarch64/APKINDEX.tar.gz is missing"
run verify PARAM_DIR=repo PARAM_KEYRING="${WORK}/other-keyring"
check "V-4: an index signed by a key the keyring lacks fails" failed
check "naming the keyring file it needs" said "the keyring has no test-apk.rsa.pub"
cp "${WORK}/keys/other-apk.rsa.pub" "${CASE}/test-apk.rsa.pub"
run verify PARAM_DIR=repo PARAM_KEYRING="${CASE}/test-apk.rsa.pub"
check "V-4: a keyring file with that name but another key fails" failed
check "saying the signature doesn't verify" said "signature doesn't verify"
${FIXTURES} index "${CASE}/repo/x86_64/APKINDEX.tar.gz" --key "${WORK}/keys/test-apk.rsa" --legacy "${CASE}/repo/x86_64/hello-1.0.0-r0.apk"
run verify PARAM_DIR=repo
check "F-4: a legacy SHA-1 .SIGN.RSA. index fails" failed
check "saying only RSA256 is accepted" said "only .SIGN.RSA256.<key>.rsa.pub signatures are accepted"

begin "T-2: a tampered repository"
for target in index apk sha256 sig; do
    new_case
    repo "${CASE}/repo" x86_64 hello 1.0.0-r0
    dir="${CASE}/repo/x86_64"
    case "${target}" in
        index) file="${dir}/APKINDEX.tar.gz" ;;
        apk) file="${dir}/hello-1.0.0-r0.apk" ;;
        sha256) file="${dir}/hello-1.0.0-r0.apk.sha256" ;;
        sig) file="${dir}/hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig" ;;
    esac
    # Flip one byte near the end, inside what the signatures cover.
    python3 -I -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[-30] ^= 1; open(p, "wb").write(bytes(b))' "${file}"
    run verify PARAM_DIR=repo
    check "a one-byte change to the ${target} fails" failed
    check "and writes no receipt" absent "${CASE}/apk-repo-receipt.json"
done

begin "V-6: the data segment"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
# A changed data segment, with a sidecar and signature made for it: the
# control segment (C:) and the size still match the index, and only the
# datahash in .PKGINFO gives it away.
python3 -I -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[-30] ^= 1; open(p, "wb").write(bytes(b))' "${CASE}/repo/x86_64/hello-1.0.0-r0.apk"
(cd "${CASE}/repo/x86_64" && sha256sum hello-1.0.0-r0.apk > hello-1.0.0-r0.apk.sha256 \
    && openssl dgst -sha256 -sign "${WORK}/keys/test-apk.rsa" -out hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig hello-1.0.0-r0.apk.sha256)
run verify PARAM_DIR=repo
check "a package whose data doesn't match its datahash fails, even with a valid sidecar" failed
check "saying so" said "data segment doesn't match the datahash in its .PKGINFO"

begin "V-6: packages and sidecars"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
rm "${CASE}/repo/x86_64/hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig"
run verify PARAM_DIR=repo
check "a sidecar without a keyring key's signature fails" failed
check "saying so" said "has no signature by a keyring key"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
rm "${CASE}/repo/x86_64/hello-1.0.0-r0.apk"
run verify PARAM_DIR=repo
check "a missing package fails" failed
check "naming it" said "hello-1.0.0-r0.apk is missing"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
(cd "${CASE}/repo/x86_64" && printf '%s  other.apk\n' "$(cut -c1-64 hello-1.0.0-r0.apk.sha256)" > hello-1.0.0-r0.apk.sha256 \
    && openssl dgst -sha256 -sign "${WORK}/keys/test-apk.rsa" -out hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig hello-1.0.0-r0.apk.sha256)
run verify PARAM_DIR=repo
check "a signed sidecar that names another file fails" failed
check "saying what it must hold" said "isn't exactly the line '<sha256>  hello-1.0.0-r0.apk'"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
# Another build of the same version, re-signed with its own sidecar: only
# the index's checksum and size give it away.
package x86_64 hello 1.0.0-r0 "${CASE}/other" "a different build"
cp "${CASE}/other/x86_64/hello-1.0.0-r0.apk" "${CASE}/repo/x86_64/"
${FIXTURES} sign "${WORK}/keys/test-apk.rsa" "${CASE}/repo/x86_64/hello-1.0.0-r0.apk"
(cd "${CASE}/repo/x86_64" && sha256sum hello-1.0.0-r0.apk > hello-1.0.0-r0.apk.sha256 \
    && openssl dgst -sha256 -sign "${WORK}/keys/test-apk.rsa" -out hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig hello-1.0.0-r0.apk.sha256)
run verify PARAM_DIR=repo
check "a package the index doesn't describe fails, even with a valid sidecar" failed
check "on its size or its checksum (C:)" said "hello-1.0.0-r0.apk"

begin "V-5 and V-3: the index's contents"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
python3 -I - "${CASE}/repo/x86_64/APKINDEX.tar.gz" "${WORK}/keys/test-apk.rsa" << 'EOF'
# Rewrites the index without its final blank line, signed again.
import gzip, io, subprocess, sys, tarfile, zlib
path, key = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
inflate = zlib.decompressobj(31)
inflate.decompress(data)
rest = inflate.unused_data
tar = tarfile.open(fileobj=io.BytesIO(gzip.decompress(rest)))
text = tar.extractfile("APKINDEX").read().rstrip(b"\n") + b"\n"
out = io.BytesIO()
with tarfile.open(fileobj=out, mode="w", format=tarfile.USTAR_FORMAT) as t:
    info = tarfile.TarInfo("APKINDEX"); info.size = len(text); t.addfile(info, io.BytesIO(text))
signed = gzip.compress(out.getvalue(), mtime=0)
sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=signed, stdout=subprocess.PIPE, check=True).stdout
info = tarfile.TarInfo(".SIGN.RSA256.test-apk.rsa.pub"); info.size = len(sig)
member = info.tobuf(tarfile.USTAR_FORMAT, "utf-8", "surrogateescape") + sig + b"\0" * ((512 - len(sig) % 512) % 512)
open(path, "wb").write(gzip.compress(member, mtime=0) + signed)
EOF
run verify PARAM_DIR=repo
check "an index apko would read one entry short of fails" failed
check "saying why" said "apko would drop its last entry"

begin "parameters"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
run verify PARAM_DIR=repo PARAM_ARCH=riscv64
check "E-1: an unknown arch is a usage error (2)" exited 2
run verify PARAM_DIR=repo PARAM_KEYRING=
check "E-1: no keyring is a usage error (2)" exited 2
cp "${WORK}/keys/test-apk.rsa.pub" "${CASE}/key.pem"
run verify PARAM_DIR=repo PARAM_KEYRING="${CASE}/key.pem"
check "F-3: a keyring file not named <key>.rsa.pub is refused" exited 2
run verify PARAM_DIR=repo PARAM_KEYRING="${CASE}/missing.rsa.pub"
check "T-2: a missing keyring file is a usage error (2)" exited 2
check "naming it" said "keyring entry ${CASE}/missing.rsa.pub is not a file or directory."
mkdir -p "${CASE}/bad"
package x86_64 'bad@name' 1.0-r0 "${CASE}/bad"
${FIXTURES} index "${CASE}/bad/x86_64/APKINDEX.tar.gz" --key "${WORK}/keys/test-apk.rsa" "${CASE}/bad/x86_64/bad@name-1.0-r0.apk"
run verify PARAM_DIR=bad
check "V-5: an index naming an invalid package fails" failed
check "naming it" said "names a package 'bad@name', which isn't a valid name"
(cd "${ROOT}" && bash tests/run_command.sh verify dir="${CASE}/repo" keyring="${WORK}/keyring" receipt_path="${CASE}/run_command.json" > /dev/null 2>&1)
check "tests/run_command.sh runs verify with its defaults" exists "${CASE}/run_command.json"

# ------------------------------------------------------------------ publish
echo "=== publish"

begin "U-8: no repository yet"
new_case
package x86_64 hello 1.0.0-r0
run publish
check "fails without allow_create" failed
check "saying how to create it" said "no repository at s3://bucket/test/os/x86_64; set allow_create to create it"
check "and writes no index" absent "$(s3 test/os/x86_64/APKINDEX.tar.gz)"

begin "T-2: create, then append"
new_case
package x86_64 hello 1.0.0-r0
built=$(sha256sum < "${CASE}/packages/x86_64/hello-1.0.0-r0.apk")
publish_new
check "creating the repository succeeds" succeeded
check "F-13: after the conditional write probe" said "enforces conditional writes"
check "F-13: whose object holds the fixed bytes" file_has "$(s3 test/os/.apk-repo-orb/probe)" "apk-repo-orb conditional write probe v1"
check "the package is uploaded" exists "$(s3 test/os/x86_64/hello-1.0.0-r0.apk)"
check "with its sidecar" exists "$(s3 test/os/x86_64/hello-1.0.0-r0.apk.sha256)"
check "F-6: and the sidecar's signature, named after the key" exists "$(s3 test/os/x86_64/hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig)"
check "U-7: before the index" python3 -I -c 'import sys; lines = open(sys.argv[1]).read().splitlines(); puts = [l.split()[1] for l in lines if l.startswith("PutObject")]; sys.exit(0 if puts.index("test/os/x86_64/APKINDEX.tar.gz") > puts.index("test/os/x86_64/hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig") else 1)' "${CASE}/aws.log"
check "U-10: which is created with If-None-Match" logged '^PutObject test/os/x86_64/APKINDEX.tar.gz if-none-match'
check "U-12: every write is conditional" not_logged '^PutObject .* none '
check "F-7: packages are immutable for caches" json_is "${CASE}/s3/.meta/bucket/test/os/x86_64/hello-1.0.0-r0.apk.json" 'r["CacheControl"], r["ContentType"]' "('max-age=31536000, immutable', 'application/octet-stream')"
check "F-8: the index is never cached" json_is "${CASE}/s3/.meta/bucket/test/os/x86_64/APKINDEX.tar.gz.json" 'r["CacheControl"], r["ContentType"]' "('no-cache', 'application/gzip')"
check "F-9: S3 gets each upload's SHA-256" json_is "${CASE}/s3/.meta/bucket/test/os/x86_64/hello-1.0.0-r0.apk.json" 'r["ChecksumSHA256"] is not None' "True"
check "the receipt lists it as published" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["published"], r["architectures"]["x86_64"]["attempts"]' "(['hello-1.0.0-r0.apk'], 1)"
check "with the index's ETag" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["etag"].startswith("\"")' "True"
check "U-17: packages_dir is left as it was" [ "$(sha256sum < "${CASE}/packages/x86_64/hello-1.0.0-r0.apk")" == "${built}" ]
check "U-4: while the published package is re-signed" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["packages"][0]["sha256"] != __import__("hashlib").sha256(open("packages/x86_64/hello-1.0.0-r0.apk", "rb").read()).hexdigest()' "True"
first_index=$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")
package x86_64 world 2.0-r0
run publish
check "appending to it succeeds" succeeded
check "lists hello as already published" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["skipped_identical"]' "['hello-1.0.0-r0.apk']"
check "and world as published" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["published"]' "['world-2.0-r0.apk']"
check "U-10: replacing the index with If-Match" logged '^PutObject test/os/x86_64/APKINDEX.tar.gz if-match'
check "the index changed" [ "$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")" != "${first_index}" ]
check "the receipt lists both packages" json_is "${CASE}/apk-repo-receipt.json" 'sorted(p["file"] for p in r["architectures"]["x86_64"]["packages"])' "['hello-1.0.0-r0.apk', 'world-2.0-r0.apk']"
run pull PARAM_OUT_DIR=pulled
check "pull reads it back" succeeded
run verify PARAM_DIR=pulled
check "and verify accepts what it pulled" succeeded

begin "U-15: both architectures at once"
new_case
package x86_64 hello 1.0.0-r0 "${CASE}/packages" "hello for x86_64"
package aarch64 hello 1.0.0-r0 "${CASE}/packages" "hello for aarch64, a different size"
publish_new PARAM_ARCH=
check "publishing the same file name for each architecture succeeds" succeeded
for arch in x86_64 aarch64; do
    check "the ${arch} receipt has the ${arch} package's SHA-256" json_is "${CASE}/apk-repo-receipt.json" \
        'r["architectures"]["'"${arch}"'"]["packages"][0]["sha256"] == open("s3/bucket/test/os/'"${arch}"'/hello-1.0.0-r0.apk.sha256").read()[:64]' "True"
done
run pull PARAM_ARCH="x86_64 aarch64" PARAM_OUT_DIR=pulled
check "and pull reads both back" succeeded

begin "T-2: publishing the same build again"
new_case
package x86_64 hello 1.0.0-r0
publish_new
before=$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")
: > "${CASE}/aws.log"
run publish
check "succeeds" succeeded
check "skipping the package as identical" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["skipped_identical"], r["architectures"]["x86_64"]["published"]' "(['hello-1.0.0-r0.apk'], [])"
check "without rewriting the index" [ "$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")" == "${before}" ]
check "or uploading the package" not_logged '^PutObject test/os/x86_64/hello'
run publish PARAM_RESIGN=false
check "U-6: the build-time signature of the same package is the same package" succeeded
check "and is skipped too" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["skipped_identical"]' "['hello-1.0.0-r0.apk']"

begin "U-6: packages are immutable"
new_case
package x86_64 hello 1.0.0-r0
publish_new
rm -rf "${CASE}/packages"
package x86_64 hello 1.0.0-r0 "${CASE}/packages" "another build"
run publish
check "a different build of a published version fails" failed
check "saying packages are immutable" said "is already published with different contents; packages are immutable"
check "and the published package stays" json_is "${CASE}/s3/.meta/bucket/test/os/x86_64/hello-1.0.0-r0.apk.json" '"ETag" in r' "True"

begin "U-7: what an interrupted publish left"
new_case
package x86_64 hello 1.0.0-r0
echo "PutObject .*/APKINDEX.tar.gz 500" > "${CASE}/rules"
publish_new
check "an index upload that fails unexpectedly fails the publish" failed
check "E-2: without retrying it" not_said "merging again"
check "after the package was uploaded" exists "$(s3 test/os/x86_64/hello-1.0.0-r0.apk)"
: > "${CASE}/rules"
publish_new
check "publishing it again succeeds, the objects being byte-identical" succeeded
check "and indexes it" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["published"]' "['hello-1.0.0-r0.apk']"

begin "U-10: compare-and-swap"
new_case
package x86_64 hello 1.0.0-r0
publish_new
package x86_64 world 2.0-r0
echo "PutObject .*/APKINDEX.tar.gz 412 1" > "${CASE}/rules"
run publish
check "a 412 on the index retries" succeeded
check "and succeeds on the second attempt" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["attempts"]' "2"
check "after a backoff" exists "${WORK}/sleeps"
echo "PutObject .*/APKINDEX.tar.gz 409 1" > "${CASE}/rules"
package x86_64 third 3.0-r0
run publish
check "a 409 ConditionalRequestConflict retries too" succeeded
echo "PutObject .*/APKINDEX.tar.gz 412" > "${CASE}/rules"
package x86_64 fourth 4.0-r0
: > "${CASE}/aws.log"
run publish PARAM_MAX_ATTEMPTS=3
check "max_attempts exhausted fails" failed
check "saying so" said "gave up after 3 attempts"
check "U-15: naming the architecture" said "Publishing failed for x86_64"
check "after exactly 3 index writes" [ "$(grep -c '^PutObject test/os/x86_64/APKINDEX.tar.gz' "${CASE}/aws.log")" -eq 3 ]

begin "T-5: concurrent publishes (offline)"
new_case
package x86_64 base 1.0-r0
publish_new
for round in 1 2 3 4 5 6; do
    rm -rf "${CASE}/one" "${CASE}/two"
    package x86_64 "left${round}" 1.0-r0 "${CASE}/one"
    package x86_64 "right${round}" 1.0-r0 "${CASE}/two"
    (run publish PARAM_PACKAGES_DIR=one PARAM_RECEIPT_PATH=one.json; echo "${RC}" > "${CASE}/one.rc"; printf '%s\n' "${OUTPUT}" > "${CASE}/one.log") &
    (run publish PARAM_PACKAGES_DIR=two PARAM_RECEIPT_PATH=two.json; echo "${RC}" > "${CASE}/two.rc"; printf '%s\n' "${OUTPUT}" > "${CASE}/two.log") &
    wait
    OUTPUT="$(cat "${CASE}/one.log" "${CASE}/two.log")"
    check "round ${round}: both publishes succeed" [ "$(cat "${CASE}/one.rc")$(cat "${CASE}/two.rc")" == "00" ]
done
run pull PARAM_OUT_DIR=pulled
check "every package of every round is in the index" [ "$(find "${CASE}/pulled/x86_64" -name '*.apk' | wc -l)" -eq 13 ]

begin "F-16: a backend that ignores conditions"
new_case
package x86_64 hello 1.0.0-r0
FAKE_AWS_IGNORE_CONDITIONS=1 publish_new
check "publish refuses" failed
check "saying why" said "does not enforce S3 conditional writes; refusing to publish"
check "before writing anything but the probe" not_logged '^PutObject test/os/x86_64/'
echo "PutObject .*probe ignore 2" > "${CASE}/rules"
publish_new
check "nor when only If-Match is ignored" failed

begin "E-3: access denied"
new_case
package x86_64 hello 1.0.0-r0
publish_new
echo "GetObject .*/APKINDEX.tar.gz 403" > "${CASE}/rules"
run publish
check "a 403 reading the index fails" failed
check "never taken for a missing repository" not_said "set allow_create"
check "suggesting s3:ListBucket" said "s3:ListBucket"

begin "U-1, U-2: the signing key"
new_case
package x86_64 hello 1.0.0-r0
run publish PARAM_ALLOW_CREATE=true APK_SIGNING_KEY=
check "an empty signing key variable fails" exited 2
run publish PARAM_ALLOW_CREATE=true PARAM_SIGNING_KEY=OTHER_KEY OTHER_KEY="$(cat "${WORK}/keys/other-apk.rsa")"
check "a key that isn't the keyring's <key_name>.pub fails" failed
check "saying so" said "doesn't match"
check "before any write" not_logged 'PutObject'
run publish PARAM_ALLOW_CREATE=true APK_SIGNING_KEY="$(base64 -w0 < "${WORK}/keys/test-apk.rsa")"
check "a base64-encoded PEM key works" succeeded

begin "S-1, S-2: secrets and temporary files"
new_case
package x86_64 hello 1.0.0-r0
publish_new
check "the key is never in the log" not_said "${KEY_LINE}"
check "the receipt" not_file_has "${CASE}/apk-repo-receipt.json" "${KEY_LINE}"
check "or BASH_ENV" not_file_has "${CASE}/bash_env" "${KEY_LINE}"
check "and no temporary files are left" [ -z "$(ls -A "${CASE}/tmp")" ]
echo "PutObject .*/APKINDEX.tar.gz 500" > "${CASE}/rules"
package x86_64 world 2.0-r0
run publish
check "S-2: after a failure too" [ -z "$(ls -A "${CASE}/tmp")" ]

begin "U-13: dry run"
new_case
package x86_64 hello 1.0.0-r0
publish_new
package x86_64 world 2.0-r0
: > "${CASE}/aws.log"
run publish PARAM_DRY_RUN=true
check "succeeds" succeeded
check "making no writes" not_logged '^PutObject'
check "reporting what it would publish" said "would publish world-2.0-r0.apk"
check "in a receipt marked dry_run" json_is "${CASE}/apk-repo-receipt.json" 'r["dry_run"], r["architectures"]["x86_64"]["published"]' "(True, ['world-2.0-r0.apk'])"

begin "U-3, F-1, F-2: the packages"
new_case
package x86_64 hello 1.0.0-r0
mkdir -p "${CASE}/packages/riscv64"
cp "${CASE}/packages/x86_64/hello-1.0.0-r0.apk" "${CASE}/packages/riscv64/"
run publish PARAM_ALLOW_CREATE=true PARAM_ARCH=
check "an unexpected arch directory is refused" exited 2
check "naming it" said "riscv64 is not x86_64 or aarch64"
new_case
package x86_64 hello 1.0.0-r0
mv "${CASE}/packages/x86_64/hello-1.0.0-r0.apk" "${CASE}/packages/x86_64/hello.apk"
publish_new
check "F-1: a package not named <P>-<V>.apk fails" failed
check "saying what it must be named" said "must be named hello-1.0.0-r0.apk"
new_case
mkdir -p "${CASE}/packages/x86_64"
${FIXTURES} build "${CASE}/packages/x86_64/hello-1.0.0.apk" hello 1.0.0 x86_64
publish_new
check "F-2: a version without -r<N> fails" failed
new_case
package x86_64 'bad@name' 1.0-r0
publish_new
check "F-2: an invalid package name fails" failed
check "naming it" said "is bad@name 1.0-r0; names must match"
new_case
mkdir -p "${CASE}/packages/x86_64"
${FIXTURES} build "${CASE}/packages/x86_64/hello-1.0.0-r0.apk" hello 1.0.0-r0 aarch64
publish_new
check "U-3: a package for another arch fails" failed
check "naming both" said "is built for aarch64, but it is in packages/x86_64"
new_case
mkdir -p "${CASE}/packages/x86_64"
# Sparse: S3's largest object plus one byte, refused before it is copied.
truncate -s $((5 * 1024 * 1024 * 1024 * 1024 + 1)) "${CASE}/packages/x86_64/huge-1.0-r0.apk"
publish_new
check "U-14: a package over 5 TiB, S3's largest object, fails" failed
check "before it is staged" said "is larger than 5 TiB, the largest object S3 stores."

begin "F-2, F-3: parameters"
new_case
package x86_64 hello 1.0.0-r0
for prefix in /test test/ "test//os" "test/../os" "te st"; do
    publish_new PARAM_PREFIX="${prefix}"
    check "prefix '${prefix}' is refused" exited 2
done
for key in test-apk test.pem ".rsa" "a/b.rsa"; do
    publish_new PARAM_KEY_NAME="${key}"
    check "key_name '${key}' is refused" exited 2
done
publish_new PARAM_ENDPOINT_URL=http://s3.example.com
check "an http:// endpoint other than localhost is refused" exited 2
publish_new PARAM_ENDPOINT_URL=http://localhost:7070
check "http://localhost is accepted" succeeded
check "and passed to the AWS CLI" logged ' http://localhost:7070$'
check "no AWS call was made for the refused ones" [ "$(grep -c 's3.example.com' "${CASE}/aws.log")" -eq 0 ]
new_case
package x86_64 hello 1.0.0-r0
FAKE_AWS_NO_IF_MATCH=1 publish_new
check "D-3: an AWS CLI without --if-match fails" failed
check "naming the version it needs" said "AWS CLI v2 2.22.5 or newer"

begin "U-16: the public key"
new_case
package x86_64 hello 1.0.0-r0
publish_new PARAM_PUBLISH_PUBLIC_KEY=true
check "is uploaded when asked" cmp -s "$(s3 test/os/test-apk.rsa.pub)" "${WORK}/keys/test-apk.rsa.pub"
publish_new PARAM_PUBLISH_PUBLIC_KEY=true
check "uploading the same key again is fine" succeeded

begin "F-9: s3_checksums"
new_case
package x86_64 hello 1.0.0-r0
publish_new PARAM_S3_CHECKSUMS=false
check "false sends no checksum" json_is "${CASE}/s3/.meta/bucket/test/os/x86_64/hello-1.0.0-r0.apk.json" 'r["ChecksumSHA256"]' "None"

begin "U-17, F-17: multipart uploads"
# big_package ARCH NAME VERSION [DIR]: a package of about 12 MiB of random
# bytes, three 5 MiB parts at the smallest part size, signed with the build key.
big_package() {
    local dir=${4:-${CASE}/packages}
    mkdir -p "${dir}/$1"
    ${FIXTURES} build "${dir}/$1/$2-$3.apk" "$2" "$3" "$1" --key "${WORK}/keys/build.rsa" \
        --random "usr/share/$2/blob=$((12 * 1024 * 1024))"
}
# open_uploads: how many multipart uploads the fake bucket has open.
open_uploads() { find "${CASE}/s3/.uploads" -mindepth 1 -maxdepth 1 2> /dev/null | wc -l; }
MULTIPART=(PARAM_MULTIPART_THRESHOLD=5MB PARAM_MULTIPART_CHUNKSIZE=5MB)
new_case
big_package x86_64 big 1.0-r0
package x86_64 small 1.0-r0
publish_new "${MULTIPART[@]}"
check "a package of multipart_threshold or more is published" succeeded
check "F-17: after proving CompleteMultipartUpload enforces If-None-Match" said "enforces If-None-Match on CompleteMultipartUpload too"
check "on the probe object, which the probe's multipart upload must not replace" logged '^CompleteMultipartUpload test/os/\.apk-repo-orb/probe if-none-match '
check "U-17: in parts of multipart_chunksize" said "Uploading s3://bucket/test/os/x86_64/big-1.0-r0.apk in 3 part(s) of up to 5 MiB."
check "completed with If-None-Match" logged '^CompleteMultipartUpload test/os/x86_64/big-1\.0-r0\.apk if-none-match '
check "while a smaller package still goes up with PutObject" logged '^PutObject test/os/x86_64/small-1\.0-r0\.apk if-none-match '
check "and is never uploaded in parts" not_logged '^(CreateMultipartUpload|UploadPart) test/os/x86_64/small'
check "leaving no multipart upload open" [ "$(open_uploads)" -eq 0 ]
check "with the package's bytes, as re-signed" json_is "${CASE}/apk-repo-receipt.json" \
    '[p["sha256"] for p in r["architectures"]["x86_64"]["packages"] if p["file"] == "big-1.0-r0.apk"] == [open("s3/bucket/test/os/x86_64/big-1.0-r0.apk.sha256").read()[:64]]' "True"
run pull PARAM_OUT_DIR=pulled
check "pull reads it back and verifies it" succeeded
run verify PARAM_DIR=pulled
check "and so does verify" succeeded
: > "${CASE}/aws.log"
run publish "${MULTIPART[@]}"
check "publishing the same build again succeeds" succeeded
check "skipping it as identical, without uploading anything" not_logged '^(PutObject|CreateMultipartUpload|UploadPart|CompleteMultipartUpload) test/os/x86_64/'
rm -rf "${CASE}/packages"
big_package x86_64 big 1.0-r0
run publish "${MULTIPART[@]}"
check "U-6: a different build of a version published in parts fails" failed
check "saying packages are immutable" said "packages are immutable"

new_case
big_package x86_64 big 1.0-r0
publish_new
check "U-17: with the default multipart_threshold (5GB), a 12 MiB package goes up with PutObject" logged '^PutObject test/os/x86_64/big-1\.0-r0\.apk if-none-match '
check "and nothing is uploaded in parts, not even the probe" not_logged '^(CreateMultipartUpload|UploadPart|CompleteMultipartUpload) '

new_case
big_package x86_64 big 1.0-r0
FAKE_AWS_IGNORE_MULTIPART_CONDITIONS=1 publish_new "${MULTIPART[@]}"
check "F-17: a backend that ignores If-None-Match on CompleteMultipartUpload is refused" failed
check "saying so" said "does not enforce If-None-Match on CompleteMultipartUpload; refusing to publish packages of multipart_threshold or more."
check "before the package is uploaded" absent "$(s3 test/os/x86_64/big-1.0-r0.apk)"
check "with the probe object's bytes unchanged" file_has "$(s3 test/os/.apk-repo-orb/probe)" "apk-repo-orb conditional write probe v1"

new_case
big_package x86_64 big 1.0-r0
FAKE_AWS_NO_MULTIPART_CONDITIONS=1 publish_new "${MULTIPART[@]}"
check "an AWS CLI whose complete-multipart-upload can't take --if-none-match is refused" failed
check "saying so" said "can't complete a multipart upload conditionally"
check "before any write" not_logged '^(PutObject|CreateMultipartUpload) '

new_case
big_package x86_64 big 1.0-r0
echo 'UploadPart big-1\.0-r0\.apk$ 500 1' > "${CASE}/rules"
publish_new "${MULTIPART[@]}"
check "a part that fails to upload fails the publish" failed
check "naming the part" said "Couldn't upload part"
check "aborting the upload" logged '^AbortMultipartUpload test/os/x86_64/big-1\.0-r0\.apk '
check "leaving none open" [ "$(open_uploads)" -eq 0 ]
check "and no index" absent "$(s3 test/os/x86_64/APKINDEX.tar.gz)"
echo 'CompleteMultipartUpload big-1\.0-r0\.apk$ 409 1' > "${CASE}/rules"
: > "${CASE}/aws.log"
publish_new "${MULTIPART[@]}"
check "U-10: a 409 on CompleteMultipartUpload is retried" succeeded
check "with a new upload" [ "$(grep -c '^CreateMultipartUpload test/os/x86_64/big' "${CASE}/aws.log")" -eq 2 ]
check "the first one aborted" logged '^AbortMultipartUpload test/os/x86_64/big'
check "leaving none open" [ "$(open_uploads)" -eq 0 ]

new_case
big_package x86_64 big 1.0-r0
echo 'CreateMultipartUpload big-1\.0-r0\.apk$ 403' > "${CASE}/rules"
publish_new "${MULTIPART[@]}"
check "E-3: a denied multipart upload fails" failed
check "naming s3:AbortMultipartUpload" said "s3:AbortMultipartUpload"
: > "${CASE}/rules"
publish_new "${MULTIPART[@]}" PARAM_S3_CHECKSUMS=false
check "F-9: with s3_checksums=false, a multipart upload succeeds too" succeeded

new_case
big_package x86_64 big 1.0-r0
publish_new "${MULTIPART[@]}" PARAM_DRY_RUN=true
check "U-13: a dry run with a package of multipart_threshold or more writes nothing" succeeded
check "not even the multipart probe" not_logged '^(PutObject|CreateMultipartUpload|UploadPart|CompleteMultipartUpload) '

new_case
big_package x86_64 big 1.0-r0
# Unusual sizes that are still allowed: a threshold in bytes, and parts of
# 7 MiB, so the 12 MiB package goes up in two.
publish_new PARAM_MULTIPART_THRESHOLD=5242880 PARAM_MULTIPART_CHUNKSIZE=7MB
check "sizes in bytes, and other part sizes, work" said "in 2 part(s) of up to 7 MiB."
: > "${CASE}/aws.log"
for bad in PARAM_MULTIPART_THRESHOLD=4MB PARAM_MULTIPART_THRESHOLD=6GB PARAM_MULTIPART_THRESHOLD=5.5MB \
    PARAM_MULTIPART_THRESHOLD=five PARAM_MULTIPART_CHUNKSIZE=4MB PARAM_MULTIPART_CHUNKSIZE=6GB \
    PARAM_MULTIPART_CHUNKSIZE=5242881 PARAM_MULTIPART_CHUNKSIZE=-64MB; do
    publish_new "${bad}"
    check "a usage error (2): ${bad#PARAM_}" exited 2
done
check "before any AWS call" not_logged '.'

begin "U-10: a write the AWS CLI reports as failed, though it landed"
new_case
package x86_64 hello 1.0.0-r0
publish_new
rm -rf "${CASE}/packages"
package x86_64 world 2.1-r3
# The index write lands, then answers 412: the AWS CLI's retry of a
# PutObject whose response was lost gets that from the write it made.
echo 'PutObject /APKINDEX\.tar\.gz$ landed-412 1' > "${CASE}/rules"
: > "${CASE}/aws.log"
run publish
check "the publish succeeds" succeeded
check "saying the index read back is its own" said "the index read back is the one an earlier attempt uploaded"
check "and the receipt reports the package as published, not as already there" json_is "${CASE}/apk-repo-receipt.json" \
    'r["architectures"]["x86_64"]["published"], r["architectures"]["x86_64"]["skipped_identical"], r["architectures"]["x86_64"]["attempts"]' \
    "(['world-2.1-r3.apk'], [], 2)"
check "having written the index once" [ "$(grep -c '^PutObject test/os/x86_64/APKINDEX\.tar\.gz ' "${CASE}/aws.log")" -eq 1 ]

begin "U-17: multipart uploads, continued"
new_case
big_package x86_64 big 1.0-r0
FAKE_AWS_NO_CHECKSUM_ECHO=1 publish_new "${MULTIPART[@]}"
check "a service that doesn't echo part checksums still completes the upload" succeeded
check "with the checksums computed here" logged '^CompleteMultipartUpload test/os/x86_64/big-1\.0-r0\.apk if-none-match '
new_case
mkdir -p "${CASE}/packages/x86_64"
# Nine 5 MiB parts: one batch of eight, then one more.
${FIXTURES} build "${CASE}/packages/x86_64/huge-1.0-r0.apk" huge 1.0-r0 x86_64 --key "${WORK}/keys/build.rsa" \
    --random "usr/share/huge/blob=$((42 * 1024 * 1024))"
echo 'UploadPart huge-1\.0-r0\.apk$ 500 1' > "${CASE}/rules"
publish_new "${MULTIPART[@]}"
check "a failed part fails the upload" failed
check "and no part after its batch is started" [ "$(grep -c '^UploadPart test/os/x86_64/huge' "${CASE}/aws.log")" -eq 8 ]
check "which is aborted" logged '^AbortMultipartUpload test/os/x86_64/huge-1\.0-r0\.apk '
publish_new PARAM_MULTIPART_THRESHOLD=17179869185GB
check "a size too large for 64-bit arithmetic is a usage error (2), not a wrapped-around one" exited 2

begin "U-3: a packages_dir with pattern characters in its name"
new_case
package x86_64 hello 1.0.0-r0 "${CASE}/out[1]"
publish_new PARAM_PACKAGES_DIR='out[1]'
check "is a path, not a pattern" succeeded
check "publishing its package" exists "$(s3 test/os/x86_64/hello-1.0.0-r0.apk)"
new_case
package x86_64 hello 1.0.0-r0 "${CASE}/out[1]"
publish_new PARAM_PACKAGES_DIR='out[1]' PARAM_ARCH=
check "with the architectures found in it too" succeeded

# ------------------------------------------------------------------ pull
echo "=== pull"

begin "P-1 to P-6"
new_case
package x86_64 hello 1.0.0-r0
FAKE_S3_VERSIONING=1 publish_new
: > "${CASE}/aws.log"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=pulled
check "succeeds" succeeded
check "P-8: leaves a repository apko can read" exists "${CASE}/pulled/x86_64/APKINDEX.tar.gz"
check "with the package" exists "${CASE}/pulled/x86_64/hello-1.0.0-r0.apk"
check "P-3: records the index's ETag" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["etag"] is not None' "True"
check "B-4: and VersionId in a versioned bucket" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["version_id"]' "v1"
check "P-7: never writes" not_logged '^PutObject'
check "P-3: reads the index first" python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1]).readline().split()[1].endswith("APKINDEX.tar.gz") else 1)' "${CASE}/aws.log"
run pull PARAM_OUT_DIR=pulled
check "P-1: a non-empty out_dir/<arch> is refused" exited 2
mkdir -p "${CASE}/empty/x86_64"
run pull PARAM_OUT_DIR=empty
check "P-1: an empty one is fine" succeeded

begin "P-6: cache_dir"
: > "${CASE}/aws.log"
run pull PARAM_OUT_DIR=first PARAM_CACHE_DIR=cache
check "fills the cache" exists "${CASE}/cache/x86_64/hello-1.0.0-r0.apk"
: > "${CASE}/aws.log"
run pull PARAM_OUT_DIR=second PARAM_CACHE_DIR=cache
check "reuses it" said "0 package(s) downloaded, 1 from the cache"
check "without downloading the package" not_logged 'GetObject test/os/x86_64/hello-1.0.0-r0.apk '
echo tampered >> "${CASE}/cache/x86_64/hello-1.0.0-r0.apk"
run pull PARAM_OUT_DIR=third PARAM_CACHE_DIR=cache
check "a cached file that doesn't match its signed sidecar is downloaded again" said "1 package(s) downloaded, 0 from the cache"
run verify PARAM_DIR=third
check "and the result verifies" succeeded

begin "P-2, P-4: failures"
new_case
run pull PARAM_OUT_DIR=pulled
check "P-4: no index (404) fails" failed
check "saying there is no repository" said "There is no repository at s3://bucket/test/os/x86_64"
echo "GetObject .*/APKINDEX.tar.gz 403" > "${CASE}/rules"
run pull PARAM_OUT_DIR=pulled
check "P-4: a 403 fails" failed
check "E-3: suggesting s3:ListBucket" said "s3:ListBucket"
new_case
package x86_64 hello 1.0.0-r0
publish_new
printf 'x' >> "$(s3 test/os/x86_64/hello-1.0.0-r0.apk)"
run pull PARAM_OUT_DIR=pulled
check "P-2: a tampered package fails the pull" failed
check "and nothing reaches out_dir" absent "${CASE}/pulled/x86_64"
new_case
package x86_64 hello 1.0.0-r0
publish_new
rm "$(s3 test/os/x86_64/hello-1.0.0-r0.apk.sha256)"
run pull PARAM_OUT_DIR=pulled
check "F-12: a package without its sidecar fails" failed
check "saying the repository is incomplete" said "The repository is incomplete"

begin "P-9: pinned reads (index_sha256, index_version_id)"
new_case
package x86_64 hello 1.0.0-r0
package aarch64 hello 1.0.0-r0
FAKE_S3_VERSIONING=1 publish_new PARAM_ARCH="x86_64 aarch64"
first_x86=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["architectures"]["x86_64"]["index"]["sha256"])' "${CASE}/apk-repo-receipt.json")
first_arm=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["architectures"]["aarch64"]["index"]["sha256"])' "${CASE}/apk-repo-receipt.json")
rm -rf "${CASE}/packages"
package x86_64 world 2.0-r0
package aarch64 world 2.0-r0
FAKE_S3_VERSIONING=1 run publish PARAM_ARCH="x86_64 aarch64"
current_x86=$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")
current_x86=${current_x86%% *}
check "(a second publish replaced the index with version v2)" [ "${current_x86}" != "${first_x86}" ]
: > "${CASE}/aws.log"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=current PARAM_INDEX_SHA256="${current_x86}"
check "the current index's SHA-256 pins it" succeeded
check "saying so" said "is the ${current_x86} index_sha256 pins"
check "and the receipt records the pull as pinned" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["pinned"], r["architectures"]["x86_64"]["index"]["sha256"] == "'"${current_x86}"'"' "(True, True)"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=upper PARAM_INDEX_SHA256="${current_x86^^}"
check "a SHA-256 in upper case works too" succeeded
: > "${CASE}/aws.log"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=stale PARAM_INDEX_SHA256="${first_x86}"
check "an index with other bytes fails (1)" exited 1
check "naming both SHA-256s" said "SHA-256 is ${current_x86}, not the ${first_x86} index_sha256 pins"
check "suggesting index_version_id" said "set index_version_id too"
check "before anything but the index is read" [ "$(grep -c '^GetObject' "${CASE}/aws.log")" -eq 1 ]
check "leaving out_dir empty" absent "${CASE}/stale/x86_64"
: > "${CASE}/aws.log"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=snapshot PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID=v1
check "with index_version_id, the earlier snapshot is pulled again" succeeded
check "reading that version of the index" logged '^GetObject test/os/x86_64/APKINDEX.tar.gz version=v1 '
check "and only the version of the index" [ "$(grep -c 'version=' "${CASE}/aws.log")" -eq 1 ]
check "with the packages it lists" exists "${CASE}/snapshot/x86_64/hello-1.0.0-r0.apk"
check "and none it doesn't" absent "${CASE}/snapshot/x86_64/world-2.0-r0.apk"
check "recording the version in the receipt" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["version_id"], r["architectures"]["x86_64"]["index"]["sha256"] == "'"${first_x86}"'"' "('v1', True)"
run verify PARAM_DIR=snapshot PARAM_INDEX_SHA256="${first_x86}"
check "verify accepts the snapshot with the same pin" succeeded
check "and records it as pinned" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["pinned"]' "True"
run verify PARAM_DIR=current PARAM_INDEX_SHA256="${first_x86}"
check "verify refuses another index (1)" exited 1
check "saying it isn't the one pinned" said "This isn't the index pinned"
run verify PARAM_DIR=current
check "an unpinned verify records pinned: false" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["pinned"]' "False"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=mixed PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID=v2
check "a version that isn't the pinned index fails (1)" exited 1
check "saying to take both from the same receipt" said "from the same receipt"
check "with nothing in out_dir" absent "${CASE}/mixed/x86_64"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=gone PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID=v9
check "a version that doesn't exist fails (1)" exited 1
check "naming it" said "has no version v9 (index_version_id)"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=dash PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID=-v1
check "a version ID starting with - reaches S3 as a version, not an option" said "has no version -v1"
FAKE_S3_VERSIONING=1 FAKE_AWS_IGNORE_VERSION_ID=1 run pull PARAM_OUT_DIR=ignored PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID=v1
check "a service that ignores the version fails (1)" exited 1
check "saying it may not support versions" said "may not support object versions"
echo "GetObject .*/APKINDEX.tar.gz 403" > "${CASE}/rules"
FAKE_S3_VERSIONING=1 run pull PARAM_OUT_DIR=denied PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID=v1
check "a denied version fails" exited 1
check "E-3: naming s3:GetObjectVersion" said "s3:GetObjectVersion"
: > "${CASE}/rules"
FAKE_S3_VERSIONING=1 run pull PARAM_ARCH="x86_64 aarch64" PARAM_OUT_DIR=both \
    PARAM_INDEX_SHA256="aarch64=${first_arm} x86_64=${first_x86}" PARAM_INDEX_VERSION_ID="x86_64=v1 aarch64=v1"
check "<arch>=<value> pairs pin each architecture" succeeded
check "to its own snapshot" json_is "${CASE}/apk-repo-receipt.json" 'sorted((a, len(x["packages"]), x["index"]["pinned"]) for a, x in r["architectures"].items())' "[('aarch64', 1, True), ('x86_64', 1, True)]"
: > "${CASE}/aws.log"
# refused DESCRIPTION MESSAGE NAME=VALUE...: a pull of both architectures
# with these settings is a usage error (2), saying MESSAGE.
refused() {
    local description=$1 message=$2
    shift 2
    run pull PARAM_ARCH="x86_64 aarch64" PARAM_OUT_DIR=refused "$@"
    check "a usage error (2): ${description}" exited 2
    check "saying so" said "${message}"
}
refused "one value for two architectures" "index_sha256 gives one value for 2 architectures (x86_64 aarch64)" \
    PARAM_INDEX_SHA256="${first_x86}"
refused "a pair for one of two architectures" "index_sha256 gives no value for aarch64" \
    PARAM_INDEX_SHA256="x86_64=${first_x86}"
refused "an architecture twice" "index_sha256 gives x86_64 more than once" \
    PARAM_INDEX_SHA256="x86_64=${first_x86} aarch64=${first_arm} x86_64=${first_x86}"
refused "an unknown architecture" "must be <arch>=<value>, with x86_64 or aarch64 as <arch>" \
    PARAM_INDEX_SHA256="x86_64=${first_x86} riscv64=${first_arm}"
refused "a pair and a bare value" "must be <arch>=<value>" \
    PARAM_INDEX_SHA256="x86_64=${first_x86} ${first_arm}"
refused "a pair whose value isn't a SHA-256" "index_sha256 for x86_64, 'nothex', isn't a SHA-256" \
    PARAM_INDEX_SHA256="x86_64=nothex aarch64=${first_arm}"
refused "a version without index_sha256" "index_version_id needs index_sha256" \
    PARAM_INDEX_VERSION_ID="x86_64=v1 aarch64=v1"
run pull PARAM_OUT_DIR=refused "PARAM_INDEX_SHA256=aarch64=${first_arm}"
check "a usage error (2) for a pair naming an arch that isn't pulled" exited 2
check "saying arch doesn't list it" said "gives a value for aarch64, which arch doesn't list (x86_64)"
run pull PARAM_OUT_DIR=refused PARAM_INDEX_SHA256="${first_x86:0:63}"
check "a usage error (2) for a SHA-256 one character short" exited 2
check "saying what it must be" said "isn't a SHA-256 in hex (64 characters)"
run pull PARAM_OUT_DIR=refused PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID='v1;x'
check "a usage error (2) for a version ID with other characters" exited 2
check "saying what it must be" said "isn't an S3 version ID"
run pull PARAM_OUT_DIR=refused PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID="$(printf 'v%.0s' $(seq 1025))"
check "a usage error (2) for a version ID over 1024 characters" exited 2
check "saying so" said "an S3 version ID is at most 1024"
run pull PARAM_OUT_DIR=refused PARAM_INDEX_SHA256='*'
check "a usage error (2) for a value that is a glob" exited 2
check "taken as it is, not as the files it matches" said "index_sha256 '*' isn't a SHA-256"
run verify PARAM_DIR=snapshot PARAM_INDEX_SHA256=nothex
check "verify: a usage error (2) for a value that isn't a SHA-256" exited 2
check "no AWS call was made for any of them" not_logged '.'
new_case
package x86_64 hello 1.0.0-r0
publish_new
pinned=$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")
run pull PARAM_OUT_DIR=null PARAM_INDEX_SHA256="${pinned%% *}" PARAM_INDEX_VERSION_ID=null
check "the version null is an object written before versioning" succeeded
run pull PARAM_OUT_DIR=unversioned PARAM_INDEX_SHA256="${pinned%% *}" PARAM_INDEX_VERSION_ID=v1
check "another version in an unversioned bucket fails (1)" exited 1
check "with the service's message" said "Invalid version id specified"

begin "P-10: selective pulls (packages)"
new_case
package x86_64 hello 1.0.0-r0
package x86_64 hello 1.1.0-r0
package x86_64 world 2.1-r3
package aarch64 hello 1.0.0-r0
package aarch64 world 2.1-r3
publish_new PARAM_ARCH="x86_64 aarch64"
: > "${CASE}/aws.log"
run pull PARAM_OUT_DIR=some PARAM_PACKAGES="hello=1.0.0-r0 world=2.1-r3"
check "succeeds" succeeded
check "saying how many it selected" said "Selected 2 of the 3 package(s) s3://bucket/test/os/x86_64/APKINDEX.tar.gz lists."
check "pulling the selected packages" exists "${CASE}/some/x86_64/hello-1.0.0-r0.apk"
check "all of them" exists "${CASE}/some/x86_64/world-2.1-r3.apk"
check "and not the others" absent "${CASE}/some/x86_64/hello-1.1.0-r0.apk"
check "nor their sidecars" absent "${CASE}/some/x86_64/hello-1.1.0-r0.apk.sha256"
check "with the whole signed index, as it is" cmp -s "${CASE}/some/x86_64/APKINDEX.tar.gz" "$(s3 test/os/x86_64/APKINDEX.tar.gz)"
check "never reading another package or its sidecar" not_logged 'hello-1\.1\.0-r0'
check "the receipt lists only what was pulled" json_is "${CASE}/apk-repo-receipt.json" '[p["file"] for p in r["architectures"]["x86_64"]["packages"]]' "['hello-1.0.0-r0.apk', 'world-2.1-r3.apk']"
check "and records the selection" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["selection"]' "['hello=1.0.0-r0', 'world=2.1-r3']"
run verify PARAM_DIR=some
check "V-9: verify without packages refuses a selective pull's directory" exited 1
check "naming the package it lacks" said "some/x86_64/hello-1.1.0-r0.apk is missing; the index lists hello 1.1.0-r0."
run verify PARAM_DIR=some PARAM_PACKAGES="hello=1.0.0-r0 world=2.1-r3"
check "V-9: with the same packages, verify accepts it" succeeded
check "saying it checked the selected packages" said "and the 2 package(s) packages selects."
check "and records the selection" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["selection"], len(r["architectures"]["x86_64"]["packages"])' "(['hello=1.0.0-r0', 'world=2.1-r3'], 2)"
printf 'x' >> "${CASE}/some/x86_64/world-2.1-r3.apk"
run verify PARAM_DIR=some PARAM_PACKAGES="hello=1.0.0-r0 world=2.1-r3"
check "V-9: a changed selected package still fails" exited 1
check "on its signed sidecar" said "its signed sidecar names"
run pull PARAM_OUT_DIR=all
run verify PARAM_DIR=all PARAM_PACKAGES="hello=1.1.0-r0"
check "V-9: verify of a full pull with packages checks only those" succeeded
check "warning that the others weren't verified" said "WARN: all/x86_64/hello-1.0.0-r0.apk is in the index but not in packages, so it wasn't verified."
check "once for each package, not for its sidecar" [ "$(grep -c 'not in packages' <<< "${OUTPUT}")" -eq 2 ]
check "without calling them unlisted" not_said "is not part of the index"
check "recording that selection" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["selection"]' "['hello=1.1.0-r0']"
run verify PARAM_DIR=all
check "and an unselective one, a null selection" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["selection"]' "None"
run pull PARAM_ARCH="x86_64 aarch64" PARAM_OUT_DIR=both PARAM_PACKAGES=$'world=2.1-r3\n'
check "packages applies to every architecture, and may span lines" succeeded
check "pulling it for each" json_is "${CASE}/apk-repo-receipt.json" '{a: [p["file"] for p in x["packages"]] for a, x in r["architectures"].items()}' "{'aarch64': ['world-2.1-r3.apk'], 'x86_64': ['world-2.1-r3.apk']}"
: > "${CASE}/aws.log"
run pull PARAM_ARCH="x86_64 aarch64" PARAM_OUT_DIR=partial PARAM_PACKAGES="hello=1.1.0-r0"
check "a version one architecture's index doesn't list fails (1)" exited 1
check "naming the index and the version" said "s3://bucket/test/os/aarch64/APKINDEX.tar.gz doesn't list hello=1.1.0-r0, which packages selects."
check "suggesting inspect" said "inspect reports which those are"
check "and nothing reaches out_dir" absent "${CASE}/partial/x86_64"
: > "${CASE}/aws.log"
run pull PARAM_OUT_DIR=unlisted PARAM_PACKAGES="hello=9.9-r0 world=2.1-r3 nope=1.0-r0"
check "versions the index doesn't list fail (1)" exited 1
check "naming all of them" said "doesn't list hello=9.9-r0 nope=1.0-r0, which packages selects."
check "before any package is read" [ "$(grep -c . "${CASE}/aws.log")" -eq 1 ]
run pull PARAM_OUT_DIR=pinned PARAM_PACKAGES="hello=1.0.0-r0" \
    PARAM_INDEX_SHA256="$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)" | cut -c1-64)"
check "packages and index_sha256 work together" json_is "${CASE}/apk-repo-receipt.json" '[p["file"] for p in r["architectures"]["x86_64"]["packages"]], r["architectures"]["x86_64"]["index"]["pinned"]' "(['hello-1.0.0-r0.apk'], True)"
run pull PARAM_OUT_DIR=cached PARAM_PACKAGES="hello=1.0.0-r0" PARAM_CACHE_DIR=cache
run pull PARAM_OUT_DIR=cached2 PARAM_PACKAGES="hello=1.0.0-r0" PARAM_CACHE_DIR=cache
check "and so do packages and cache_dir" said "0 package(s) downloaded, 1 from the cache"
: > "${CASE}/aws.log"
# refused_packages DESCRIPTION MESSAGE VALUE: pull and verify with packages
# VALUE are usage errors (2), saying MESSAGE.
refused_packages() {
    run pull PARAM_OUT_DIR=refused PARAM_PACKAGES="$3"
    check "a usage error (2): $1" exited 2
    check "saying so" said "$2"
    run verify PARAM_DIR=all PARAM_PACKAGES="$3"
    check "for verify too" exited 2
}
refused_packages "an entry without a version" "packages entry 'hello' must be <name>=<version>" "hello"
refused_packages "a version without its release" "'1.0.0' isn't a package version with its release" "hello=1.0.0"
refused_packages "an invalid name" "'bad@name' isn't a package name" "bad@name=1.0-r0"
refused_packages "an entry twice" "packages lists hello=1.0.0-r0 more than once" "hello=1.0.0-r0 world=2.1-r3 hello=1.0.0-r0"
refused_packages "a glob, taken as it is" "packages entry '*' must be <name>=<version>" "*"
check "no AWS call was made for any of them" not_logged '.'

# ------------------------------------------------------------------ inspect
echo "=== inspect"

begin "I-1, I-2: what the index lists"
new_case
package x86_64 hello 1.0.0-r0
package x86_64 world 2.1-r3
package aarch64 hello 1.0.0-r0
FAKE_S3_VERSIONING=1 publish_new PARAM_ARCH="x86_64 aarch64"
first_x86=$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")
first_x86=${first_x86%% *}
: > "${CASE}/aws.log"
FAKE_S3_VERSIONING=1 run inspect PARAM_ARCH="x86_64 aarch64"
check "succeeds for both architectures" succeeded
check "I-1: reading each architecture's index" logged '^GetObject test/os/x86_64/APKINDEX.tar.gz '
check "both of them" logged '^GetObject test/os/aarch64/APKINDEX.tar.gz '
check "and nothing else" [ "$(grep -c . "${CASE}/aws.log")" -eq 2 ]
check "I-1: writing nothing to the bucket" not_logged '^PutObject'
check "or to the working directory but the receipt" [ -z "$(find "${CASE}" -mindepth 1 -maxdepth 1 ! -name s3 ! -name tmp ! -name bash_env \
    ! -name aws.log ! -name rules ! -name packages ! -name apk-repo-receipt.json)" ]
check "I-2: listing every package of each index" json_is "${CASE}/apk-repo-receipt.json" '{a: [(p["name"], p["version"], p["file"]) for p in x["packages"]] for a, x in r["architectures"].items()}' \
    "{'aarch64': [('hello', '1.0.0-r0', 'hello-1.0.0-r0.apk')], 'x86_64': [('hello', '1.0.0-r0', 'hello-1.0.0-r0.apk'), ('world', '2.1-r3', 'world-2.1-r3.apk')]}"
check "with the size the index gives" json_is "${CASE}/apk-repo-receipt.json" '[p["size"] for p in r["architectures"]["x86_64"]["packages"]]' \
    "[$(stat -c %s "$(s3 test/os/x86_64/hello-1.0.0-r0.apk)"), $(stat -c %s "$(s3 test/os/x86_64/world-2.1-r3.apk)")]"
check "and no SHA-256, since no sidecar is read" json_is "${CASE}/apk-repo-receipt.json" 'set(p["sha256"] for x in r["architectures"].values() for p in x["packages"])' "{None}"
check "recording the operation" json_is "${CASE}/apk-repo-receipt.json" 'r["operation"], r["key_name"], r["prefix"]' "('inspect', None, 'test/os')"
check "and the index read, as a later pin needs it" json_is "${CASE}/apk-repo-receipt.json" \
    '[r["architectures"]["x86_64"]["index"][k] for k in ("version_id", "signature", "pinned")], r["architectures"]["x86_64"]["index"]["sha256"] == "'"${first_x86}"'"' \
    "(['v1', '.SIGN.RSA256.test-apk.rsa.pub', False], True)"
check "saying how many packages each index lists" said "Inspected x86_64: an index signed with test-apk.rsa that lists 2 package(s)."
check "O-2: exports the receipt's path" file_has "${CASE}/bash_env" "export APK_REPO_RECEIPT=${CASE}/apk-repo-receipt.json"
run inspect PARAM_KEYRING="${WORK}/other-keyring"
check "I-4: an index signed with a key the keyring lacks fails" failed
check "naming the keyring file it needs" said "the keyring has no test-apk.rsa.pub"
check "and writes no receipt" absent "${CASE}/apk-repo-receipt.json"
rm -rf "${CASE}/packages"
package x86_64 later 3.0-r0
FAKE_S3_VERSIONING=1 run publish
FAKE_S3_VERSIONING=1 run inspect PARAM_INDEX_SHA256="${first_x86}"
check "I-5: a pin to a replaced index fails" exited 1
check "suggesting index_version_id" said "set index_version_id too"
FAKE_S3_VERSIONING=1 run inspect PARAM_INDEX_SHA256="${first_x86}" PARAM_INDEX_VERSION_ID=v1
check "I-5: with its version, the replaced index is inspected again" succeeded
check "listing what it listed then" json_is "${CASE}/apk-repo-receipt.json" '[p["file"] for p in r["architectures"]["x86_64"]["packages"]], r["architectures"]["x86_64"]["index"]["pinned"]' \
    "(['hello-1.0.0-r0.apk', 'world-2.1-r3.apk'], True)"
FAKE_S3_VERSIONING=1 run inspect
check "and without a pin, the current one" json_is "${CASE}/apk-repo-receipt.json" 'sorted(p["file"] for p in r["architectures"]["x86_64"]["packages"])' \
    "['hello-1.0.0-r0.apk', 'later-3.0-r0.apk', 'world-2.1-r3.apk']"

begin "I-3: no repository yet"
new_case
run inspect
check "a missing index fails (1)" exited 1
check "saying there is no repository" said "There is no repository at s3://bucket/test/os/x86_64"
check "and writes no receipt" absent "${CASE}/apk-repo-receipt.json"
run inspect PARAM_ALLOW_MISSING=true
check "allow_missing reports it as empty" succeeded
check "saying so" said "allow_missing reports it as empty"
check "with a null index and no packages" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]' "{'x86_64': {'index': None, 'packages': []}}"
run inspect PARAM_ALLOW_MISSING=1
check "allow_missing takes CircleCI's 1 for true" succeeded
run inspect PARAM_ALLOW_MISSING=yes
check "and refuses anything but a boolean (2)" exited 2
echo "GetObject .*/APKINDEX.tar.gz 403" > "${CASE}/rules"
run inspect PARAM_ALLOW_MISSING=true
check "E-3: a 403 fails even with allow_missing, since it may hide an index" exited 1
check "suggesting s3:ListBucket" said "s3:ListBucket"
: > "${CASE}/rules"
run inspect PARAM_ALLOW_MISSING=true PARAM_INDEX_SHA256="$(printf '0%.0s' $(seq 64))"
check "a missing index that index_sha256 pins fails even with allow_missing" exited 1
check "saying there is no repository" said "There is no repository at"
package x86_64 hello 1.0.0-r0
publish_new
run inspect PARAM_ARCH="x86_64 aarch64" PARAM_ALLOW_MISSING=true
check "with two architectures, one of them published" succeeded
check "reports the one with an index, and the other as empty" json_is "${CASE}/apk-repo-receipt.json" \
    '{a: (x["index"] is not None, len(x["packages"])) for a, x in r["architectures"].items()}' "{'aarch64': (False, 0), 'x86_64': (True, 1)}"
: > "${CASE}/aws.log"
run inspect PARAM_PREFIX=$'ok\n../../other/os'
check "a usage error (2) for a bad prefix" exited 2
run inspect PARAM_BUCKET=
check "and for no bucket" exited 2
run inspect PARAM_INDEX_VERSION_ID=v1
check "and for a version without index_sha256" exited 2
check "before any AWS call" not_logged '.'

# ------------------------------------------------------------------ edges
echo "=== edge cases"

# s3_put KEY FILE: an object written into the case's bucket by someone
# else, such as an earlier publish that didn't finish.
s3_put() {
    (cd "${CASE}" && env PATH="${STUBS}:${PATH}" FAKE_S3_DIR="${CASE}/s3" \
        aws s3api put-object --bucket bucket --key "$1" --body "$2" --if-none-match "*" > /dev/null)
}

begin "P-11: pull reads only what it needs, and passes on only what verified"
new_case
package x86_64 hello 1.0.0-r0
package x86_64 world 2.1-r3
package aarch64 hello 1.0.0-r0
publish_new PARAM_ARCH="x86_64 aarch64"
# A keyring with a second key, as during a key rotation: pull then fetches
# each sidecar's signature by that key too, which anyone who can create
# objects in the bucket can plant.
mkdir -p "${CASE}/two-keys"
cp "${WORK}/keys/test-apk.rsa.pub" "${WORK}/keys/other-apk.rsa.pub" "${CASE}/two-keys/"
head -c 512 /dev/urandom > "${CASE}/bad.sig"
s3_put test/os/x86_64/hello-1.0.0-r0.apk.sha256.other-apk.rsa.sig "${CASE}/bad.sig"
: > "${CASE}/empty.sig"
s3_put test/os/x86_64/world-2.1-r3.apk.sha256.other-apk.rsa.sig "${CASE}/empty.sig"
head -c $((1024 * 1024)) /dev/urandom > "${CASE}/huge.sig"
s3_put test/os/aarch64/hello-1.0.0-r0.apk.sha256.other-apk.rsa.sig "${CASE}/huge.sig"
: > "${CASE}/aws.log"
run pull PARAM_ARCH="x86_64 aarch64" PARAM_KEYRING="${CASE}/two-keys" PARAM_OUT_DIR=pulled
check "stray signatures by another keyring key don't fail the pull" succeeded
check "one that doesn't verify is warned about" said "WARN: hello-1.0.0-r0.apk.sha256.other-apk.rsa.sig doesn't verify with other-apk.rsa.pub"
check "and doesn't reach out_dir" absent "${CASE}/pulled/x86_64/hello-1.0.0-r0.apk.sha256.other-apk.rsa.sig"
check "while the signature that verified does" exists "${CASE}/pulled/x86_64/hello-1.0.0-r0.apk.sha256.test-apk.rsa.sig"
check "an empty one (which a Range request can't be satisfied for) doesn't either" absent "${CASE}/pulled/x86_64/world-2.1-r3.apk.sha256.other-apk.rsa.sig"
check "one larger than a signature can be is ignored with a warning" said "is larger than a signature can be (8192 bytes); ignoring it."
check "without reading more than 8193 bytes of it" logged '^GetObject test/os/aarch64/hello-1\.0\.0-r0\.apk\.sha256\.other-apk\.rsa\.sig range=bytes=0-8192 '
check "and doesn't reach out_dir" absent "${CASE}/pulled/aarch64/hello-1.0.0-r0.apk.sha256.other-apk.rsa.sig"
check "every download asks for no more than it can use" not_logged '^GetObject [^ ]+ none '
check "an index, at most 128 MiB" logged '^GetObject test/os/x86_64/APKINDEX\.tar\.gz range=bytes=0-134217728 '
check "a sidecar, its exact line" logged '^GetObject test/os/x86_64/hello-1\.0\.0-r0\.apk\.sha256 range=bytes=0-85 '
check "a package, the size the index gives" logged "^GetObject test/os/x86_64/hello-1\\.0\\.0-r0\\.apk range=bytes=0-$(stat -c %s "$(s3 test/os/x86_64/hello-1.0.0-r0.apk)") "
run verify PARAM_ARCH="x86_64 aarch64" PARAM_KEYRING="${CASE}/two-keys" PARAM_DIR=pulled
check "and verify accepts what pull wrote" succeeded

printf 'more\n' >> "$(s3 test/os/x86_64/world-2.1-r3.apk.sha256)"
run pull PARAM_OUT_DIR=long-sidecar
check "a sidecar longer than its one line fails the pull" exited 1
check "saying so, without reading the rest" said "world-2.1-r3.apk.sha256 is larger than the 83 bytes it can be for world 2.1-r3"
printf 'x' >> "$(s3 test/os/aarch64/hello-1.0.0-r0.apk)"
run pull PARAM_ARCH=aarch64 PARAM_OUT_DIR=long-package
check "a package larger than the index says fails the pull" exited 1
check "saying so, without reading the rest" said "hello-1.0.0-r0.apk is larger than the"
check "and nothing reaches out_dir" absent "${CASE}/long-package/aarch64"

new_case
printf 'index\n' > "${CASE}/index"
s3_put test/os/x86_64/APKINDEX.tar.gz "${CASE}/index"
# Sparse: 200 MiB in the bucket, of which the pull may read 128 MiB and a byte.
truncate -s $((200 * 1024 * 1024)) "$(s3 test/os/x86_64/APKINDEX.tar.gz)"
run pull PARAM_OUT_DIR=pulled
check "an index larger than 128 MiB fails the pull" exited 1
check "saying so" said "is larger than an index can be (134217728 bytes)"
run inspect
check "and inspect" said "is larger than an index can be"

new_case
package x86_64 hello 1.0.0-r0
package aarch64 hello 1.0.0-r0
package x86_64 world 2.1-r3
publish_new PARAM_ARCH="x86_64 aarch64"
: > "${CASE}/aws.log"
run pull PARAM_ARCH="x86_64 aarch64" PARAM_OUT_DIR=pulled PARAM_PACKAGES="world=2.1-r3"
check "P-10: packages one architecture's index doesn't list fails" exited 1
check "before any package or sidecar of any architecture is read" [ "$(grep -c '^GetObject' "${CASE}/aws.log")" -eq "$(grep -c '^GetObject [^ ]*/APKINDEX\.tar\.gz ' "${CASE}/aws.log")" ]
: > "${CASE}/aws.log"
run pull PARAM_ARCH="x86_64 aarch64" PARAM_OUT_DIR=pulled \
    PARAM_INDEX_SHA256="x86_64=$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)" | cut -c1-64) aarch64=$(printf '0%.0s' $(seq 64))"
check "P-9: a pin one architecture's index doesn't match fails" exited 1
check "before any package or sidecar of any architecture is read" [ "$(grep -c '^GetObject' "${CASE}/aws.log")" -eq "$(grep -c '^GetObject [^ ]*/APKINDEX\.tar\.gz ' "${CASE}/aws.log")" ]

: > "${CASE}/aws.log"
printf 'a file\n' > "${CASE}/file"
run pull PARAM_OUT_DIR=file
check "P-1: an out_dir that is a file is a usage error (2)" exited 2
run pull PARAM_CACHE_DIR=file
check "and so is a cache_dir that is a file" exited 2
mkdir -p "${CASE}/cache"
printf 'a file\n' > "${CASE}/cache/x86_64"
run pull PARAM_CACHE_DIR=cache
check "and a cache_dir/<arch> that is a file" exited 2
check "all before any AWS call" not_logged '.'
rm -f "${CASE}/cache/x86_64"
ln -s "${CASE}/nowhere" "${CASE}/cache/x86_64"
run pull PARAM_OUT_DIR=dangling PARAM_CACHE_DIR=cache
check "P-6: a dangling symbolic link at cache_dir/<arch> doesn't fail the pull" succeeded
check "which leaves it alone, with a warning" said "WARN: cache_dir cache/x86_64 is a symbolic link; leaving it as it is."
check "and fills out_dir" exists "${CASE}/dangling/x86_64/hello-1.0.0-r0.apk"
check "and writes the receipt" exists "${CASE}/apk-repo-receipt.json"
run pull PARAM_OUT_DIR=-out PARAM_CACHE_DIR=-cache
check "an out_dir and a cache_dir that start with - are paths, not options" succeeded
check "filling out_dir" exists "${CASE}/-out/x86_64/hello-1.0.0-r0.apk"
check "and the cache" exists "${CASE}/-cache/x86_64/hello-1.0.0-r0.apk"

begin "E-1: an architecture list that comes out empty"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
mkdir -p "${CASE}/riscv"
printf '#!/bin/sh\necho riscv64\n' > "${CASE}/riscv/uname"
chmod +x "${CASE}/riscv/uname"
run verify PARAM_DIR=repo PARAM_ARCH=" "
check "an arch of only spaces is the machine's own" json_is "${CASE}/apk-repo-receipt.json" 'list(r["architectures"])' "['x86_64']"
run verify PARAM_DIR=repo PARAM_ARCH= PATH="${CASE}/riscv:${STUBS}:${PATH}"
check "on a machine that is neither architecture, verify fails (2)" exited 2
check "naming it" said "This machine is riscv64"
check "and writes no receipt for nothing" not_said "Wrote the receipt"
run pull PARAM_OUT_DIR=pulled PARAM_ARCH= PATH="${CASE}/riscv:${STUBS}:${PATH}"
check "so does pull" exited 2

begin "F-2: a prefix is checked as a whole"
new_case
package x86_64 hello 1.0.0-r0
publish_new PARAM_PREFIX=$'ok\n../../other/os'
check "a prefix with a newline is refused" exited 2
check "before any AWS call" not_logged '.'

begin "S-4: the index's receipt data is checked before it is written"
new_case
package x86_64 aaa 1.0-r0
publish_new
rm -rf "${CASE}/packages"
package x86_64 bbb 1.0-r0
before=$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")
echo 'GetObject aaa-1.0-r0\.apk\.sha256$ 500 1' > "${CASE}/rules"
run publish
check "an old entry's sidecar that can't be read fails the publish" failed
check "before the index is replaced" [ "$(sha256sum < "$(s3 test/os/x86_64/APKINDEX.tar.gz)")" == "${before}" ]
: > "${CASE}/rules"
run publish
check "and the next publish succeeds" succeeded
check "with both packages in its receipt" json_is "${CASE}/apk-repo-receipt.json" 'sorted(p["file"] for p in r["architectures"]["x86_64"]["packages"])' "['aaa-1.0-r0.apk', 'bbb-1.0-r0.apk']"

begin "U-4, U-7: what an earlier publish left at a new package's key"
new_case
package x86_64 hello 1.0.0-r0
# The package as melange built it, signed with the build key, never re-signed.
s3_put test/os/x86_64/hello-1.0.0-r0.apk "${CASE}/packages/x86_64/hello-1.0.0-r0.apk"
publish_new PARAM_DRY_RUN=true
check "a dry run finds it" failed
check "and says it isn't signed with key_name alone" said "signed as '.SIGN.RSA256.build.rsa.pub', not only by test-apk.rsa"
publish_new
check "a real run refuses to adopt it" failed
check "and leaves no index" absent "$(s3 test/os/x86_64/APKINDEX.tar.gz)"
new_case
package x86_64 hello 1.0.0-r0
package x86_64 hello 1.0.0-r0 "${CASE}/other" "another build"
s3_put test/os/x86_64/hello-1.0.0-r0.apk "${CASE}/other/x86_64/hello-1.0.0-r0.apk"
publish_new PARAM_DRY_RUN=true
check "U-13: a dry run finds a different build at the key" failed
check "saying packages are immutable" said "already exists with different contents; packages are immutable"

begin "U-13: what an earlier publish left at a new package's sidecar"
new_case
package x86_64 hello 1.0.0-r0
printf 'junk\n' > "${CASE}/junk.sha256"
s3_put test/os/x86_64/hello-1.0.0-r0.apk.sha256 "${CASE}/junk.sha256"
publish_new PARAM_DRY_RUN=true
check "a dry run finds a different .sha256" failed
check "saying it is immutable" said "hello-1.0.0-r0.apk.sha256 already exists with different contents; it is immutable."
publish_new
check "as the real run does" said "hello-1.0.0-r0.apk.sha256 already exists with different contents; it is immutable."

begin "S-8: rotating the signing key"
new_case
package x86_64 hello 1.0.0-r0
publish_new
mkdir -p "${CASE}/rotation"
cp "${WORK}/keys/test-apk.rsa.pub" "${WORK}/keys/other-apk.rsa.pub" "${CASE}/rotation/"
run publish PARAM_KEYRING="${CASE}/rotation" PARAM_KEY_NAME=other-apk.rsa APK_SIGNING_KEY="$(cat "${WORK}/keys/other-apk.rsa")" PARAM_DRY_RUN=true
check "a dry run with the new key_name and nothing new would sign the index" said "would sign the index with other-apk.rsa"
run publish PARAM_KEYRING="${CASE}/rotation" PARAM_KEY_NAME=other-apk.rsa APK_SIGNING_KEY="$(cat "${WORK}/keys/other-apk.rsa")"
check "the real run succeeds" succeeded
check "signing the unchanged index with the new key" json_is "${CASE}/apk-repo-receipt.json" 'r["architectures"]["x86_64"]["index"]["signature"], r["architectures"]["x86_64"]["published"]' "('.SIGN.RSA256.other-apk.rsa.pub', [])"
check "with If-Match" logged '^PutObject test/os/x86_64/APKINDEX.tar.gz if-match'
run pull PARAM_OUT_DIR=pulled PARAM_KEYRING="${CASE}/rotation"
check "pull reads it with both keys in the keyring" succeeded
: > "${CASE}/aws.log"
run publish PARAM_KEYRING="${CASE}/rotation" PARAM_KEY_NAME=other-apk.rsa APK_SIGNING_KEY="$(cat "${WORK}/keys/other-apk.rsa")"
check "a second publish leaves it as it is" not_logged '^PutObject test/os/x86_64/APKINDEX.tar.gz'

begin "S-6: a sparse entry in an archive"
new_case
python3 -I - "${CASE}/sparse.tar.gz" << 'EOF'
# An index whose signature tar holds a GNU sparse entry claiming 1 GiB.
import gzip, sys, tarfile
info = tarfile.TarInfo(".SIGN.RSA256.test-apk.rsa.pub")
info.type = tarfile.GNUTYPE_SPARSE
header = bytearray(info.tobuf(tarfile.GNU_FORMAT, "utf-8", "strict"))
header[483:495] = b"%011o\0" % (1 << 30)
header[148:156] = b"        "
header[148:156] = b"%06o\0 " % sum(header)
open(sys.argv[1], "wb").write(gzip.compress(bytes(header)) + gzip.compress(b"\0" * 1024))
EOF
RC=0
OUTPUT=$(python3 -I "${ROOT}/src/scripts/apk_repo.py" index-split "${CASE}/sparse.tar.gz" "${CASE}" 2>&1) || RC=$?
check "is refused before its contents are read" exited 1
check "as not a plain regular file" said "which is not a plain regular file"

begin "V-6: a signature that doesn't verify beside one that does"
new_case
package x86_64 hello 1.0.0-r0
publish_new
printf 'junk' > "${CASE}/junk.sig"
s3_put test/os/x86_64/hello-1.0.0-r0.apk.sha256.other-apk.rsa.sig "${CASE}/junk.sig"
mkdir -p "${CASE}/both"
cp "${WORK}/keys/test-apk.rsa.pub" "${WORK}/keys/other-apk.rsa.pub" "${CASE}/both/"
run pull PARAM_OUT_DIR=pulled PARAM_KEYRING="${CASE}/both"
check "is a warning, not a failure" succeeded
check "naming it, once" [ "$(grep -c "WARN: hello-1.0.0-r0.apk.sha256.other-apk.rsa.sig doesn't verify with other-apk.rsa.pub" <<< "${OUTPUT}")" -eq 1 ]

begin "V-4: the signature is checked before the index is read"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
${FIXTURES} index "${CASE}/repo/x86_64/APKINDEX.tar.gz" --key "${WORK}/keys/other-apk.rsa" "${CASE}/repo/x86_64/hello-1.0.0-r0.apk"
run verify PARAM_DIR=repo
check "an index by a key the keyring lacks fails on its key" said "the keyring has no other-apk.rsa.pub"

begin "P-6: a symbolic link left in cache_dir"
new_case
package x86_64 hello 1.0.0-r0
publish_new
mkdir -p "${CASE}/cache/x86_64"
echo "outside" > "${CASE}/outside"
ln -s "${CASE}/outside" "${CASE}/cache/x86_64/.hello-1.0.0-r0.apk.partial"
ln -s "${CASE}/outside" "${CASE}/cache/x86_64/hello-1.0.0-r0.apk"
run pull PARAM_OUT_DIR=pulled PARAM_CACHE_DIR=cache
check "pull succeeds" succeeded
check "without writing through it" [ "$(cat "${CASE}/outside")" == "outside" ]
check "replacing the cache entry with the package" cmp -s "${CASE}/cache/x86_64/hello-1.0.0-r0.apk" "${CASE}/pulled/x86_64/hello-1.0.0-r0.apk"

begin "U-1, S-1: the signing key"
new_case
package x86_64 hello 1.0.0-r0
rm -f "${WORK}/key-seen"
publish_new
check "no tool publish runs (aws, python3, openssl, melange) has the key in its environment" absent "${WORK}/key-seen"
rm -f "${WORK}/key-seen"
publish_new PARAM_SIGNING_KEY=SIGNING_KEY SIGNING_KEY="${SIGNING_KEY_PEM}" APK_SIGNING_KEY=
check "signing_key may name a variable the script itself uses (SIGNING_KEY)" succeeded
check "and no tool sees that one either" absent "${WORK}/key-seen"
publish_new PARAM_SIGNING_KEY=AR_KEY AR_KEY="${SIGNING_KEY_PEM}"
check "but not one of the orb's own names (AR_*), a usage error (2)" exited 2
publish_new PARAM_SIGNING_KEY=PARAM_KEY PARAM_KEY="${SIGNING_KEY_PEM}"
check "or PARAM_*" exited 2
openssl genrsa -aes256 -passout pass:secret -out "${CASE}/encrypted.pem" 2048 2> /dev/null
publish_new APK_SIGNING_KEY="$(cat "${CASE}/encrypted.pem")" < /dev/null
check "an encrypted key fails at once (2)" exited 2
check "saying it must be unencrypted" said "unencrypted RSA private key"
openssl ecparam -name prime256v1 -genkey -noout -out "${CASE}/ec.pem" 2> /dev/null
mkdir -p "${CASE}/ec"
openssl ec -in "${CASE}/ec.pem" -pubout -out "${CASE}/ec/ec-key.rsa.pub" 2> /dev/null
run verify PARAM_DIR=. PARAM_KEYRING="${CASE}/ec"
check "a keyring key that isn't RSA is refused (2)" exited 2

begin "D-3: the AWS CLI's own endpoint settings"
new_case
package x86_64 hello 1.0.0-r0
publish_new AWS_ENDPOINT_URL=http://localhost:7777
check "AWS_ENDPOINT_URL is used when endpoint_url is empty" logged ' http://localhost:7777$'
check "and named in the receipt" json_is "${CASE}/apk-repo-receipt.json" 'r["endpoint_url"]' "http://localhost:7777"
: > "${CASE}/aws.log"
publish_new AWS_ENDPOINT_URL_S3=http://s3.example.com
check "and checked like it: http:// to another host is refused" exited 2
check "before any AWS call" not_logged '.'

begin "O-1: receipt_path"
new_case
repo "${CASE}/repo" x86_64 hello 1.0.0-r0
mkdir -p "${CASE}/receipts"
run verify PARAM_DIR=repo PARAM_RECEIPT_PATH=receipts
check "a directory is refused (2)" exited 2
run verify PARAM_DIR=repo
check "a receipt is readable by others, as the umask allows" [ "$(stat -c %a "${CASE}/apk-repo-receipt.json")" == "644" ]

begin "U-6: a listed package that is missing"
new_case
package x86_64 hello 1.0.0-r0
publish_new
rm "$(s3 test/os/x86_64/hello-1.0.0-r0.apk)"
rm -rf "${CASE}/packages"
package x86_64 hello 1.0.0-r0 "${CASE}/packages" "another build"
run publish
check "fails" failed
check "saying it is missing, not that it differs" said "is missing, though the index lists it"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All command checks passed."
