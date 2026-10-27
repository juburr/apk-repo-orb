#!/usr/bin/env bash
#
# Starts a local S3-compatible server for the integration and end-to-end
# tests (T-4): versitygw, pinned by digest, which enforces If-None-Match and
# If-Match on PutObject atomically per key. It listens on 127.0.0.1:7070.
# Then it creates BUCKET and, before any test relies on it, proves that the
# server answers 412 to a write with If-None-Match: * on an existing key
# (F-14) and with If-Match on another ETag (F-15).
#
# Usage:
#   bash tests/s3_server.sh BUCKET
#
# Needs docker and the AWS CLI v2, with AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY set: the server takes them as its root credentials.
# They are test credentials, never real ones.

set -euo pipefail

IMAGE="ghcr.io/versity/versitygw:v1.10.0@sha256:89cad13cc981986ee284cbafea4613f9533ce6fd5f37a2c96c4c4fb8adb3a316"
NAME=apk-repo-s3
ENDPOINT=http://localhost:7070

if [[ $# -ne 1 ]]; then
    echo "ERROR: Usage: bash tests/s3_server.sh BUCKET" >&2
    exit 2
fi
BUCKET=$1
: "${AWS_ACCESS_KEY_ID:?ERROR: set AWS_ACCESS_KEY_ID, the access key the test server is to accept}"
: "${AWS_SECRET_ACCESS_KEY:?ERROR: set AWS_SECRET_ACCESS_KEY, the secret key the test server is to accept}"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# start [DOCKER_OPTION...]: (re)starts the server. The credentials reach
# docker through its environment, not its command line.
start() {
    docker rm -f "${NAME}" > /dev/null 2>&1 || true
    ROOT_ACCESS_KEY="${AWS_ACCESS_KEY_ID}" ROOT_SECRET_KEY="${AWS_SECRET_ACCESS_KEY}" \
        docker run -d --name "${NAME}" -p 127.0.0.1:7070:7070 \
        -e ROOT_ACCESS_KEY -e ROOT_SECRET_KEY \
        -e VGW_BACKEND=posix -e VGW_BACKEND_ARG=/tmp/vgw -e VGW_HEALTH=/health \
        "$@" "${IMAGE}" > /dev/null
}

# healthy: waits up to a minute for /health, while the container runs.
healthy() {
    local attempt
    for attempt in $(seq 60); do
        if curl -fsS -o /dev/null http://127.0.0.1:7070/health 2> /dev/null; then
            echo "versitygw is up after ${attempt} attempt(s)."
            return 0
        fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "${NAME}" 2> /dev/null)" != "true" ]]; then
            return 1
        fi
        sleep 1
    done
    return 1
}

echo "Starting ${IMAGE}"
start
if ! healthy; then
    # The posix backend keeps ETags in extended attributes, and refuses to
    # start on a filesystem without them; its sidecar mode keeps them in
    # files instead.
    if docker logs "${NAME}" 2>&1 | grep -qi 'xattr'; then
        echo "The container's filesystem has no extended attributes; keeping metadata in a sidecar directory."
        start -e VGW_META_SIDECAR=/tmp/vgw-meta --tmpfs /tmp/vgw-meta
    fi
    if ! healthy; then
        docker logs "${NAME}" >&2 || true
        echo "ERROR: versitygw didn't become healthy." >&2
        exit 1
    fi
fi

aws s3api create-bucket --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" > /dev/null
echo "Created the bucket ${BUCKET}."

# expect_412 DESCRIPTION COMMAND...: COMMAND must fail with PreconditionFailed.
expect_412() {
    local description=$1
    shift
    if "$@" > "${WORK}/out" 2> "${WORK}/err"; then
        echo "ERROR: ${description} succeeded; the server doesn't enforce conditional writes." >&2
        exit 1
    fi
    if ! grep -q '(PreconditionFailed)' "${WORK}/err"; then
        cat "${WORK}/err" >&2
        echo "ERROR: ${description} failed, but not with 412 PreconditionFailed." >&2
        exit 1
    fi
    echo "ok: ${description} is refused with 412 PreconditionFailed."
}

KEY=t4/conditional-write-check
printf 'first\n' > "${WORK}/first"
printf 'second\n' > "${WORK}/second"
etag=$(aws s3api put-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "${KEY}" \
    --body "${WORK}/first" --if-none-match "*" --query ETag --output text)
expect_412 "F-14: If-None-Match: * on an existing key" \
    aws s3api put-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "${KEY}" \
    --body "${WORK}/second" --if-none-match "*"
expect_412 "F-15: If-Match with another ETag" \
    aws s3api put-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "${KEY}" \
    --body "${WORK}/second" --if-match '"00000000000000000000000000000000"'
aws s3api put-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "${KEY}" \
    --body "${WORK}/second" --if-match "${etag}" > /dev/null
aws s3api get-object --endpoint-url "${ENDPOINT}" --bucket "${BUCKET}" --key "${KEY}" "${WORK}/read" > /dev/null
if ! cmp -s "${WORK}/read" "${WORK}/second"; then
    echo "ERROR: the write with the current ETag (If-Match) didn't replace the object." >&2
    exit 1
fi
echo "ok: If-Match with the current ETag replaces the object."
echo "The server enforces conditional writes; ${ENDPOINT} is ready."
