def parse_kv(text):
    out = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        key, _, value = line.partition("=")
        out[key] = value
    return out
