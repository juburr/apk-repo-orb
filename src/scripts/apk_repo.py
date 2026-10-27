"""Reads APK repositories for apk-repo-orb's scripts.

Python 3.8 or newer, standard library only. The scripts run it as
python3 -I -c "${SCRIPT_APK_REPO_PY}" COMMAND ARGS, and do everything
else (signatures with openssl, objects with the AWS CLI) themselves.

An APK and an APKINDEX.tar.gz are concatenated gzip members, and their
signatures cover the exact compressed bytes of the members after the
first. Finding where a member ends needs the inflate state, which bash
can't reach; that is what this file is for. It never writes a path read
from an archive: members are read into memory, within the limits below.

Commands:

  index FILE ARCH WORKDIR
      Splits a signed APKINDEX.tar.gz. Writes WORKDIR/signature (the
      signature's bytes), WORKDIR/signed (every byte after the signature
      member: what the signature covers) and WORKDIR/entries.tsv, one
      line per package: P, V, A, S, C and a digest of the entry's fields,
      tab-separated. Prints the signing key's name (KEY in
      .SIGN.RSA256.KEY.pub).

  apk FILE WORKDIR
      Reads a package. Writes WORKDIR/control (its control segment, which
      its signature covers) and, when it has exactly one signature,
      WORKDIR/signature. Prints tab-separated fields: pkgname, pkgver, arch
      (from .PKGINFO), signatures (space-separated entry names),
      checksum (the index's C: for it), control_sha256, data_sha256 and
      size.

  receipt OUT WORKDIR
      Writes the JSON receipt from the files the scripts left in WORKDIR
      (meta.tsv, and arch/<arch>/index.tsv, packages.tsv, published,
      skipped_identical, attempts), through a temporary file it renames.

Exit codes: 0 success, 1 a file it refuses (with an ERROR: line on
stderr), 2 usage.
"""

import base64
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import tempfile
import zlib

# The same patterns as lib/apk_repo.sh; tests/wiring_test.sh checks that.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
VERSION_RE = re.compile(r"^[0-9A-Za-z._+~-]+-r[0-9]+$")
KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.rsa$")
SIGN_PREFIX = ".SIGN.RSA256."
ARCHES = ("x86_64", "aarch64")

# A signature member (compressed, and its tar), as apko caps it.
SIGNATURE_LIMIT = 64 * 1024
# An APKINDEX.tar.gz, compressed and decompressed.
INDEX_LIMIT = 128 * 1024 * 1024
# A package's control member (.PKGINFO and scripts), decompressed.
CONTROL_LIMIT = 16 * 1024 * 1024
CHUNK = 1024 * 1024


class Refused(Exception):
    """A file this helper won't accept; the message says why."""


def read_member(stream, limit, what):
    """Reads the gzip member that starts at stream's position.

    Returns (compressed bytes, decompressed bytes) and leaves stream at the
    member's end. Neither may exceed limit.
    """
    start = stream.tell()
    inflate = zlib.decompressobj(16 + zlib.MAX_WBITS)
    compressed = bytearray()
    pieces = []
    size = 0
    try:
        while not inflate.eof:
            chunk = stream.read(min(CHUNK, limit + 1))
            if not chunk:
                raise Refused("%s ends inside a gzip member" % what)
            compressed += chunk
            pending = chunk
            while pending and not inflate.eof:
                piece = inflate.decompress(pending, limit + 1 - size)
                size += len(piece)
                if size > limit:
                    raise Refused("%s holds more than %d bytes" % (what, limit))
                pieces.append(piece)
                pending = inflate.unconsumed_tail
            if len(compressed) - len(inflate.unused_data) > limit:
                raise Refused("%s is more than %d bytes compressed" % (what, limit))
    except zlib.error as error:
        raise Refused("%s is not valid gzip: %s" % (what, error))
    length = len(compressed) - len(inflate.unused_data)
    stream.seek(start + length)
    return bytes(compressed[:length]), b"".join(pieces)


