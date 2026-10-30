"""Explicit process-local protected-store fixture; never used by the package."""
import json


class MemoryRecords:
    values = {}

    def __init__(self, identity):
        self.identity = identity

    def read(self, slot):
        return self.values.get((self.identity, slot))

    def write(self, slot, value):
        self.values[self.identity, slot] = value


def active_slot(store):
    return json.loads((store.directory / store._reference_name).read_text())["slot"]


def active_raw(store):
    return store.records.read(active_slot(store))


def replace_active_raw(store, value):
    store.records.write(active_slot(store), value)
