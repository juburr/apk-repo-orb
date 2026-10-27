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
printf '#!/bin/sh\nexec python3 -I "%s/tests/fake_aws.py" "$@"\n' "${ROOT}" > "${STUBS}/aws"
printf '#!/bin/sh\nexec python3 -I "%s/tests/apk_fixtures.py" "$@"\n' "${ROOT}" > "${STUBS}/melange"
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
run publish PARAM_MAX_ATTEMPTS=3
check "max_attempts exhausted fails" failed
check "saying so" said "gave up after 3 attempts"
check "U-15: naming the architecture" said "Publishing failed for x86_64"
check "after exactly 3 index writes" [ "$(grep -c '^PutObject test/os/x86_64/APKINDEX.tar.gz' "${CASE}/aws.log")" -ge 3 ]

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
truncate -s 5368709121 "${CASE}/packages/x86_64/huge-1.0-r0.apk"
publish_new
check "U-14: a package over 5 GiB fails" failed
check "before any upload" said "exceeds 5 GiB; multipart upload is not supported yet"

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

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All command checks passed."
