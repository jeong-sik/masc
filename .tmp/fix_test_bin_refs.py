"""Fix Llm_types/Llm_orchestration references in test/ and bin/ files.

Files that do `open Masc_mcp` can use Llm_types directly.
Files that don't need Masc_mcp.Llm_types prefix.
"""
import os
import re

def has_open_masc_mcp(content):
    return bool(re.search(r'^open Masc_mcp\b', content, re.MULTILINE))

def fix_file(filepath):
    with open(filepath) as f:
        content = f.read()
    original = content

    if has_open_masc_mcp(content):
        # Already has open Masc_mcp, Llm_types is accessible directly
        pass
    else:
        # Need to prefix with Masc_mcp.
        content = re.sub(r'(?<!\.)Llm_types\.', 'Masc_mcp.Llm_types.', content)
        content = re.sub(r'(?<!\.)Llm_orchestration\.', 'Masc_mcp.Llm_orchestration.', content)
        # Fix double prefix
        content = content.replace('Masc_mcp.Masc_mcp.', 'Masc_mcp.')

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        return True
    return False

changed = 0
for d in ['test', 'bin']:
    if not os.path.isdir(d):
        continue
    for root, dirs, files in os.walk(d):
        for f in sorted(files):
            if f.endswith('.ml') or f.endswith('.mli'):
                path = os.path.join(root, f)
                if fix_file(path):
                    changed += 1
                    print(f"  {path}: fixed")

print(f"\nFixed {changed} files")
