def load(lines):
    entries = {}
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        entries[key.strip()] = value.strip()
    return entries
