import importlib.util
import pathlib

path = pathlib.Path("test/fixtures/coding_worker_repo_smoke/calc.py")
spec = importlib.util.spec_from_file_location("coding_worker_repo_smoke", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
value = module.add_two_and_three()
assert value == 5, f"expected 5, got {value}"
print("PASS")
