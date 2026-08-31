class Store:
    def __init__(self):
        self._data = {}
        self._size_cache = None

    def put(self, key, value):
        self._data[key] = value
        self._size_cache = None

    def delete(self, key):
        self._data.pop(key, None)
        self._size_cache = None

    def size(self):
        if self._size_cache is None:
            self._size_cache = len(self._data)
        return self._size_cache
