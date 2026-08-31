from store import Store


def build_inventory(pairs):
    """Insert each (key, value) pair, then report the final size.

    A caller reads size() early (warming the cache) and again at the end;
    the final size must reflect every put.
    """
    s = Store()
    s.put("warm", 0)
    _ = s.size()  # warms the size cache
    for key, value in pairs:
        s.put(key, value)
    return s.size()
