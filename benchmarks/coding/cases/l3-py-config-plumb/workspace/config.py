def load(lines):
    entries = {}
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, _value = line.partition("=")
        entries[key.strip()] = ""
    return entries
