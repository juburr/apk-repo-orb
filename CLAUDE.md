# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, that publishes and pulls signed APK repositories in S3-compatible buckets: the link between melange-orb (builds APKs) and apko-orb (builds images from them). `publish` re-signs melange's packages with a production key and merges them into the bucket's signed index with S3 conditional writes; `pull` fetches a repository into a local directory apko can use, verifying every byte against the caller's keyring; `verify` checks a local repository offline. It installs nothing: melange comes from melange-orb, and the AWS CLI is on the runners.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh

# Offline tests (bash 4+, python3 3.8+, openssl)
for t in commands wiring actions env_subst shell_conventions; do bash "tests/${t}_test.sh" || break; done

# Run one command's script with its YAML defaults (what CI uses for steps that must fail)
bash tests/run_command.sh verify dir=packages keyring=keys

# Against a real server and real melange (Docker, the AWS CLI, melange)
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test-secret AWS_DEFAULT_REGION=us-east-1
bash tests/s3_server.sh apk-repo-test
APK_REPO_BUCKET=apk-repo-test bash tests/integration_test.sh
bash tests/golden_test.sh
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - `verify`, `pull`, `publish`, one script each in `scripts/`
- `scripts/lib/apk_repo.sh` - Shell helpers shared by the scripts (`ar_*`). Only defines functions and variables; no `set` line.
- `scripts/apk_repo.py` - Python helper (standard library only, Python 3.8+), run as `python3 -I -c "${SCRIPT_APK_REPO_PY}" COMMAND ...`
- `examples/` - Usage examples, pinned to the orb's current version
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below)

### Three run modes

Every script works the same in each (C-4, D-8 in the requirements that started the orb):

- **CircleCI:** the command passes `SCRIPT_APK_REPO_LIB: << include(scripts/lib/apk_repo.sh) >>` and `SCRIPT_APK_REPO_PY: << include(scripts/apk_repo.py) >>`, and its `command:` includes the script.
- **GitHub Actions:** `actions/run_script.sh SCRIPT SCRIPT_APK_REPO_LIB=<file> SCRIPT_APK_REPO_PY=<file>` sets them to the files' contents.
- **Standalone:** `PARAM_X=... bash src/scripts/<cmd>.sh`; a script that finds them unset reads the files beside itself.

The script `eval`s the lib, which runs the Python through `ar_py`. Each script's header lists its `PARAM_*` variables. Scripts start `#!/bin/bash` and `set -euo pipefail`, then refuse bash before 4 (the conventions test wants `set` first).

### Repository format

The README's Repository Format section is the contract. Per architecture: a signed `APKINDEX.tar.gz` (`.SIGN.RSA256.<key_name>.pub`), the only object ever replaced, with `If-Match`; and immutable objects, written once with `If-None-Match: *`: `<P>-<V>.apk`, its `.sha256` (one `sha256sum` line) and `.sha256.<key_name>.sig` (`openssl dgst -sha256 -sign` over the `.sha256` bytes). Nothing is ever deleted. `<prefix>/.apk-repo-orb/probe` holds fixed bytes for the probe.

APK v2 facts the code relies on:
- A package is three gzip members: signature (a tar of `.SIGN.RSA256.<key>.pub` without end-of-archive blocks), control (`.PKGINFO`, also cut) and data. The package signature is PKCS#1 v1.5 over SHA-256 of the compressed control member. apko never checks it.
- An index is a signature member followed by a tar.gz of `APKINDEX` and `DESCRIPTION`; the signature covers every byte after the first member. A record's `C:` is `Q1` + base64(SHA-1 of the compressed control member). Records end with a blank line, and apko drops a final record without one, so verify refuses such an index.
- apko checks the index signature, then `C:`, then the data segment against `.PKGINFO`'s `datahash`; `apk_repo.py apk` checks `datahash` too, so verify and pull catch a changed data segment even with a re-signed sidecar.
- melange names signatures after the key file's basename and reads only PKCS#1 keys (`BEGIN RSA PRIVATE KEY`), so `publish` writes the key to a file named `key_name` and converts it with `openssl rsa -traditional` (plain `openssl rsa` on OpenSSL 1.1).

### `apk_repo.py`

