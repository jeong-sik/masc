#!/usr/bin/env python3
"""Embed the exact release setup helper as an OCaml byte string."""
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
# Decimal byte escapes preserve UTF-8 and cannot terminate an OCaml string.
print('let script = "' + ''.join('\\{:03d}'.format(byte) for byte in data) + '"')
