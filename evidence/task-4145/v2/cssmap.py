import re, hashlib
def rules(p):
    s = open(p, 'rb').read().decode('utf8', 'replace')
    return [x for x in re.split(r'(?<=})', s) if x.strip()]
a = rules('b2/assets/dashboard/assets/index6.css')
b = rules('p2/assets/dashboard/assets/index6.css')
norm = lambda x: re.sub(r'\\', '', x)
ha = {hashlib.sha256(norm(x).encode()).hexdigest(): x for x in a}
hb = {hashlib.sha256(norm(x).encode()).hexdigest(): x for x in b}
only_a = [ha[h] for h in ha if h not in hb]
only_b = [hb[h] for h in hb if h not in ha]
print('rules before', len(ha), 'prhead', len(hb), 'only-before', len(only_a), 'only-prhead', len(only_b))
# extract class-like tokens from only-before rules
tokens = set()
for x in only_a:
    for m in re.findall(r'\.([a-zA-Z0-9_-]+)', x):
        tokens.add(m)
print('distinct class tokens only-in-before:', len(tokens))
open('only-before-classes.txt', 'w').write('\n'.join(sorted(tokens)))