- `index-split FILE WORKDIR`: requires exactly one `.SIGN.RSA256.<key>.rsa.pub` entry, writes `signature` and `signed` (every byte after the signature member, not decompressed) and prints the key's name.
- `index-sign KEY SIGNATURE SIGNED OUT`: writes an index from a signature over SIGNED (made by openssl) and SIGNED itself, with melange's signature member layout.
- `index-entries FILE ARCH WORKDIR`: run only after `signed` verified, so an unsigned file is never decompressed or parsed. Writes `entries.tsv` (`P V A S C digest`, the digest being the SHA-256 of the record's sorted lines). Checks names, versions, `A:`, `S:`, duplicates and the final blank line.
- `apk FILE WORKDIR`: writes `control` and, with one signature, `signature`; prints TSV of `pkgname`, `pkgver`, `arch`, `signatures`, `checksum` (the `C:` the package needs), `control_sha256`, `data_sha256` and `size`.
- `receipt OUT WORKDIR`: writes the JSON receipt from `meta.tsv` and `arch/<arch>/{index.tsv,packages.tsv,published,skipped_identical,attempts}`, atomically.

Archives are read member by member with `zlib.decompressobj(31)` and `tarfile` in memory, with size limits; no archive path is ever written to disk, and sparse entries (which `tarfile` counts as regular, and would read at their full logical size) or entries claiming more bytes than their archive holds are refused. Exit 1 is a refused file (`ERROR:` on stderr), 2 usage. The name, version and key patterns are the lib's (`AR_*_RE`), checked with `fullmatch`; `tests/wiring_test.sh` checks the two agree.

### Shared helpers (`scripts/lib/apk_repo.sh`)

- `ar_die` (exit 1) and `ar_usage` (exit 2) print `ERROR:` lines; `ar_warn`; `ar_subst` (stdin `circleci env subst`, the value as is without the CLI); `ar_bool`, `ar_match` (C locale), `ar_py`.
- `ar_need_tools` and `ar_need_aws`: the AWS CLI must list `IfMatch` and `IfNoneMatch` in `s3api put-object --generate-cli-skeleton` (2.22.5 added `--if-match`; `AR_AWS_MIN_VERSION`).
- Parameters: `ar_arches`, `ar_check_prefix`, `ar_check_bucket`, `ar_check_key_name`, `ar_check_backend`, `ar_check_endpoint` (https, or http to localhost; no credentials, query or fragment), `ar_check_region`.
- Keyring: `ar_keyring` fills `AR_KEYS[<key>.rsa]=path` (scripts `declare -A AR_KEYS=()` first: bash 4.0 has no `declare -g`). Only `*.rsa.pub` PEM public keys.
- Verification: `ar_verify_index FILE ARCH WORKDIR` (`index-split`, the keyring and openssl, then `index-entries`; sets `AR_INDEX_KEY`), `ar_verify_sidecar DIR FILE` (sets `AR_SIDECAR_SHA256`; at least one signature by a keyring key must verify, and others that don't are warned about once each, through `AR_SIG_WARNED`: a stray immutable `.sig` must not break a package for good), `ar_verify_packages DIR ARCH WORKDIR RECEIPT_DIR` (presence, sidecar, SHA-256, size, `C:`, `datahash`; warns about unlisted files).
- `ar_default_arch` (run as `ARCH=$(ar_default_arch ...) || exit $?`: `ar_usage` in a command substitution only ends the subshell) and `ar_arches`, which refuses an empty list, so no command succeeds having checked no architecture. `ar_check_prefix` matches the whole value against one pattern (a newline can't split it). `ar_configured_endpoint` takes `AWS_ENDPOINT_URL_S3`/`AWS_ENDPOINT_URL` when `endpoint_url` is empty, so it is checked and recorded too. `ar_check_receipt_path`. Keyring keys must be RSA (`openssl rsa -pubin`).
- S3: `ar_aws_init`, `ar_get_object KEY OUT` and `ar_put_object KEY FILE TYPE CACHE CONDITION` (sets `AR_ETAG`, `AR_VERSION_ID`; each call has its own `mktemp` error file). `ar_get_objects LIST` runs the `KEY<TAB>OUT<TAB>STATUS` downloads of LIST `AR_PARALLEL` (8) at a time in background subshells, in batches since bash 4.0 has no `wait -n`, writing each status to STATUS (empty: a failure already reported); `ar_require_fetched` and `ar_optional_fetched` then apply the 404/403 rules. Each AWS CLI call costs about half a second, so anything that reads every package of an index goes through it. Failures are classified from the CLI's error code (`ar_aws_status`): `AR_ABSENT` (404, NoSuchKey), `AR_DENIED` (403), `AR_PRECONDITION` (412), `AR_CONFLICT` (409); anything else is fatal. A 403 is never "absent": S3 answers 403 for a missing key without `s3:ListBucket`.
- Receipts: `ar_receipt_meta`, `ar_write_receipt PATH` (also exports `APK_REPO_RECEIPT`).

### `publish.sh`

Validates everything, writes the key (xtrace off, `umask 077`) and checks it matches `<key_name>.pub` in the keyring (U-2), then stages each architecture in `AR_WORK/stage/<arch>`: copies, `inspect` (the `PKG_*` arrays, keyed `<arch>/<file>` by `pkg_key`, since one file name can be staged for each architecture), name and arch checks, `melange sign` (U-4) and `write_sidecars` (U-5). Then, unless `dry_run`, the probe (F-13 to F-16) and `publish_public_key`. Each architecture runs `publish_arch` in a subshell (U-15):

1. Reads and verifies the remote index, or with `allow_create` starts from none (U-8).
2. Splits staged packages into new and already listed; a listed one must be the same bytes or the same control and data segments (`same_package`, through `segments`), or it fails (U-6).
3. Uploads new packages and sidecars with `put_immutable` (`If-None-Match: *`). An existing object at a new package's key (an orphan of an interrupted publish) is adopted by `adopt` only if it is the same package, `resign` is on, and it is signed with `key_name` alone (`signed_by_key`, the U-4 check staging runs too); otherwise the version is immutable and the publish fails. A dry run makes the same check with a GET, without writing (U-7).
4. Runs `melange index [--merge --source remote]` (or, when nothing is new but the index is signed with another key, signs the same bytes with `key_name` through `apk_repo.py index-sign`, so a key rotation completes, S-8), verifies the result is signed with `key_name`, and `check_merge` requires exactly the remote entries, unchanged, plus the new ones with the staged packages' sizes and checksums (U-9). `receipt_shas` then fetches (in parallel) and verifies the sidecar of every listed package not seen yet (kept across attempts), so nothing after the index write can fail.
5. Uploads the index with `If-Match` (or `If-None-Match: *` when creating), and on 412, 409 or 404 backs off (jittered, up to 30 s) and starts again, up to `max_attempts` (U-10).

`publish_arch` runs as `set +e; ( set -e; publish_arch ARCH ); status=$?; set -e`, not `if (publish_arch ...)`, which would turn errexit off inside it. The key is unset from the environment once it is in its file. The receipt is written only if every architecture succeeded.

### `pull.sh`

Refuses a non-empty `out_dir/<arch>` before any download (P-1). Per architecture, reads the index (404: "There is no repository at ..."; 403: the `s3:ListBucket` hint), verifies it, fetches every listed package's sidecar and signatures by keyring keys in parallel (404 for a signature is fine), verifies each sidecar, takes the package from `cache_dir` when its SHA-256 matches the signed sidecar or else downloads it (in parallel too), and verifies the staged copies. Only when every architecture verified does it move them into `out_dir` and fill the cache, through a `mktemp` file renamed into place, so a symbolic link left in a restored cache is replaced rather than written through (a symlinked `cache_dir/<arch>` is left alone with a warning). Never lists the bucket.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Its first step passes the inputs to the orb's script as `PARAM_*` environment variables and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_APK_REPO_LIB=<lib> SCRIPT_APK_REPO_PY=<py>`. Inputs never appear inside a `run:` script. A second step turns the `APK_REPO_RECEIPT` the script exported into the `receipt` output (O-2), with a random delimiter.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. Keep the actions in sync with the command YAML by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number. `tests/actions_test.sh` checks all of this.

### Tests

- `tests/commands_test.sh` (T-1, T-2): every command offline, against `tests/fake_aws.py` (on the `PATH` as `aws`) and `tests/apk_fixtures.py` (as `melange`). Each check names the requirement it covers.
  - `fake_aws.py` keeps the bucket in `FAKE_S3_DIR`, enforces both conditions under a file lock (so the offline race is real), and prints errors as AWS CLI 2.34+ does (exit 254). `FAKE_AWS_RULES` injects 403, 404, 409, 412, 500 or `ignore` per operation and key regex, with an optional count. `FAKE_AWS_IGNORE_CONDITIONS`, `FAKE_AWS_NO_IF_MATCH` (an old CLI) and `FAKE_S3_VERSIONING` change its behavior; `FAKE_AWS_LOG` records each call's operation, key, condition and endpoint.
  - `apk_fixtures.py` builds packages and indexes in melange's format (`keygen`, `build`, `sign`, `index` with `--merge`, `--source` and `--legacy`), so keys and packages are made at test time and nothing private is committed.
- `tests/wiring_test.sh`: the YAML passes every `PARAM_` its script reads and every helper; run steps have names; the README documents every command and action; the lib's and the Python's patterns agree; the Python parses as 3.8; and T-8: no script, workflow or action outside the fixtures runs `aws s3 ` (high-level), `delete-object(s)`, `--delete`, or `put-object` without `--if-match` or `--if-none-match`, and the orb's code calls no s3api operation but `get-object` and `put-object`.
- `tests/golden_test.sh` (T-3): real melange (and Docker) builds `tests/fixtures/melange.yaml`; verify must accept melange build's, melange sign's and melange index's output (with `--merge`), and refuse a change in the index's signed contents, the control segment and the data segment (each changed in its gzip header, so only hashes and signatures can tell).
- `tests/s3_server.sh BUCKET` (T-4): starts versitygw v1.10.0 by digest on `127.0.0.1:7070` (falling back to its sidecar metadata mode when the filesystem has no xattrs), creates the bucket, and proves F-14 and F-15 give 412 before anything else runs.
- `tests/integration_test.sh` (T-4, T-5, T-7): the commands, through `tests/run_command.sh`, with the real AWS CLI and melange against that server, then `RACE_ROUNDS` (default 20) rounds of two concurrent publishes, each followed by a pull and verify. An empty `APK_REPO_ENDPOINT` runs it against Amazon S3, and `APK_REPO_PREFIX` puts every scenario's prefix under one of the run's own.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-commands` (the offline command and wiring tests, on `cimg/base:current` and `cimg/python:3.8`), `test-env-subst` (env subst and shell conventions), `test-actions`, orb-tools lint, pack and review (`orb_name: apk-repo`), shellcheck.
- `.circleci/test-deploy.yml` - `golden-test` and `integration-test`, each with melange 0.61.2 and 0.63.1 on an amd64 machine; `end-to-end-test` on `medium` and `arm.medium` machines (T-6): melange-orb builds the fixture package, `apk-repo-orb/publish` uploads it to versitygw, `pull` and `verify` fetch and check it, apko-orb builds `tests/fixtures/apko.yaml` from the pulled directory, and the image must print the package's message. `aws-s3-test` (T-7) runs the integration tests (10 race rounds) and the same pipeline against Amazon S3, with the `s3_apk_test_rw` context's IAM user and `AWS_S3_BUCKET_NAME`, under `apk-repo-orb-ci/<workflow>-<job>/`, which a lifecycle rule on the bucket expires; without the bucket's name it halts and passes. It runs on every branch, not only `main` and tags as T-7 suggested, so a pull request shows how its change behaves on Amazon S3. The pipeline's steps are shared commands (`make-test-package`, `check-publish-receipt`, `run-test-image`). Publishing runs on `v*` tags and needs every test job.
- `.github/workflows/actions.yml` - The same on GitHub's runners: `offline-tests`, `golden` (both melange versions), `integration` and `end-to-end` on `ubuntu-24.04` and `ubuntu-24.04-arm`, the latter through `./actions/*` and checking the `receipt` outputs.

melange-orb (1.2.0) and apko-orb (1.1.0) are pinned in both: orb versions in `test-deploy.yml`, commit SHAs with version comments in the workflow.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit; copied from melange-orb, whose trailing blank line yamllint warns about). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `ar_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `publish.sh` runs `set +o xtrace` before reading the signing key.
- Under `-u`, use `${VAR:-}` for variables that may be unset. The scripts read `PARAM_*` with the commands' defaults, so a standalone run needs only the required ones.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, so copy `"$@"` into an array only when `$#` is non-zero. `tests/commands_test.sh` passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself. Exit 2 is a usage error, 1 any other failure.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_APK_REPO_LIB}"`). Secrets never go on a command line: the signing key reaches `melange` and `openssl` only as a file in a 0700 directory.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).

## Naming

Command names say what they do (`verify`, `pull`, `publish`). Parameters take the names of the repository's parts (`bucket`, `prefix`, `arch`, `keyring`, `key_name`) or of the S3 and AWS CLI settings they map onto (`endpoint_url`, `region`, `s3_checksums`), and the orb is invoked as `apk-repo` in examples. Plumbing matches the other juburr orbs: credentials are `env_var_name` parameters (`signing_key`); AWS credentials are never parameters, only the CLI's standard chain.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh` and `yamllint .`
- Run the offline tests, also with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`
- For changes to `publish` or `pull`, also run `tests/integration_test.sh` against `tests/s3_server.sh`, and for changes to parsing or verification, `tests/golden_test.sh` with real melange
