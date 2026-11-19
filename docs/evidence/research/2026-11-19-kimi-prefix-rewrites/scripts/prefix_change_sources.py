# Usage: python3 -I prefix_change_sources.py <base-path>/.masc
# For consecutive Kimi turn pairs (11-18..11-19), names what changed in the
# system prompt (Markdown "### " headings only, never the text under them)
# and in the tool array (tool names only). For a changed keeper_tool_search
# schema it also names the tool names that entered or left it; its
# description lists the held-back tools. Reads provider-input records and
# the blobs they reference, read-only.
import sys, json, os, re, glob, collections, datetime

H = sys.argv[1]
SHA = re.compile(r'sha256=([0-9a-f]+)')
HEADING = re.compile(r'^### (.+)$')
# Snake-case identifiers: the shape of every tool name in the listing.
TOOL_NAME = re.compile(r'\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b')
# Heading of the context.direct_input_source template in config/prompts/keeper.md.
SOURCE_HEADING = 'Admitted Request Source'
TOOL_SEARCH = 'keeper_tool_search'
RECEIPT_WAIT = 'keeper_receipt_wait'
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


def listed_names(digest):
    text = blob(digest) if digest else None
    return None if text is None else set(TOOL_NAME.findall(text))


def offers_receipt_wait(tools):
    if RECEIPT_WAIT in tools:
        return True
    names = listed_names(tools.get(TOOL_SEARCH))
    return names is not None and RECEIPT_WAIT in names


system_changes = collections.Counter()
tool_changes = collections.Counter()
listing_changes = collections.Counter()
together = collections.Counter()
pairs = 0
for path in sorted(glob.glob(H + '/keepers/*/provider-inputs/2026-11/1[89].jsonl')):
    snaps = sorted((json.loads(l) for l in open(path) if l.strip()), key=lambda r: r['captured_at'])
    for a, b in zip(snaps, snaps[1:]):
        if not b['runtime_profile'].startswith('kimi_coding') or a['runtime_profile'] != b['runtime_profile']:
            continue
        if not (T0 <= b['captured_at'] <= T1):
            continue
        pairs += 1
        source_toggled = False
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
                source_toggled = (SOURCE_HEADING in h0) != (SOURCE_HEADING in h1)
        t0 = {t['name']: ref(t.get('artifact')) for t in a.get('tool_schemas') or []}
        t1 = {t['name']: ref(t.get('artifact')) for t in b.get('tool_schemas') or []}
        if t0 != t1:
            change = (tuple(sorted(t1.keys() - t0.keys())), tuple(sorted(t0.keys() - t1.keys())),
                      tuple(sorted(k for k in t0.keys() & t1.keys() if t0[k] != t1[k])))
            tool_changes[change] += 1
            if t0.get(TOOL_SEARCH) and t1.get(TOOL_SEARCH) and t0[TOOL_SEARCH] != t1[TOOL_SEARCH]:
                n0, n1 = listed_names(t0[TOOL_SEARCH]), listed_names(t1[TOOL_SEARCH])
                if n0 is None or n1 is None:
                    listing_changes[(('blob missing',), ())] += 1
                else:
                    listing_changes[(tuple(sorted(n1 - n0)), tuple(sorted(n0 - n1)))] += 1
        receipt_wait_toggled = offers_receipt_wait(t0) != offers_receipt_wait(t1)
        other_tools_changed = bool((t0.keys() ^ t1.keys()) - {RECEIPT_WAIT})
        together[(source_toggled, receipt_wait_toggled, other_tools_changed)] += 1

print('kimi consecutive turn pairs:', pairs)
print('system prompt changes, by heading (+added -removed ~changed):')
for k, n in system_changes.most_common():
    print(f'  {n:3d}  {", ".join(k)}')
print('tool array changes (added | removed | schema changed):')
for (added, removed, changed), n in tool_changes.most_common():
    print(f'  {n:3d}  {",".join(added) or "-"} | {",".join(removed) or "-"} | {",".join(changed) or "-"}')
print(f'{TOOL_SEARCH} schema changes, by tool names that entered | left it:')
for (entered, left), n in listing_changes.most_common():
    print(f'  {n:3d}  {",".join(entered) or "-"} | {",".join(left) or "-"}')
print(f'per pair: "{SOURCE_HEADING}" toggled | {RECEIPT_WAIT} offered toggled | other tools entered or left:')
for (source, receipt, other), n in sorted(together.items(), key=lambda kv: -kv[1]):
    print(f'  {n:3d}  {source} | {receipt} | {other}')
