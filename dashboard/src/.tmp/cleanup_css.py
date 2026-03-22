#!/usr/bin/env python3
"""Clean up dead CSS selectors from mission.css after Tailwind migration."""
import os

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fpath = os.path.join(base, 'styles', 'mission.css')

with open(fpath) as f:
    content = f.read()

# 1. Remove .mission-activity-focus span from grouped selector
content = content.replace(
    '.mission-io-item span,\n.mission-activity-focus span {',
    '.mission-io-item span {'
)

# 2. Remove .mission-crew-event small, from grouped selector
content = content.replace(
    '.mission-stat-detail,\n.mission-crew-event small,\n.mission-timeline-row small {',
    '.mission-stat-detail,\n.mission-timeline-row small {'
)

# 3. Remove .mission-activity-focus strong from grouped selector
content = content.replace(
    '.mission-io-item strong,\n.mission-activity-focus strong {',
    '.mission-io-item strong {'
)

# 4. Remove .mission-activity-focus small from grouped selector
content = content.replace(
    '.mission-link-row small,\n.mission-activity-focus small {',
    '.mission-link-row small {'
)

# 5. Replace .mission-fact-tile small,.mission-inline-note,.mission-crew-event,.mission-activity-focus
# with just .mission-fact-tile small
content = content.replace(
    '.mission-fact-tile small,\n.mission-inline-note,\n.mission-crew-event,\n.mission-activity-focus {',
    '.mission-fact-tile small {'
)

# 6. Remove .mission-crew-event span, and .mission-crew-event strong, from grouped selector
content = content.replace(
    '.mission-crew-event span,\n.mission-crew-event strong,\n.mission-member-preview {',
    '.mission-member-preview {'
)

# 7. Remove .proof-summary-stack,.proof-kv-block,.mission-detail-column rule entirely
content = content.replace(
    '.proof-summary-stack,\n.proof-kv-block,\n.mission-detail-column {\n  display: grid;\n  gap: 10px;\n}\n',
    ''
)

with open(fpath, 'w') as f:
    f.write(content)

# Verify
with open(fpath) as f:
    lines = f.readlines()

dead = ['mission-inline-note', 'mission-crew-event', 'mission-activity-focus',
        'proof-summary-stack', 'proof-kv-block', 'mission-detail-column']
found = []
for i, line in enumerate(lines, 1):
    for d in dead:
        if d in line:
            found.append(f"  L{i}: {line.rstrip()}")

if found:
    print("REMAINING dead references:")
    for f in found:
        print(f)
else:
    print("OK: All dead selectors removed")
