#!/usr/bin/env python3
"""A stand-in for the AWS CLI's s3api get-object, put-object and multipart
upload (create-multipart-upload, upload-part, complete-multipart-upload,
abort-multipart-upload), for tests.

Objects live in $FAKE_S3_DIR/<bucket>/<key>, and their ETags (the MD5,
quoted, as S3's) in $FAKE_S3_DIR/.meta. Conditional writes are checked and
made under a lock, as S3 makes them, so concurrent publishes race for
real. Errors are printed as AWS CLI 2.34+ prints them, with exit code 254.

  FAKE_S3_DIR               where the buckets are (required)
  FAKE_AWS_LOG              a file to append one line per call to
  FAKE_AWS_RULES            a file of rules, one per line:
                              OPERATION KEY_REGEX STATUS [COUNT]
                            OPERATION is GetObject or PutObject; STATUS is
                            403, 404, 409, 412 or 500, ignore (make the
                            write, ignoring its condition), or landed-412
                            (make the write, then answer 412, as the AWS
                            CLI's retry of a write whose response was lost
                            gets from the write it made). A rule with a
                            COUNT applies that many times.
  FAKE_AWS_IGNORE_CONDITIONS=1
                            a backend that ignores If-Match and If-None-Match
  FAKE_AWS_NO_IF_MATCH=1    an old CLI, whose put-object can't take --if-match
  FAKE_S3_VERSIONING=1      a versioned bucket: writes return a VersionId,
                            and get-object --version-id reads any version
                            written while it was set
  FAKE_AWS_IGNORE_VERSION_ID=1
                            a service that ignores --version-id, and
                            returns the current object
  FAKE_AWS_IGNORE_MULTIPART_CONDITIONS=1
                            a backend that enforces conditions on PutObject
                            but ignores them on CompleteMultipartUpload
  FAKE_AWS_NO_MULTIPART_CONDITIONS=1
                            an old CLI, whose complete-multipart-upload
                            can't take --if-none-match
  FAKE_AWS_NO_CHECKSUM_ECHO=1
                            a service that checks an UploadPart's
                            --checksum-sha256 but doesn't echo it back

Multipart uploads keep their parts in $FAKE_S3_DIR/.uploads/<id>/ until
they complete or are aborted. As S3 does, every part but the last must be
at least 5 MiB, a part's --checksum-sha256 must match it, and an upload
created with --checksum-algorithm SHA256 needs each part's ChecksumSHA256
when it completes. Rules apply to the operations CreateMultipartUpload,
UploadPart, CompleteMultipartUpload and AbortMultipartUpload too.

The log line of a GetObject with --version-id has version=<id> (or else,
with --range, range=<range>), and an UploadPart's part=<number>, where
other calls have their condition. get-object --range bytes=A-B writes only
those bytes, as S3 does, and an empty object answers 416 InvalidRange.
"""

import base64
import fcntl
import hashlib
import json
import os
import re
import shutil
import sys

ERRORS = {
    "403": ("AccessDenied", "Access Denied"),
    "404": ("NoSuchKey", "The specified key does not exist."),
    "NoSuchVersion": ("NoSuchVersion", "The specified version does not exist."),
    "InvalidVersion": ("InvalidArgument", "Invalid version id specified"),
    "InvalidRange": ("InvalidRange", "The requested range is not satisfiable"),
    "409": ("ConditionalRequestConflict",
            "The conditional request cannot succeed due to a conflicting operation against this resource."),
    "412": ("PreconditionFailed", "At least one of the pre-conditions you specified did not hold"),
    "500": ("InternalError", "We encountered an internal error. Please try again."),
    "NoSuchUpload": ("NoSuchUpload", "The specified upload does not exist."),
    "EntityTooSmall": ("EntityTooSmall", "Your proposed upload is smaller than the minimum allowed object size."),
    "InvalidPart": ("InvalidPart", "One or more of the specified parts could not be found."),
}
OPERATIONS = {"get-object": "GetObject", "put-object": "PutObject",
              "create-multipart-upload": "CreateMultipartUpload", "upload-part": "UploadPart",
              "complete-multipart-upload": "CompleteMultipartUpload",
              "abort-multipart-upload": "AbortMultipartUpload"}
