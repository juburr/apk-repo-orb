#!/usr/bin/env python3
"""A stand-in for the AWS CLI's s3api get-object and put-object, for tests.

Objects live in $FAKE_S3_DIR/<bucket>/<key>, and their ETags (the MD5,
quoted, as S3's) in $FAKE_S3_DIR/.meta. Conditional writes are checked and
made under a lock, as S3 makes them, so concurrent publishes race for
real. Errors are printed as AWS CLI 2.34+ prints them, with exit code 254.

  FAKE_S3_DIR               where the buckets are (required)
  FAKE_AWS_LOG              a file to append one line per call to
  FAKE_AWS_RULES            a file of rules, one per line:
                              OPERATION KEY_REGEX STATUS [COUNT]
                            OPERATION is GetObject or PutObject; STATUS is
                            403, 404, 409, 412 or 500, or ignore (make the
                            write, ignoring its condition). A rule with a
                            COUNT applies that many times.
  FAKE_AWS_IGNORE_CONDITIONS=1
                            a backend that ignores If-Match and If-None-Match
  FAKE_AWS_NO_IF_MATCH=1    an old CLI, whose put-object can't take --if-match
  FAKE_S3_VERSIONING=1      a versioned bucket: writes return a VersionId
"""

import base64
import fcntl
import hashlib
import json
import os
import re
import sys

ERRORS = {
    "403": ("AccessDenied", "Access Denied"),
    "404": ("NoSuchKey", "The specified key does not exist."),
    "409": ("ConditionalRequestConflict",
            "The conditional request cannot succeed due to a conflicting operation against this resource."),
    "412": ("PreconditionFailed", "At least one of the pre-conditions you specified did not hold"),
    "500": ("InternalError", "We encountered an internal error. Please try again."),
}


def fail(operation, code, message):
    sys.stderr.write("\naws: [ERROR]: An error occurred (%s) when calling the %s operation: %s\n"
                     % (code, operation, message))
    sys.exit(254)


def error(operation, status):
    code, message = ERRORS[status]
    fail(operation, code, message)


def parse(argv):
    options = {}
    positional = []
    flags = {"--generate-cli-skeleton", "--no-cli-pager", "--debug"}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in flags:
            options[arg] = True
            i += 1
        elif arg.startswith("--"):
            if i + 1 >= len(argv):
                sys.stderr.write("aws: error: argument %s: expected one argument\n" % arg)
                sys.exit(252)
            options[arg] = argv[i + 1]
            i += 2
        else:
            positional.append(arg)
            i += 1
    return options, positional


def rule_status(operation, key):
    """The status of the first rule for this call, consuming one count."""
    path = os.environ.get("FAKE_AWS_RULES")
    if not path or not os.path.exists(path):
        return None
    with open(path) as stream:
        lines = stream.read().splitlines()
    for number, line in enumerate(lines):
        fields = line.split()
        if len(fields) < 3 or fields[0] != operation or not re.search(fields[1], key):
            continue
        status = fields[2]
        if len(fields) > 3:
            count = int(fields[3]) - 1
            lines[number] = " ".join(fields[:3] + [str(count)]) if count > 0 else ""
            with open(path, "w") as stream:
                stream.write("\n".join(line for line in lines if line) + "\n")
        return status
    return None


def output(options, values):
    query = options.get("--query")
    if query == "[ETag, VersionId]" and options.get("--output") == "text":
        print("%s\t%s" % (values.get("ETag"), values.get("VersionId") or "None"))
    elif query == "ETag" and options.get("--output") == "text":
        print(values.get("ETag"))
    else:
        print(json.dumps(values, indent=4))


def main(argv):
    if "--version" in argv:
        print(os.environ.get("FAKE_AWS_VERSION", "aws-cli/2.38.6 Python/3.14.8 Linux/6.18 exe/x86_64.ubuntu.24"))
        return 0
    options, positional = parse(argv[1:])
    if positional[:2] == ["s3api", "put-object"] and options.get("--generate-cli-skeleton"):
        skeleton = {"Bucket": "", "Key": "", "Body": "", "ChecksumSHA256": "", "IfNoneMatch": ""}
        if not os.environ.get("FAKE_AWS_NO_IF_MATCH"):
            skeleton["IfMatch"] = ""
        print(json.dumps(skeleton, indent=4))
        return 0
    if positional[:1] != ["s3api"] or len(positional) < 2 or positional[1] not in ("get-object", "put-object"):
        sys.stderr.write("fake aws: unsupported command: %s\n" % " ".join(argv[1:]))
        return 252
    if os.environ.get("FAKE_AWS_NO_IF_MATCH") and "--if-match" in options:
        sys.stderr.write("\naws: [ERROR]: Unknown options: --if-match, %s\n" % options["--if-match"])
        return 252
    root = os.environ["FAKE_S3_DIR"]
    bucket, key = options.get("--bucket", ""), options.get("--key", "")
    operation = "GetObject" if positional[1] == "get-object" else "PutObject"
    condition = options.get("--if-none-match") and "if-none-match" or options.get("--if-match") and "if-match" or "none"
    log = os.environ.get("FAKE_AWS_LOG")
    if log:
        with open(log, "a") as stream:
            stream.write("%s %s %s %s\n" % (operation, key, condition, options.get("--endpoint-url", "-")))
    path = os.path.join(root, bucket, key)
    meta = os.path.join(root, ".meta", bucket, key + ".json")
    with open(os.path.join(root, ".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        status = rule_status(operation, key)
        if status in ERRORS:
            error(operation, status)
        if not os.path.isdir(os.path.join(root, bucket)):
            fail(operation, "NoSuchBucket", "The specified bucket does not exist")
        exists = os.path.isfile(path)
        current = json.load(open(meta)) if exists else {}
        if operation == "GetObject":
            if not exists:
                error(operation, "404")
            with open(path, "rb") as source, open(positional[2], "wb") as target:
                target.write(source.read())
            output(options, {"ETag": current["ETag"], "VersionId": current.get("VersionId"),
                             "ContentType": current.get("ContentType")})
            return 0
        if "--if-none-match" in options and "--if-match" in options:
            fail(operation, "NotImplemented", "Multiple conditional request headers present in the request")
        ignore = status == "ignore" or os.environ.get("FAKE_AWS_IGNORE_CONDITIONS") == "1"
        if not ignore:
            if options.get("--if-none-match") == "*" and exists:
                error(operation, "412")
            if "--if-match" in options:
                if not exists:
                    error(operation, "404")
                if options["--if-match"].strip('"') != current["ETag"].strip('"'):
                    error(operation, "412")
        with open(options["--body"], "rb") as source:
            body = source.read()
        if "--checksum-sha256" in options:
            if base64.b64encode(hashlib.sha256(body).digest()).decode() != options["--checksum-sha256"]:
                fail(operation, "BadDigest", "The SHA256 you specified did not match the calculated checksum.")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.makedirs(os.path.dirname(meta), exist_ok=True)
        with open(path + ".partial", "wb") as target:
            target.write(body)
        os.replace(path + ".partial", path)
        version = None
        if os.environ.get("FAKE_S3_VERSIONING") == "1":
            version = "v%d" % (int(current.get("VersionId", "v0")[1:]) + 1 if current else 1)
        values = {"ETag": '"%s"' % hashlib.md5(body).hexdigest(), "VersionId": version,
                  "ContentType": options.get("--content-type"), "CacheControl": options.get("--cache-control"),
                  "ChecksumSHA256": options.get("--checksum-sha256")}
        with open(meta, "w") as stream:
            json.dump(values, stream)
        output(options, {"ETag": values["ETag"], "VersionId": version})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
