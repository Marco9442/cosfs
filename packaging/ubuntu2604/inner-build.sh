#!/usr/bin/env bash
# 在 ubuntu:26.04 容器内编译并打出 deb。由 build-deb.sh 调用。
set -euo pipefail

: "${DEB_VERSION:?}"
: "${UPSTREAM_SHA:?}"
: "${RELEASE_TAG:?}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  g++ make pkg-config autoconf automake libtool \
  libcurl4-openssl-dev libfuse-dev libssl-dev libxml2-dev \
  ca-certificates python3

rm -rf /tmp/cosfs /tmp/stage
cp -a /src /tmp/cosfs
cd /tmp/cosfs
python3 - << 'PY'
from pathlib import Path
p = Path("configure.ac")
text = p.read_text(encoding="utf-8")
normalized = text.replace("\u201c", '"').replace("\u201d", '"')
if normalized != text:
    p.write_text(normalized, encoding="utf-8")
    print("normalized configure.ac quotes")
PY
./autogen.sh
./configure --prefix=/usr/local
make -j"$(nproc)"
ldd src/cosfs | tee /tmp/ldd.txt
grep -q 'libfuse.so.2' /tmp/ldd.txt
grep -q 'libxml2.so.16' /tmp/ldd.txt

make install DESTDIR=/tmp/stage
test -x /tmp/stage/usr/local/bin/cosfs

objdump -p src/cosfs | awk '/NEEDED/ {print $2}' > /tmp/needed.txt
python3 - << 'PY'
import subprocess
from pathlib import Path
ldd = Path("/tmp/ldd.txt").read_text(encoding="utf-8")
wanted = Path("/tmp/needed.txt").read_text(encoding="utf-8").split()
found = {}
for line in ldd.splitlines():
    parts = line.split()
    if "=>" not in parts:
        continue
    soname = parts[0]
    path = parts[parts.index("=>") + 1]
    if soname in wanted and path.startswith("/"):
        found[soname] = path
missing = [name for name in wanted if name not in found]
if missing:
    raise SystemExit(f"missing ldd paths: {missing}")
packages = []
for soname in wanted:
    out = subprocess.check_output(["dpkg", "-S", found[soname]], text=True)
    name = out.split(":", 1)[0].split(",")[0].strip().split(":")[0]
    if name not in packages:
        packages.append(name)
if not packages:
    raise SystemExit("no depends")
Path("/tmp/depends").write_text(", ".join(packages) + "\n", encoding="utf-8")
print("depends", ", ".join(packages))
PY

name="cosfs_${DEB_VERSION}_amd64"
rm -rf /tmp/debroot
mkdir -p /tmp/debroot/DEBIAN
cp -a /tmp/stage/. /tmp/debroot/
size="$(du -sk /tmp/debroot/usr | cut -f1)"
depends="$(tr -d '\n' < /tmp/depends)"
cat > /tmp/debroot/DEBIAN/control << EOF
Package: cosfs
Version: ${DEB_VERSION}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Marco9442 <Marco9442@users.noreply.github.com>
Installed-Size: ${size}
Depends: ${depends}
Homepage: https://github.com/Marco9442/cosfs
Description: Mount a Tencent COS bucket with FUSE
 Ubuntu 26.04 amd64 build of tencentyun/cosfs ${UPSTREAM_SHA}.
EOF

export DEB_FILE="/tmp/${name}.deb"
python3 - << 'PY'
import io
import os
import tarfile
import time
from pathlib import Path

END = bytes((0x60, 0x0A))

def member(name, data):
    header = (name + "/").encode().ljust(16)
    header += str(int(time.time())).encode().ljust(12)
    header += b"0".ljust(6) + b"0".ljust(6) + b"100644".ljust(8)
    header += str(len(data)).encode().ljust(10) + END
    if len(header) != 60:
        raise SystemExit(f"bad ar header {len(header)}")
    pad = b"\n" if len(data) % 2 else b""
    return header + data + pad

def as_root(info):
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    return info

def gzip_tar(paths):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tar:
        for src, arc in paths:
            tar.add(str(src), arcname=arc, recursive=True, filter=as_root)
    return buf.getvalue()

def parse_ar(blob):
    if not blob.startswith(b"!<arch>\n"):
        raise SystemExit("bad ar magic")
    pos = 8
    found = []
    payloads = {}
    while pos < len(blob):
        header = blob[pos:pos + 60]
        if len(header) != 60:
            raise SystemExit("truncated ar header")
        if header[58:60] != END:
            raise SystemExit("bad ar end")
        name = header[:16].decode().strip()
        size = int(header[48:58].decode().strip())
        data = blob[pos + 60:pos + 60 + size]
        if len(data) != size:
            raise SystemExit(f"truncated {name}")
        found.append(name)
        payloads[name] = data
        pos += 60 + size + (size % 2)
    return found, payloads

control = gzip_tar([(Path("/tmp/debroot/DEBIAN/control"), "./control")])
data = gzip_tar([(Path("/tmp/debroot/usr"), "./usr")])
blob = b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", control) + member("data.tar.gz", data)
found, payloads = parse_ar(blob)
if found != ["debian-binary/", "control.tar.gz/", "data.tar.gz/"]:
    raise SystemExit(f"ar members {found}")
if payloads["debian-binary/"] != b"2.0\n":
    raise SystemExit("bad debian-binary")
with tarfile.open(fileobj=io.BytesIO(payloads["data.tar.gz/"]), mode="r:gz") as tar:
    names = tar.getnames()
if not any(name.endswith("usr/local/bin/cosfs") for name in names):
    raise SystemExit("package missing cosfs")
out = Path(os.environ["DEB_FILE"])
out.write_bytes(blob)
print("deb bytes", len(blob))
PY
mkdir -p /out
cp "${DEB_FILE}" "/out/${name}.deb"

cat > /out/NOTES.md << EOF
upstream-sha: ${UPSTREAM_SHA}

上游提交：https://github.com/tencentyun/cosfs/commit/${UPSTREAM_SHA}

标签：${RELEASE_TAG}

Ubuntu 26.04 amd64 安装包。构建时会把 configure.ac 里的弯引号换成直引号，不改挂载行为。

\`\`\`bash
sudo apt-get install -y ./${name}.deb
\`\`\`
EOF
