#!/usr/bin/env bash
#
# Checks how the command YAML and the scripts fit together, offline:
#
#   - every PARAM_ variable a script reads is set by its command, from the
#     parameter of the same name, and every parameter a command declares is
#     passed on to its script;
#   - every command passes the shared helpers its script reads
#     (SCRIPT_APK_REPO_LIB, SCRIPT_APK_REPO_PY);
#   - every run step has a name, as orb-tools review's RC008 asks;
#   - the README documents every command and names its GitHub Action;
#   - the name, version and key name patterns are the same in the shell
#     library and the Python helper, which both check them;
#   - the Python helper parses as Python 3.8, the oldest it supports;
#   - T-8: no script, workflow or action outside the test fixtures runs a
#     high-level `aws s3` command, deletes anything, or writes with
#     put-object without --if-match or --if-none-match (U-12), and the
#     orb's own code calls no s3api operation but get-object and put-object;
#   - tests/run_command.sh runs each command's own script.
#
# Run from a checkout:
#   bash tests/wiring_test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"
FAILURES=0
fail() {
    printf 'FAIL: %s\n' "$*"
    FAILURES=$((FAILURES + 1))
}

# param_vars SCRIPT: the PARAM_ variables SCRIPT reads.
param_vars() {
    grep -oE '\$\{PARAM_[A-Z0-9_]+' "$1" | sed 's/^\${//' || true
}

# unnamed_runs FILE: "<line>: <problem>" for each run step in FILE without a
# name: a "- run:" mapping whose own keys have no name, or an empty one, and
# a "- run: <command>" string, which can't have one.
unnamed_runs() {
    awk '
        function close_step() {
            if (open && !named) { print start ": this run step has no name" }
            open = 0
        }
        {
            match($0, /^ */)
            indent = RLENGTH
            if (open && NF && indent <= dash) { close_step() }
            if ($0 ~ /^ *- run:/) {
                close_step()
                dash = indent
                rest = $0
                sub(/^ *- run:[ ]*/, "", rest)
                if (rest != "") { print FNR ": this run step is a string, which has no name" }
                else { open = 1; named = 0; keys = -1; start = FNR }
                next
            }
            if (open && NF) {
                if (keys < 0) { keys = indent }
                if (indent == keys && $0 ~ /^ *name:/) {
                    value = $0
                    sub(/^ *name:[ ]*/, "", value)
                    gsub(/["\047 ]/, "", value)
                    if (value != "") { named = 1 }
                }
            }
        }
        END { close_step() }
    ' "$1"
}

# params FILE: the parameters a command declares.
params() {
    awk '/^parameters:/ { p = 1; next } /^[^ ]/ { p = 0 } p && /^  [a-z_0-9]+:$/ { sub(/:$/, ""); print $1 }' "$1"
}

for yml in src/commands/*.yml; do
    command=${yml##*/}
    command=${command%.yml}
    mapfile -t declared < <(params "${yml}")
    mapfile -t scripts < <(grep -oE 'command: << include\(scripts/[^)]+\.sh\) >>' "${yml}" \
        | sed -E 's/command: << include\(([^)]+)\) >>/\1/' | sort -u)
    if [[ "${#scripts[@]}" -eq 0 ]]; then
        fail "${command}: no run step includes a script"
    fi
    passed=$(grep -oE 'PARAM_[A-Z0-9_]+: << parameters\.[a-z0-9_]+ >>' "${yml}" || true)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        var=${line%%:*}
        name=${line##*parameters.}
        name=${name% >>}
        if [[ "${var}" != "PARAM_${name^^}" ]]; then
            fail "${command}: ${var} is set from parameters.${name}"
        fi
    done <<< "${passed}"
    for script in ${scripts[@]+"${scripts[@]}"}; do
        mapfile -t read_vars < <(param_vars "src/${script}" | sort -u)
        for var in ${read_vars[@]+"${read_vars[@]}"}; do
            if ! grep -qE "^ +${var}: << parameters\.[a-z0-9_]+ >>$" "${yml}"; then
                fail "${command}: src/${script} reads ${var}, which ${command}.yml doesn't set"
            fi
        done
        if grep -q 'SCRIPT_APK_REPO_LIB' "src/${script}" \
            && ! grep -q 'SCRIPT_APK_REPO_LIB: << include(scripts/lib/apk_repo.sh) >>' "${yml}"; then
            fail "${command}: src/${script} needs SCRIPT_APK_REPO_LIB, which ${command}.yml doesn't pass"
        fi
        if grep -q 'SCRIPT_APK_REPO_PY' "src/${script}" \
            && ! grep -q 'SCRIPT_APK_REPO_PY: << include(scripts/apk_repo.py) >>' "${yml}"; then
            fail "${command}: src/${script} needs SCRIPT_APK_REPO_PY, which ${command}.yml doesn't pass"
        fi
    done
    for name in ${declared[@]+"${declared[@]}"}; do
        if ! grep -qE "<< parameters\.${name} >>" "${yml}"; then
            fail "${command}: the parameter ${name} is never used"
        fi
    done
    if ! grep -q "### \`apk-repo/${command}\`" README.md 2> /dev/null; then
        fail "${command}: the README has no section for it"
    fi
    if ! grep -q "juburr/apk-repo-orb/actions/${command}@" README.md 2> /dev/null; then
        fail "${command}: the README doesn't name its GitHub Action, juburr/apk-repo-orb/actions/${command}"
    fi
    while IFS= read -r problem; do
        [[ -n "${problem}" ]] && fail "${yml}:${problem}"
    done < <(unnamed_runs "${yml}")
done

# The patterns both languages check names, versions and key names with.
for pattern in NAME VERSION KEY; do
    shell=$(sed -nE "s/^AR_${pattern}_RE='(.*)'$/\\1/p" src/scripts/lib/apk_repo.sh)
    python=$(sed -nE "s/^${pattern}_RE = re\\.compile\\(r\"(.*)\"\\)$/\\1/p" src/scripts/apk_repo.py)
    if [[ -z "${shell}" || "${shell}" != "${python}" ]]; then
        fail "AR_${pattern}_RE in lib/apk_repo.sh is '${shell}', but ${pattern}_RE in apk_repo.py is '${python}'"
    fi
done

# The oldest Python the helper supports.
if ! python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 8))' src/scripts/apk_repo.py 2> /dev/null; then
    fail "src/scripts/apk_repo.py doesn't parse as Python 3.8"
