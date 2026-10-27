#!/usr/bin/env bash
#
# Golden tests with real melange (T-3). It builds tests/fixtures/melange.yaml
# for the machine's architecture with melange's docker runner, then checks
# that verify accepts what melange writes:
#
#   - the package and index melange build signed (V-4: the index signature's
#     padding and digest input, the index's C: and S: for the package);
#   - the package re-signed with melange sign and indexed again with
#     melange index, as publish runs them, and a second package merged into
#     that index with --merge --source (U-4, U-9);
#
# and that it rejects a one-byte change in each signed segment: the index's
# signed contents, the package's control segment (covered by C:) and its
# data segment (covered by the datahash in .PKGINFO). The byte changed is in
# the segment's gzip header (its MTIME), so the segment still decompresses
# and only the hashes and signatures can tell. Each package gets a SHA-256
# sidecar signed for its changed bytes too, so the sidecar isn't what
# catches it. Keys are made at test time; nothing private is committed.
#
# Needs melange (0.61.2 or newer), docker, python3 and openssl. Run from a
# checkout:
#   bash tests/golden_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
ARCH=$(uname -m)
FAILURES=0
OUTPUT=""
RC=0

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
refused() { [[ "${RC}" -eq 1 ]] && grep -q '^ERROR: ' <<< "${OUTPUT}"; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
receipt_is() {
    local got
    got=$(python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "${WORK}/receipt.json" "$1" 2>&1)
    [[ "${got}" == "$2" ]] || { OUTPUT+=$'\n'"receipt: $1 is ${got}, not $2"; return 1; }
}

# verify DIR KEYRING: runs the orb's verify on DIR/ARCH. Sets RC and OUTPUT.
verify() {
    RC=0
    OUTPUT=$(cd "${WORK}" && bash "${ROOT}/tests/run_command.sh" verify dir="$1" arch="${ARCH}" keyring="$2" \
        receipt_path="${WORK}/receipt.json" 2>&1) || RC=$?
}

# sidecars DIR KEY: a SHA-256 sidecar for each package in DIR, signed with
# KEY, as publish writes them.
sidecars() {
    local dir=$1 key=$2 file
    rm -f "${dir}"/*.sha256 "${dir}"/*.sig
    for file in "${dir}"/*.apk; do
        file=$(basename "${file}")
        (cd "${dir}" && sha256sum "${file}" > "${file}.sha256" \
            && openssl dgst -sha256 -sign "${key}" -out "${file}.sha256.$(basename "${key}").sig" "${file}.sha256") \
            || { echo "ERROR: couldn't sign ${dir}/${file}.sha256" >&2; exit 1; }
    done
}

# tamper FILE MEMBER: flips a bit of the MTIME in the gzip header of FILE's
# member MEMBER (0 is the first).
tamper() {
    python3 -I - "$1" "$2" << 'EOF'
import sys, zlib
path, member = sys.argv[1], int(sys.argv[2])
data = bytearray(open(path, "rb").read())
offsets, position = [0], 0
while True:
    inflate = zlib.decompressobj(31)
    inflate.decompress(bytes(data[position:]))
    if not inflate.eof or not inflate.unused_data:
        break
    position = len(data) - len(inflate.unused_data)
    offsets.append(position)
data[offsets[member] + 4] ^= 1
open(path, "wb").write(bytes(data))
EOF
}

# run_melange ARGS...: runs melange, showing its output only when it fails.
run_melange() {
    if ! (cd "${WORK}" && melange "$@") > "${WORK}/melange.log" 2>&1; then
        cat "${WORK}/melange.log"
        echo "ERROR: melange $1 failed." >&2
        exit 1
    fi
}

melange version 2>&1 | grep -i 'gitversion' || melange version
cd "${WORK}" || exit 1
run_melange keygen build.rsa
run_melange keygen production.rsa
mkdir -p build-keyring production-keyring
cp build.rsa.pub build-keyring/
cp production.rsa.pub production-keyring/

echo "--- T-3: what melange build writes"
run_melange build "${ROOT}/tests/fixtures/melange.yaml" --runner docker --arch "${ARCH}" \
    --signing-key build.rsa --out-dir built
PACKAGE=apk-repo-hello-0.0.1-r0.apk
sidecars "built/${ARCH}" "${WORK}/build.rsa"
verify built build-keyring
check "V-4: verify accepts melange build's index and package" succeeded
check "signed with the build key" receipt_is 'r["architectures"]["'"${ARCH}"'"]["index"]["signature"]' ".SIGN.RSA256.build.rsa.pub"
check "listing the package" receipt_is '[p["file"] for p in r["architectures"]["'"${ARCH}"'"]["packages"]]' "['${PACKAGE}']"
verify built production-keyring
check "and refuses it with another keyring" refused

echo "--- U-4, U-9: melange sign and melange index, as publish runs them"
mkdir -p "resigned/${ARCH}"
cp "built/${ARCH}/${PACKAGE}" "resigned/${ARCH}/"
run_melange sign --signing-key production.rsa "resigned/${ARCH}/${PACKAGE}"
OUTPUT=$(python3 -I "${ROOT}/src/scripts/apk_repo.py" apk "resigned/${ARCH}/${PACKAGE}" "$(mktemp -d -p "${WORK}")" 2>&1)
check "U-4: melange sign leaves the production key's signature alone in the package" said $'signatures\t.SIGN.RSA256.production.rsa.pub'
run_melange index --output "resigned/${ARCH}/APKINDEX.tar.gz" --signing-key production.rsa "resigned/${ARCH}/${PACKAGE}"
sidecars "resigned/${ARCH}" "${WORK}/production.rsa"
verify resigned production-keyring
check "verify accepts the re-signed package and melange index's index" succeeded
mkdir -p "merged/${ARCH}"
cp "resigned/${ARCH}/${PACKAGE}" "merged/${ARCH}/"
python3 -I "${ROOT}/tests/apk_fixtures.py" build "merged/${ARCH}/second-1.0-r0.apk" second 1.0-r0 "${ARCH}" --key build.rsa
run_melange sign --signing-key production.rsa "merged/${ARCH}/second-1.0-r0.apk"
run_melange index --output "merged/${ARCH}/APKINDEX.tar.gz" --merge --source "resigned/${ARCH}/APKINDEX.tar.gz" \
    --signing-key production.rsa "merged/${ARCH}/second-1.0-r0.apk"
sidecars "merged/${ARCH}" "${WORK}/production.rsa"
verify merged production-keyring
check "U-9: melange index --merge --source keeps the source's entries" succeeded
check "and adds the new package" receipt_is 'sorted(p["file"] for p in r["architectures"]["'"${ARCH}"'"]["packages"])' "['${PACKAGE}', 'second-1.0-r0.apk']"

echo "--- T-3: a one-byte change in each signed segment"
for case in index-contents control data; do
    rm -rf tampered && cp -r built tampered
    case "${case}" in
        index-contents) tamper "tampered/${ARCH}/APKINDEX.tar.gz" 1 ;;
        control) tamper "tampered/${ARCH}/${PACKAGE}" 1 ;;
        data) tamper "tampered/${ARCH}/${PACKAGE}" 2 ;;
    esac
    sidecars "tampered/${ARCH}" "${WORK}/build.rsa"
    verify tampered build-keyring
    check "a changed byte in the ${case} segment is refused" refused
    case "${case}" in
        index-contents) check "by the index's signature" said "signature doesn't verify" ;;
        control) check "by the index's checksum (C:)" said "control segment doesn't match the index's checksum" ;;
        data) check "by the datahash in .PKGINFO" said "doesn't match the datahash in its .PKGINFO" ;;
    esac
done

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All golden checks passed with $(melange version 2>&1 | grep -oiE 'v?[0-9]+\.[0-9]+\.[0-9]+' | awk 'NR == 1')."
