class Store:
    def __init__(self):
        self._data = {}
        self._size_cache = None

    def put(self, key, value):
        self._data[key] = value
        # BUG: the cached size is not invalidated here, so size() keeps
        # returning a stale value after the first time it is computed.

    def delete(self, key):
        self._data.pop(key, None)

    def size(self):
        if self._size_cache is None:
            self._size_cache = len(self._data)
        return self._size_cache
