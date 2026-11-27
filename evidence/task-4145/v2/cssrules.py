import re, hashlib
def rules(p):
    s = open(p, 'rb').read().decode('utf8', 'replace')
    parts = re.split(r'(?<=})', s)
    return parts
a = rules('b2/assets/dashboard/assets/index6.css')
b = rules('p2/assets/dashboard/assets/index6.css')
sa = [x for x in a if x.strip()]
sb = [x for x in b if x.strip()]
print('rules before', len(sa), 'prhead', len(sb))
ca = {hashlib.sha256(x.encode()).hexdigest(): x for x in sa}
cb = {hashlib.sha256(x.encode()).hexdigest(): x for x in sb}
only_a = [ca[h] for h in ca if h not in cb]
only_b = [cb[h] for h in cb if h not in ca]
print('only-in-before rules:', len(only_a))
for x in only_a[:5]: print('  B:', x[:160])
print('only-in-prhead rules:', len(only_b))
for x in only_b[:5]: print('  P:', x[:160])
