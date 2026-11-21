
import re, glob
names = set()
files = ['test/dune'] + sorted(glob.glob('test/stanzas/*.inc')) + sorted(glob.glob('test/*/dune'))
stanza = re.compile(r'\(test\b')
name = re.compile(r'\(name\s+([A-Za-z0-9_.-]+)\)')
bundle = re.compile(r'\(alias\s*\(\s*name\s+runtest\s*\)\s*\(deps\s*(.*?)\)\s*\)', re.S)
ref = re.compile(r'\(alias\s+runtest-([A-Za-z0-9_.-]+)\)')
for f in files:
    try:
        s = open(f, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    for m in stanza.finditer(s):
        nm = name.search(s[m.end():m.end() + 600])
        if nm:
            names.add(nm.group(1))
    for bm in bundle.finditer(s):
        for am in ref.finditer(bm.group(1)):
            names.add(am.group(1))
for n in sorted(names):
    print(n)