MIN_PART = 5 * 1024 * 1024


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
        elif arg.startswith("--") and "=" in arg:
            name, value = arg.split("=", 1)
            options[name] = value
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
    elif query == "[ETag, ChecksumSHA256]" and options.get("--output") == "text":
        print("%s\t%s" % (values.get("ETag"), values.get("ChecksumSHA256") or "None"))
    elif query == "UploadId" and options.get("--output") == "text":
        print(values.get("UploadId"))
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
    if positional[:2] == ["s3api", "complete-multipart-upload"] and options.get("--generate-cli-skeleton"):
        skeleton = {"Bucket": "", "Key": "", "UploadId": "", "MultipartUpload": {"Parts": []}}
        if not os.environ.get("FAKE_AWS_NO_MULTIPART_CONDITIONS"):
            skeleton.update({"IfMatch": "", "IfNoneMatch": ""})
        print(json.dumps(skeleton, indent=4))
        return 0
    if positional[:1] != ["s3api"] or len(positional) < 2 or positional[1] not in OPERATIONS:
        sys.stderr.write("fake aws: unsupported command: %s\n" % " ".join(argv[1:]))
        return 252
    if os.environ.get("FAKE_AWS_NO_IF_MATCH") and "--if-match" in options:
        sys.stderr.write("\naws: [ERROR]: Unknown options: --if-match, %s\n" % options["--if-match"])
        return 252
    root = os.environ["FAKE_S3_DIR"]
    bucket, key = options.get("--bucket", ""), options.get("--key", "")
    operation = OPERATIONS[positional[1]]
    condition = options.get("--if-none-match") and "if-none-match" or options.get("--if-match") and "if-match" or "none"
    version_id = options.get("--version-id")
    if version_id is not None and operation == "GetObject":
        condition = "version=%s" % version_id
    elif "--range" in options and operation == "GetObject":
        condition = "range=%s" % options["--range"]
    if operation == "UploadPart":
        condition = "part=%s" % options.get("--part-number")
    log = os.environ.get("FAKE_AWS_LOG")
    if log:
        with open(log, "a") as stream:
            stream.write("%s %s %s %s\n" % (operation, key, condition, options.get("--endpoint-url", "-")))
    path = os.path.join(root, bucket, key)
    meta = os.path.join(root, ".meta", bucket, key + ".json")
    versions = os.path.join(root, ".versions", bucket, key)
    with open(os.path.join(root, ".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        status = rule_status(operation, key)
        if status in ERRORS:
            error(operation, status)
        if not os.path.isdir(os.path.join(root, bucket)):
            fail(operation, "NoSuchBucket", "The specified bucket does not exist")
        exists = os.path.isfile(path)
        current = json.load(open(meta)) if exists else {}
        if operation in ("CreateMultipartUpload", "UploadPart", "CompleteMultipartUpload", "AbortMultipartUpload"):
            return multipart(operation, options, root, bucket, key, path, meta, versions, exists, current, status)
        if operation == "GetObject":
            if version_id is not None and not os.environ.get("FAKE_AWS_IGNORE_VERSION_ID"):
                if version_id == "null" and exists and not current.get("VersionId"):
                    pass
                elif os.path.isfile(os.path.join(versions, version_id)):
                    path = os.path.join(versions, version_id)
                    current = json.load(open(path + ".json"))
                elif exists and current.get("VersionId") or os.path.isdir(versions):
                    error(operation, "NoSuchVersion")
                elif exists:
                    error(operation, "InvalidVersion")
            if not exists:
                error(operation, "404")
            size = os.path.getsize(path)
            start, end = 0, size - 1
            if "--range" in options:
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", options["--range"])
                if not match:
                    sys.stderr.write("fake aws: unsupported --range %s\n" % options["--range"])
                    return 252
                start = int(match.group(1))
                if match.group(2):
                    end = min(end, int(match.group(2)))
                if start >= size:
                    error(operation, "InvalidRange")
            # Only the bytes asked for are read, so a test can stand a huge
            # sparse object in the bucket.
            with open(path, "rb") as source, open(positional[2], "wb") as target:
                source.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    chunk = source.read(min(remaining, 1 << 20))
                    if not chunk:
                        break
                    target.write(chunk)
                    remaining -= len(chunk)
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
        if version:
            os.makedirs(versions, exist_ok=True)
            with open(os.path.join(versions, version), "wb") as target:
                target.write(body)
            with open(os.path.join(versions, version + ".json"), "w") as stream:
                json.dump(values, stream)
        if status == "landed-412":
            error(operation, "412")
        output(options, {"ETag": values["ETag"], "VersionId": version})
    return 0


def write_object(path, meta, versions, body, values, current):
    """Stores body as the object, with values as its metadata, as PutObject does."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.makedirs(os.path.dirname(meta), exist_ok=True)
    with open(path + ".partial", "wb") as target:
        target.write(body)
    os.replace(path + ".partial", path)
    version = None
    if os.environ.get("FAKE_S3_VERSIONING") == "1":
        version = "v%d" % (int(current.get("VersionId", "v0")[1:]) + 1 if current else 1)
    values = dict(values, VersionId=version)
    with open(meta, "w") as stream:
        json.dump(values, stream)
    if version:
        os.makedirs(versions, exist_ok=True)
        with open(os.path.join(versions, version), "wb") as target:
            target.write(body)
        with open(os.path.join(versions, version + ".json"), "w") as stream:
            json.dump(values, stream)
    return values


def multipart(operation, options, root, bucket, key, path, meta, versions, exists, current, status):
    """The multipart upload's operations, under the caller's lock."""
    uploads = os.path.join(root, ".uploads")
    if operation == "CreateMultipartUpload":
        os.makedirs(uploads, exist_ok=True)
        upload_id = "upload-%s" % hashlib.sha256(os.urandom(16)).hexdigest()[:16]
        os.makedirs(os.path.join(uploads, upload_id))
        with open(os.path.join(uploads, upload_id, "upload.json"), "w") as stream:
            json.dump({"Bucket": bucket, "Key": key, "ContentType": options.get("--content-type"),
                       "CacheControl": options.get("--cache-control"),
                       "ChecksumAlgorithm": options.get("--checksum-algorithm")}, stream)
        output(options, {"UploadId": upload_id, "Bucket": bucket, "Key": key})
        return 0
    upload_dir = os.path.join(uploads, options.get("--upload-id", ""))
    upload_file = os.path.join(upload_dir, "upload.json")
    if not options.get("--upload-id") or not os.path.isfile(upload_file):
        error(operation, "NoSuchUpload")
    upload = json.load(open(upload_file))
    if (upload["Bucket"], upload["Key"]) != (bucket, key):
        error(operation, "NoSuchUpload")
    if operation == "AbortMultipartUpload":
        shutil.rmtree(upload_dir)
        return 0
    if operation == "UploadPart":
        number = int(options["--part-number"])
        with open(options["--body"], "rb") as source:
            body = source.read()
        checksum = base64.b64encode(hashlib.sha256(body).digest()).decode()
        if "--checksum-sha256" in options and options["--checksum-sha256"] != checksum:
            fail(operation, "BadDigest", "The SHA256 you specified did not match the calculated checksum.")
        with open(os.path.join(upload_dir, "%05d.part" % number), "wb") as target:
            target.write(body)
        etag = '"%s"' % hashlib.md5(body).hexdigest()
        with open(os.path.join(upload_dir, "%05d.json" % number), "w") as stream:
            json.dump({"ETag": etag, "ChecksumSHA256": checksum}, stream)
        output(options, {"ETag": etag,
                         "ChecksumSHA256": None if os.environ.get("FAKE_AWS_NO_CHECKSUM_ECHO")
                         else checksum if upload["ChecksumAlgorithm"] or "--checksum-sha256" in options else None})
        return 0
    # CompleteMultipartUpload
    if os.environ.get("FAKE_AWS_NO_MULTIPART_CONDITIONS") and ("--if-none-match" in options or "--if-match" in options):
        sys.stderr.write("\naws: [ERROR]: Unknown options: --if-none-match, %s\n" % options.get("--if-none-match"))
        return 252
    spec = options.get("--multipart-upload", "")
    if not spec.startswith("file://"):
        sys.stderr.write("fake aws: --multipart-upload must be file://PATH\n")
        return 252
    parts = json.load(open(spec[len("file://"):]))["Parts"]
    if not parts or [p["PartNumber"] for p in parts] != list(range(1, len(parts) + 1)):
        error(operation, "InvalidPart")
    body = b""
    digests = b""
    for index, part in enumerate(parts):
        stored = os.path.join(upload_dir, "%05d" % part["PartNumber"])
        if not os.path.isfile(stored + ".part"):
            error(operation, "InvalidPart")
        info = json.load(open(stored + ".json"))
        if part.get("ETag") != info["ETag"]:
            error(operation, "InvalidPart")
        if upload["ChecksumAlgorithm"] == "SHA256" and part.get("ChecksumSHA256") != info["ChecksumSHA256"]:
            error(operation, "InvalidPart")
        data = open(stored + ".part", "rb").read()
        if index < len(parts) - 1 and len(data) < MIN_PART:
            error(operation, "EntityTooSmall")
        body += data
        digests += hashlib.md5(data).digest()
    ignore = (status == "ignore" or os.environ.get("FAKE_AWS_IGNORE_CONDITIONS") == "1"
              or os.environ.get("FAKE_AWS_IGNORE_MULTIPART_CONDITIONS") == "1")
    if "--if-none-match" in options and "--if-match" in options:
        fail(operation, "NotImplemented", "Multiple conditional request headers present in the request")
    if not ignore:
        if options.get("--if-none-match") == "*" and exists:
            error(operation, "412")
        if "--if-match" in options:
            if not exists:
                error(operation, "404")
            if options["--if-match"].strip('"') != current["ETag"].strip('"'):
                error(operation, "412")
    values = write_object(path, meta, versions, body, {
        "ETag": '"%s-%d"' % (hashlib.md5(digests).hexdigest(), len(parts)),
        "ContentType": upload["ContentType"], "CacheControl": upload["CacheControl"],
        "ChecksumSHA256": None}, current)
    shutil.rmtree(upload_dir)
    output(options, {"ETag": values["ETag"], "VersionId": values["VersionId"]})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
