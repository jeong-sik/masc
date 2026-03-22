#!/usr/bin/env python3
"""Remove .activity-filter-bar and .live-monitor rules from live.css."""
import os

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fpath = os.path.join(base, 'styles', 'live.css')

with open(fpath) as f:
    content = f.read()

content = content.replace(
    '.activity-filter-bar {\n  display: flex;\n  gap: 6px;\n}\n',
    ''
)

content = content.replace(
    '.live-monitor {\n  display: grid;\n  gap: 16px;\n}\n',
    ''
)

with open(fpath, 'w') as f:
    f.write(content)

print(f"activity-filter-bar count: {content.count('activity-filter-bar')}")
print(f"live-monitor count: {content.count('live-monitor')}")