fi

# t8_problems [ORB_CODE] FILE...: "<file>:<line>: <problem>" for each command
# line (continuation lines joined, comments skipped) that T-8 forbids. With
# ORB_CODE 1, s3api operations other than get-object and put-object are
# refused too.
t8_problems() {
    local orb_code=$1
    shift
    awk -v orb_code="${orb_code}" '
        function check(text, file, line,   op) {
            if (text ~ /^[ \t]*#/) { return }
            if (text ~ /aws s3 /) { print file ":" line ": a high-level aws s3 command" }
            if (text ~ /delete-object/) { print file ":" line ": delete-object(s)" }
            if (text ~ /--delete/) { print file ":" line ": --delete" }
            if (text ~ /put-object/ && text !~ /--if-match|--if-none-match|--generate-cli-skeleton/) {
                print file ":" line ": put-object without --if-match or --if-none-match"
            }
            if (orb_code == 1) {
                op = text
                while (match(op, /s3api [a-z0-9-]+/)) {
                    if (substr(op, RSTART + 6, RLENGTH - 6) !~ /^(get-object|put-object)$/) {
                        print file ":" line ": s3api " substr(op, RSTART + 6, RLENGTH - 6)
                    }
                    op = substr(op, RSTART + RLENGTH)
                }
            }
        }
        FNR == 1 { if (joined != "") { check(joined, last_file, start) } joined = "" }
        {
            last_file = FILENAME
            if (joined == "") { start = FNR }
            text = $0
            if (text ~ /\\$/) { joined = joined substr(text, 1, length(text) - 1); next }
            check(joined text, FILENAME, start)
            joined = ""
        }
        END { if (joined != "") { check(joined, last_file, start) } }
    ' "$@"
}

# The check finds what it must.
SAMPLE=$(mktemp)
trap 'rm -f "${SAMPLE}"' EXIT
cat > "${SAMPLE}" << 'EOF'
# aws s3 sync in a comment is fine
aws s3 cp a s3://b/c
aws s3api delete-objects --bucket b --delete file://d
aws s3api put-object --bucket b \
    --key k --body f
aws s3api put-object --bucket b --key k --body f --if-none-match "*"
aws s3api list-objects-v2 --bucket b
EOF
expected="${SAMPLE}:2: a high-level aws s3 command
${SAMPLE}:3: delete-object(s)
${SAMPLE}:3: --delete
${SAMPLE}:3: s3api delete-objects
${SAMPLE}:4: put-object without --if-match or --if-none-match
${SAMPLE}:7: s3api list-objects-v2"
if [[ "$(t8_problems 1 "${SAMPLE}")" != "${expected}" ]]; then
    fail "T-8's check doesn't find what it must in a sample:"$'\n'"$(t8_problems 1 "${SAMPLE}")"
fi

# T-8 on the orb's code, its actions, its CI and its test scripts (the test
# fixtures, fake_aws.py and apk_fixtures.py, are left out, and so is this
# file, which names what it looks for).
mapfile -t orb_files < <(find src actions -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yml' \) | sort)
mapfile -t ci_files < <(find .circleci .github tests -type f \( -name '*.sh' -o -name '*.yml' \) ! -path tests/wiring_test.sh 2> /dev/null | sort)
while IFS= read -r problem; do
    [[ -n "${problem}" ]] && fail "T-8: ${problem}"
done < <(t8_problems 1 "${orb_files[@]}"; [[ "${#ci_files[@]}" -eq 0 ]] || t8_problems 0 "${ci_files[@]}")
if ! grep -q 'put-object .*--if-none-match' src/scripts/lib/apk_repo.sh || ! grep -q 'put-object .*--if-match' src/scripts/lib/apk_repo.sh; then
    fail "T-8: lib/apk_repo.sh no longer writes with put-object --if-none-match and --if-match"
fi

# tests/run_command.sh, which test-deploy.yml runs the steps that must fail
# with, picks each command's own script. --name-only stops before running it.
for yml in src/commands/*.yml; do
    command=${yml##*/}
    command=${command%.yml}
    running=$(bash tests/run_command.sh --name-only "${command}" 2> /dev/null || true)
    if [[ "${running}" != "scripts/${command}.sh" ]]; then
        fail "run_command.sh ${command} doesn't run scripts/${command}.sh: ${running:-it printed nothing}"
    fi
done

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "ok: every command passes every parameter and helper its script reads, names its run steps and has a README section; the lib and the Python helper agree; no write is unconditional and nothing is deleted (T-8)"
