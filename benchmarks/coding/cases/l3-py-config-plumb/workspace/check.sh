#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import importlib.util, pathlib

def load_mod(name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

config = load_mod("config")
greeting = load_mod("greeting")
assert greeting.greet(config.load(["NAME=Vincent"])) == "Hello, Vincent!"
assert greeting.greet(config.load(["OTHER=x"])) == "Hello, world!"
assert greeting.greet(config.load([])) == "Hello, world!"
print("PASS")
PY