def inflate_all(data, limit, what):
    """Decompresses one or more concatenated gzip members, within limit."""
    out = []
    size = 0
    rest = data
    try:
        while rest:
            inflate = zlib.decompressobj(16 + zlib.MAX_WBITS)
            pending = rest
            while pending and not inflate.eof:
                piece = inflate.decompress(pending, limit + 1 - size)
                size += len(piece)
                if size > limit:
                    raise Refused("%s holds more than %d bytes" % (what, limit))
                out.append(piece)
                pending = inflate.unconsumed_tail
            if not inflate.eof:
                raise Refused("%s ends inside a gzip member" % what)
            rest = inflate.unused_data
    except zlib.error as error:
        raise Refused("%s is not valid gzip: %s" % (what, error))
    return b"".join(out)


def tar_files(data, what):
    """Returns [(name, bytes)] for the regular files in a tar, in order."""
    files = []
    try:
        archive = tarfile.open(fileobj=io.BytesIO(data), mode="r:")
        for member in archive:
            if member.isdir():
                continue
            if not member.isreg():
                raise Refused("%s holds %s, which is not a regular file" % (what, member.name))
            files.append((member.name, archive.extractfile(member).read()))
    except tarfile.TarError as error:
        raise Refused("%s is not a valid tar archive: %s" % (what, error))
    return files


def signature_key(name):
    """The KEY in .SIGN.RSA256.KEY.pub, or None for any other entry name."""
    if not (name.startswith(SIGN_PREFIX) and name.endswith(".pub")):
        return None
    key = name[len(SIGN_PREFIX):-len(".pub")]
    return key if KEY_RE.fullmatch(key) else None


def text_field(value, what):
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise Refused("%s holds a control character" % what)
    return value


def parse_apkindex(text, path, arch):
    """Returns [(P, V, A, S, C, digest)] from APKINDEX's text."""
    entries = []
    seen = set()
    for number, block in enumerate(re.split(r"\n\s*\n", text), 1):
        lines = [line for line in block.split("\n") if line != ""]
        if not lines:
            continue
        fields = {}
        for line in lines:
            if len(line) < 2 or line[1] != ":":
                raise Refused("%s: entry %d has a line that isn't K:value: %r" % (path, number, line[:80]))
            text_field(line, "%s: entry %d" % (path, number))
            fields.setdefault(line[0], []).append(line[2:])
        values = {}
        for key in "PVASC":
            found = fields.get(key, [])
            if len(found) != 1 or found[0] == "":
                raise Refused("%s: entry %d needs exactly one %s: field" % (path, number, key))
            values[key] = found[0]
        name, version = values["P"], values["V"]
        what = "%s: %s-%s" % (path, name, version)
        if not NAME_RE.fullmatch(name):
            raise Refused("%s: entry %d names a package %r, which isn't a valid name" % (path, number, name))
        if not VERSION_RE.fullmatch(version):
            raise Refused("%s has a version that isn't <version>-r<N>" % what)
        if values["A"] != arch:
            raise Refused("%s is for %s, in the %s index" % (what, values["A"], arch))
        if not re.fullmatch(r"[0-9]+", values["S"]):
            raise Refused("%s has a size (S:) that isn't a number" % what)
        if (name, version) in seen:
            raise Refused("%s is listed twice" % what)
        seen.add((name, version))
        digest = hashlib.sha256("\n".join(sorted(lines)).encode("utf-8")).hexdigest()
        entries.append((name, version, values["A"], values["S"], values["C"], digest))
    return entries


