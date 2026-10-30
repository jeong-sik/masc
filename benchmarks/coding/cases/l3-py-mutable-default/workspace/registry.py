def add_item(item, bucket=[]):
    """Append item to bucket and return the bucket.

    Each call without an explicit bucket should start from empty:
    add_item("a") -> ["a"], and a later add_item("b") -> ["b"], not
    ["a", "b"]. The default bucket must not persist across calls.
    """
    bucket.append(item)
    return bucket
