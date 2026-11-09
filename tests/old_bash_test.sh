#!/usr/bin/env bash
#
# Runs the offline command tests (tests/commands_test.sh) with old versions
# of bash first on the PATH: the orb supports bash 4.0 and newer, and bash
# before 4.4 treats an empty array as unset under set -u, among other
# differences (see Shell conventions in CLAUDE.md). Each version runs in the
# official bash image, pinned by digest, with the tools the tests need added
# from Alpine's packages. Before the tests, it checks that `bash` on the
# PATH is that version, so a wrong image can't pass for the right one.
#
# Usage, from a checkout, with Docker:
#   bash tests/old_bash_test.sh            (every version below)
#   bash tests/old_bash_test.sh 4.0        (one of them)

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The bash versions the orb promises to support below 4.4, and their images.
declare -A IMAGES=(
    [4.0]="bash:4.0@sha256:df53a43bc02dd7d2d9f3dbd024588a7451e6ef2065718b306001f73beaa899a5"
    [4.3]="bash:4.3@sha256:2cae1250903ee0e41d7c0bdf327bd084509a988e881699c8771733ea177435b7"
)
# What the tests use besides bash: GNU coreutils (stat -c, dd status=none,
# truncate, sha256sum), findutils, grep, sed, gawk, diffutils (cmp),
# python3 and the openssl CLI.
PACKAGES="python3 openssl coreutils findutils grep sed gawk diffutils"

# Bash 4.0 takes an empty "$@" for an unbound variable.
versions=(4.0 4.3)
if [[ $# -gt 0 ]]; then
    versions=("$@")
fi
for version in "${versions[@]}"; do
    if [[ -z "${IMAGES[${version}]:-}" ]]; then
        echo "ERROR: there is no image for bash ${version}; choose from ${!IMAGES[*]}." >&2
        exit 2
    fi
done

for version in "${versions[@]}"; do
    echo "=== bash ${version} (${IMAGES[${version}]})"
    # The checkout is mounted read-write, as the tests run from it; they
    # write only to temporary directories.
    docker run --rm -v "${ROOT}:/src" -w /src -e EXPECTED="${version}" -e PACKAGES="${PACKAGES}" \
        "${IMAGES[${version}]}" sh -euc '
            apk add --no-cache ${PACKAGES} > /dev/null
            found=$(bash -c "echo \${BASH_VERSINFO[0]}.\${BASH_VERSINFO[1]}")
            if [ "${found}" != "${EXPECTED}" ]; then
                echo "ERROR: bash on the PATH is ${found}, not ${EXPECTED}." >&2
                exit 1
            fi
            bash --version | head -n 1
            bash tests/commands_test.sh'
done
echo "The offline command tests pass with bash ${versions[*]}."
