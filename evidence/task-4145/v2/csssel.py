import difflib, re
a = open('b2/assets/dashboard/assets/index6.css','rb').read().decode('utf8','replace')
b = open('p2/assets/dashboard/assets/index6.css','rb').read().decode('utf8','replace')
d = list(difflib.unified_diff(a, b, lineterm=''))
# collect selectors only in before (lines starting with '-')
sels = set()
for line in d:
    if line.startswith('-') and not line.startswith('---'):
        for m in re.findall(r'[.#]?[a-zA-Z][a-zA-Z0-9_-]{3,}', line[:200]):
            sels.add(m)
print('candidate selectors (first 25):', sorted(sels)[:25])
