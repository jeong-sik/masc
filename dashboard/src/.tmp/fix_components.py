#!/usr/bin/env python3
"""Fix remaining component class replacements."""
import os

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

replacements = [
    ('components/mission-attention-card.ts', 'class="mission-inline-note"', 'class="grid gap-1"'),
    ('components/mission-agent-cards.ts', 'class="mission-activity-focus"', 'class="grid gap-1"'),
]

for rel_path, old, new in replacements:
    fpath = os.path.join(base, rel_path)
    with open(fpath) as f:
        content = f.read()
    count = content.count(old)
    if count > 0:
        content = content.replace(old, new)
        with open(fpath, 'w') as f:
            f.write(content)
        print(f"{rel_path}: replaced {count} occurrences")
    else:
        print(f"{rel_path}: already clean")
