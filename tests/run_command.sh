#!/usr/bin/env bash
#
# Runs a command's script the way the command's step runs it: with every
# PARAM_ variable set from the command's parameter defaults, overridden by
# NAME=VALUE arguments, and SCRIPT_APK_REPO_LIB and SCRIPT_APK_REPO_PY set to
# the shared helpers. test-deploy.yml uses it to check steps that must fail,
# since a failing orb step would fail the test job itself. It runs in the
# current directory, as the step does.
#
# Usage, from a checkout:
#   bash tests/run_command.sh [--name-only] COMMAND [NAME=VALUE ...]
#
# Exits with the script's exit code. --name-only prints the script the
# command runs, and runs nothing.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAME_ONLY=false
if [[ "${1:-}" == "--name-only" ]]; then
    NAME_ONLY=true
    shift
fi
if [[ $# -lt 1 ]]; then
    echo "ERROR: Usage: bash tests/run_command.sh [--name-only] COMMAND [NAME=VALUE ...]" >&2
    exit 2
fi
COMMAND=$1
shift
YML="${ROOT}/src/commands/${COMMAND}.yml"
if [[ ! -f "${YML}" ]]; then
    echo "ERROR: There is no command ${COMMAND} (${YML})." >&2
    exit 2
fi
SCRIPT=$(grep -oE '^ +command: << include\(scripts/[a-z_]+\.sh\) >>$' "${YML}" \
    | sed -E 's/^ +command: << include\((.*)\) >>$/\1/' | tail -n 1 || true)
if [[ -z "${SCRIPT}" ]]; then
    echo "ERROR: ${COMMAND}.yml has no run step that includes a script." >&2
    exit 2
fi
if [[ "${NAME_ONLY}" == "true" ]]; then
    echo "${SCRIPT}"
    exit 0
fi

# Every parameter, as NAME<TAB>DEFAULT, without the quotes YAML allows; a
# parameter without a default has the value "<required>" until it is given.
declare -A VALUES=()
while IFS=$'\t' read -r name value; do
    VALUES[${name}]=${value}
done < <(awk '
    function flush() { if (name != "") { printf "%s\t%s\n", name, value } }
    /^parameters:/ { p = 1; next }
    /^[^ ]/ { if (p) { flush() } p = 0; name = "" }
    p && /^  [a-z_0-9]+:$/ { flush(); name = $1; sub(/:$/, "", name); value = "<required>" }
    p && /^    default:/ {
        value = $0
        sub(/^    default: */, "", value)
        if (value ~ /^".*"$/) { value = substr(value, 2, length(value) - 2) }
    }' "${YML}")
# Bash 4.0 takes an empty "$@" for an unbound variable.
SETTINGS=()
if [[ $# -gt 0 ]]; then
    SETTINGS=("$@")
fi
for setting in ${SETTINGS[@]+"${SETTINGS[@]}"}; do
    name=${setting%%=*}
    if [[ "${setting}" != *=* || -z "${VALUES[${name}]+set}" ]]; then
        echo "ERROR: ${COMMAND} has no parameter ${name}." >&2
        exit 2
    fi
    VALUES[${name}]=${setting#*=}
done
for name in "${!VALUES[@]}"; do
    if [[ "${VALUES[${name}]}" == "<required>" ]]; then
        echo "ERROR: ${COMMAND} needs ${name}=VALUE." >&2
        exit 2
    fi
done

ENVIRONMENT=()
while IFS= read -r line; do
    var=${line%%:*}
    name=${line##*parameters.}
    name=${name% >>}
    ENVIRONMENT+=("${var}=${VALUES[${name}]}")
done < <(grep -oE 'PARAM_[A-Z0-9_]+: << parameters\.[a-z0-9_]+ >>' "${YML}")

echo "Running ${SCRIPT} with ${ENVIRONMENT[*]-}"
STATUS=0
env ${ENVIRONMENT[@]+"${ENVIRONMENT[@]}"} \
    SCRIPT_APK_REPO_LIB="$(cat "${ROOT}/src/scripts/lib/apk_repo.sh")" \
    SCRIPT_APK_REPO_PY="$(cat "${ROOT}/src/scripts/apk_repo.py")" \
    bash "${ROOT}/src/${SCRIPT}" || STATUS=$?
echo "${SCRIPT} exited with ${STATUS}."
exit "${STATUS}"
