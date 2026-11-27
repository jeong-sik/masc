import difflib
a = open('b2/assets/dashboard/assets/index6.css','rb').read().decode('utf8','replace')
b = open('p2/assets/dashboard/assets/index6.css','rb').read().decode('utf8','replace')
print('len', len(a), len(b))
d = list(difflib.unified_diff(a, b, lineterm=''))
print('difflines', len(d))
print(''.join(d[:40]))
