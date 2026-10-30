#!/usr/bin/env python3
"""CI gate: Validate all .yml/.yaml files for syntax correctness."""
import os
import sys
import subprocess

def main():
    repo_root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True
    ).stdout.strip()
    os.chdir(repo_root)

    yaml_files = []
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in (".git", "_opam", ".worktrees")]
        for f in files:
            if f.endswith((".yml", ".yaml")):
                yaml_files.append(os.path.join(root, f))
    yaml_files.sort()

    if not yaml_files:
        print("No YAML files to validate.")
        return 0

    exit_code = 0
    count = 0
    for f in yaml_files:
        result = subprocess.run(
            [sys.executable, "-c", "import yaml, sys; yaml.safe_load(open(sys.argv[1]))", f],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            count += 1
        else:
            print(f"ERROR: Invalid YAML in: {f}")
            print(result.stderr.strip())
            exit_code = 1

    print(f"{count} YAML files validated successfully.")
    return exit_code

if __name__ == "__main__":
    sys.exit(main())