def command_index(path, arch, workdir):
    if arch not in ARCHES:
        raise Refused("%s is not an architecture this orb handles" % arch)
    if os.path.getsize(path) > INDEX_LIMIT:
        raise Refused("%s is more than %d bytes" % (path, INDEX_LIMIT))
    with open(path, "rb") as stream:
        _, signature_tar = read_member(stream, SIGNATURE_LIMIT, "%s's signature" % path)
        signed = stream.read()
    signatures = tar_files(signature_tar, "%s's signature" % path)
    names = [name for name, _ in signatures]
    if len(signatures) != 1:
        raise Refused("%s has %d signature entries (%s); exactly one .SIGN.RSA256.<key>.rsa.pub is accepted"
                      % (path, len(signatures), " ".join(names) or "none"))
    name, signature = signatures[0]
    key = signature_key(name)
    if key is None:
        raise Refused("%s is signed as %s; only .SIGN.RSA256.<key>.rsa.pub signatures are accepted" % (path, name))
    if not signed:
        raise Refused("%s has nothing after its signature" % path)
    members = dict(tar_files(inflate_all(signed, INDEX_LIMIT, path), path))
    if "APKINDEX" not in members:
        raise Refused("%s has no APKINDEX file" % path)
    try:
        text = members["APKINDEX"].decode("utf-8")
    except UnicodeDecodeError:
        raise Refused("%s's APKINDEX is not UTF-8" % path)
    # apko only keeps a record that a blank line ends, so a last record
    # without one would be verified here and silently dropped there.
    if text.strip() and not text.endswith("\n\n"):
        raise Refused("%s's APKINDEX doesn't end with a blank line, so apko would drop its last entry" % path)
    entries = parse_apkindex(text, path, arch)
    write(os.path.join(workdir, "signature"), signature)
    write(os.path.join(workdir, "signed"), signed)
    write(os.path.join(workdir, "entries.tsv"),
          "".join("\t".join(entry) + "\n" for entry in entries).encode("utf-8"))
    print(key)


def parse_pkginfo(data, path):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused("%s's .PKGINFO is not UTF-8" % path)
    info = {}
    for line in text.split("\n"):
        if line.startswith("#") or " = " not in line:
            continue
        key, value = line.split(" = ", 1)
        info.setdefault(key.strip(), value.strip())
    for key in ("pkgname", "pkgver", "arch"):
        if not info.get(key):
            raise Refused("%s's .PKGINFO has no %s" % (path, key))
        text_field(info[key], "%s's %s" % (path, key))
    return info


def command_apk(path, workdir):
    size = os.path.getsize(path)
    with open(path, "rb") as stream:
        first, first_tar = read_member(stream, CONTROL_LIMIT, "%s's first segment" % path)
        first_files = tar_files(first_tar, "%s's first segment" % path)
        if any(name == ".PKGINFO" for name, _ in first_files):
            # An unsigned package starts with its control segment.
            signatures, control, control_files = [], first, first_files
        else:
            if len(first) > SIGNATURE_LIMIT:
                raise Refused("%s's signature segment is more than %d bytes" % (path, SIGNATURE_LIMIT))
            signatures = first_files
            control, control_tar = read_member(stream, CONTROL_LIMIT, "%s's control segment" % path)
            control_files = tar_files(control_tar, "%s's control segment" % path)
        data_hash = hashlib.sha256()
        data_size = 0
        while True:
            chunk = stream.read(CHUNK)
            if not chunk:
                break
            data_hash.update(chunk)
            data_size += len(chunk)
    pkginfo = [data for name, data in control_files if name == ".PKGINFO"]
    if len(pkginfo) != 1:
        raise Refused("%s has %d .PKGINFO files in its control segment" % (path, len(pkginfo)))
    if data_size == 0:
        raise Refused("%s has no data segment" % path)
    info = parse_pkginfo(pkginfo[0], path)
    # The index's C: covers the control segment, and this hash in it is what
    # ties the data segment to it, as apko checks when it installs.
    if not info.get("datahash"):
        raise Refused("%s's .PKGINFO has no datahash, so its data isn't covered by the index" % path)
    if info["datahash"] != data_hash.hexdigest():
        raise Refused("%s's data segment doesn't match the datahash in its .PKGINFO" % path)
    names = [name for name, _ in signatures]
    for name in names:
        text_field(name, "%s's signature entry" % path)
        if " " in name:
            raise Refused("%s has a signature entry with a space in its name" % path)
    if len(signatures) == 1:
        write(os.path.join(workdir, "signature"), signatures[0][1])
    write(os.path.join(workdir, "control"), control)
    fields = [
        ("pkgname", info["pkgname"]),
        ("pkgver", info["pkgver"]),
        ("arch", info["arch"]),
        ("signatures", " ".join(names)),
        ("checksum", "Q1" + base64.b64encode(hashlib.sha1(control).digest()).decode("ascii")),
        ("control_sha256", hashlib.sha256(control).hexdigest()),
        ("data_sha256", data_hash.hexdigest()),
        ("size", str(size)),
    ]
    for key, value in fields:
        print("%s\t%s" % (key, value))


