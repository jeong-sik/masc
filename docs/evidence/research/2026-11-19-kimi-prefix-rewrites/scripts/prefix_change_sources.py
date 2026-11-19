# Usage: python3 -I prefix_change_sources.py <base-path>/.masc
# For consecutive Kimi turn pairs (11-18..11-19), names what changed in the
# system prompt (Markdown "### " headings only, never the text under them)
# and in the tool array (tool names only). Reads provider-input records and
# the blobs they reference, read-only.
import sys, json, os, re, glob, collections, datetime

H = sys.argv[1]
SHA = re.compile(r'sha256=([0-9a-f]+)')
HEADING = re.compile(r'^### (.+)$')
UTC = datetime.timezone.utc
# The window the RFC reports: 11-18 10:00Z .. 11-19 01:40Z.
T0 = datetime.datetime(2026, 11, 18, 10, 0, tzinfo=UTC).timestamp()
T1 = datetime.datetime(2026, 11, 19, 1, 40, tzinfo=UTC).timestamp()


def ref(artifact):
    if not isinstance(artifact, dict):
        return None
    m = SHA.search(artifact.get('content_ref') or '')
    return m.group(1) if m else None


def blob(digest):
    path = f"{H}/tool_blobs/{digest[:2]}/{digest}"
    return open(path, errors='replace').read() if os.path.exists(path) else None


def sections(text):
    """Heading -> digest of the text under it."""
    out, name, buf = {}, '(before first heading)', []
    for line in text.splitlines():
        m = HEADING.match(line)
        if m:
            out[name] = hash('\n'.join(buf).strip())
            name, buf = re.sub(r'\(\d+\)', '(#)', m.group(1).strip()), []
        else:
            buf.append(line)
    out[name] = hash('\n'.join(buf).strip())
    return out


system_changes = collections.Counter()
tool_changes = collections.Counter()
pairs = 0
for path in sorted(glob.glob(H + '/keepers/*/provider-inputs/2026-11/1[89].jsonl')):
    snaps = sorted((json.loads(l) for l in open(path) if l.strip()), key=lambda r: r['captured_at'])
    for a, b in zip(snaps, snaps[1:]):
        if not b['runtime_profile'].startswith('kimi_coding') or a['runtime_profile'] != b['runtime_profile']:
            continue
        if not (T0 <= b['captured_at'] <= T1):
            continue
        pairs += 1
        s0, s1 = ref(a.get('system_prompt')), ref(b.get('system_prompt'))
        if s0 != s1:
            x, y = blob(s0), blob(s1)
            if x is None or y is None:
                system_changes[('blob missing',)] += 1
            else:
                h0, h1 = sections(x), sections(y)
                changed = sorted(
                    [f'+{k}' for k in h1.keys() - h0.keys()]
                    + [f'-{k}' for k in h0.keys() - h1.keys()]
                    + [f'~{k}' for k in h0.keys() & h1.keys() if h0[k] != h1[k]])
                system_changes[tuple(changed)] += 1
        t0 = {t['name']: ref(t.get('artifact')) for t in a.get('tool_schemas') or []}
        t1 = {t['name']: ref(t.get('artifact')) for t in b.get('tool_schemas') or []}
        if t0 != t1:
            change = (tuple(sorted(t1.keys() - t0.keys())), tuple(sorted(t0.keys() - t1.keys())),
                      tuple(sorted(k for k in t0.keys() & t1.keys() if t0[k] != t1[k])))
            tool_changes[change] += 1

print('kimi consecutive turn pairs:', pairs)
print('system prompt changes, by heading (+added -removed ~changed):')
for k, n in system_changes.most_common():
    print(f'  {n:3d}  {", ".join(k)}')
print('tool array changes (added | removed | schema changed):')
for (added, removed, changed), n in tool_changes.most_common():
    print(f'  {n:3d}  {",".join(added) or "-"} | {",".join(removed) or "-"} | {",".join(changed) or "-"}')
