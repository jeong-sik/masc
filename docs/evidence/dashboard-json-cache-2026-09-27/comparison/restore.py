#!/usr/bin/env python3
"""Verify and restore one retained experiment for independent summarization."""
from pathlib import Path
import argparse, gzip, hashlib, json, tarfile
p=argparse.ArgumentParser();p.add_argument('experiment',type=Path);p.add_argument('output',type=Path);a=p.parse_args();a.output.mkdir(exist_ok=False)
manifest=json.loads((a.experiment/'receipt-files.json').read_text())
with tarfile.open(a.experiment/'receipts.tar.xz','r:xz') as archive:
 assert set(archive.getnames())==set(manifest)
 for member in archive.getmembers():
  m=manifest[member.name];rel=Path(m['original_path'])
  assert member.isfile() and not rel.is_absolute() and '..' not in rel.parts
  raw=archive.extractfile(member).read();assert hashlib.sha256(raw).hexdigest()==m['archive_member_sha256']
  content=gzip.compress(raw,mtime=0) if m['encoding']=='gzip-decompressed' else raw
  if m['encoding']=='verbatim':assert hashlib.sha256(content).hexdigest()==m['archive_member_sha256']
  dst=a.output/rel;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(content)
print(f'Verified and restored {len(manifest)} files; gzip byte streams may vary by Python/zlib version, published path-redacted receipt bytes are exact; local original hashes are provenance only.')