def read_tsv(path):
    rows = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                line = line.rstrip("\n")
                if line:
                    rows.append(line.split("\t"))
    return rows


def read_lines(path):
    return [row[0] for row in read_tsv(path)]


def nullable(value):
    return None if value in ("", "None", "null") else value


def command_receipt(out, workdir):
    meta = dict((row[0], row[1] if len(row) > 1 else "") for row in read_tsv(os.path.join(workdir, "meta.tsv")))
    operation = meta.get("operation", "")
    receipt = {
        "schema_version": 1,
        "tool": "apk-repo-orb",
        "tool_version": meta.get("tool_version", ""),
        "operation": operation,
        "dry_run": meta.get("dry_run") == "true",
        "backend": nullable(meta.get("backend", "")),
        "endpoint_url": meta.get("endpoint_url") if "endpoint_url" in meta else None,
        "bucket": nullable(meta.get("bucket", "")),
        "prefix": nullable(meta.get("prefix", "")),
        "key_name": nullable(meta.get("key_name", "")),
        "started": meta.get("started", ""),
        "finished": meta.get("finished", ""),
        "architectures": {},
    }
    arch_root = os.path.join(workdir, "arch")
    for arch in sorted(os.listdir(arch_root)) if os.path.isdir(arch_root) else []:
        directory = os.path.join(arch_root, arch)
        index = dict((row[0], row[1] if len(row) > 1 else "") for row in read_tsv(os.path.join(directory, "index.tsv")))
        result = {
            "index": {
                "key": index.get("key", ""),
                "sha256": index.get("sha256", ""),
                "etag": nullable(index.get("etag", "")),
                "version_id": nullable(index.get("version_id", "")),
                "signature": index.get("signature", ""),
            },
            "packages": [
                {"name": row[0], "version": row[1], "file": row[2], "sha256": row[3], "size": int(row[4])}
                for row in read_tsv(os.path.join(directory, "packages.tsv"))
            ],
        }
        if operation == "publish":
            result["published"] = read_lines(os.path.join(directory, "published"))
            result["skipped_identical"] = read_lines(os.path.join(directory, "skipped_identical"))
            attempts = read_lines(os.path.join(directory, "attempts"))
            result["attempts"] = int(attempts[0]) if attempts else 0
        receipt["architectures"][arch] = result
    directory = os.path.dirname(os.path.abspath(out))
    handle, temporary = tempfile.mkstemp(prefix=".apk-repo-receipt.", dir=directory)
    # mkstemp makes the file 0600; a receipt gets the umask's usual mode.
    umask = os.umask(0)
    os.umask(umask)
    try:
        os.chmod(temporary, 0o666 & ~umask)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(receipt, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, out)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def write(path, data):
    with open(path, "wb") as stream:
        stream.write(data)


def main(argv):
    commands = {"index": (command_index, 3), "apk": (command_apk, 2), "receipt": (command_receipt, 2)}
    if len(argv) < 2 or argv[1] not in commands or len(argv) - 2 != commands[argv[1]][1]:
        sys.stderr.write("ERROR: usage: apk_repo.py index FILE ARCH WORKDIR | apk FILE WORKDIR | receipt OUT WORKDIR\n")
        return 2
    function, _ = commands[argv[1]]
    try:
        function(*argv[2:])
    except Refused as error:
        sys.stderr.write("ERROR: %s\n" % error)
        return 1
    except (OSError, ValueError) as error:
        sys.stderr.write("ERROR: %s\n" % error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
