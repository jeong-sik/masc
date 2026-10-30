#!/usr/bin/env python3
"""Measure whole-process macOS max RSS and post-GC live words for the trail shim."""
import argparse
import csv
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('executable', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
binary = str(args.executable.resolve())
with args.output.open('w', newline='') as output:
    writer = csv.writer(output, lineterminator='\n')
    writer.writerow(['calls', 'fragments', 'width', 'ended', 'draw', 'version',
                     'sample', 'live_words_after_feed', 'live_words_after_draw', 'whole_process_max_rss_bytes'])
    for ended, draw in [(False, False), (False, True), (True, False), (True, True)]:
        for sample in range(5):
            versions = ['old', 'new'] if sample % 2 == 0 else ['new', 'old']
            for version in versions:
                command = ['/usr/bin/time', '-l', binary, '--profile', version, '24', '64', '4096',
                           str(ended).lower(), str(draw).lower()]
                result = subprocess.run(command, text=True, capture_output=True, check=True)
                before, after = map(int, result.stdout.strip().split(','))
                match = re.search(r'^\s*(\d+)\s+maximum resident set size', result.stderr, re.MULTILINE)
                if not match:
                    raise RuntimeError('macOS time did not report maximum resident set size')
                writer.writerow([24, 64, 4096, ended, draw, version, sample, before, after, int(match.group(1))])
                output.flush()
print(f'Wrote 40 separate-process measurements to {args.output}')
