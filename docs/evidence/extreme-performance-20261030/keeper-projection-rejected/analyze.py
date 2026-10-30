from pathlib import Path
import hashlib
import json
import statistics

root = Path(__file__).resolve().parent
data = (root / 'samples-v1.jsonl').read_bytes()
records = [json.loads(line) for line in data.decode().splitlines()]
results = []
for case in dict.fromkeys(row['case'] for row in records[1:]):
    variants = {}
    for variant in ('baseline','candidate'):
        rows = [row for row in records[1:] if row['case'] == case and row['variant'] == variant]
        variants[variant] = {
            'batches':len(rows), 'iterations_per_batch':[row['iterations'] for row in rows],
            'median_per_call_batch_wall_ns':statistics.median(row['wall_ns']/row['iterations'] for row in rows),
            'median_per_call_batch_cpu_s':statistics.median(row['cpu_s']/row['iterations'] for row in rows),
            'median_per_call_batch_allocated_bytes':statistics.median(row['allocated_bytes']/row['iterations'] for row in rows),
        }
    ratios = {key:variants['candidate'][key]/variants['baseline'][key]
              for key in ('median_per_call_batch_wall_ns','median_per_call_batch_cpu_s',
                          'median_per_call_batch_allocated_bytes') if variants['baseline'][key] != 0}
    results.append({'case':case, 'variants':variants, 'candidate_over_baseline':ratios})
value = {
    'scope':'Five alternating-order batches in one component execution. Reported medians summarize per-call batch averages, not per-call latency quantiles. Reduced record stubs exclude actual activity/date parsing and sorting. Shared host uncontrolled. No native TUI, physical paint or target proof.',
    'source_samples_sha256':hashlib.sha256(data).hexdigest(),
    'metadata_validation':records[0], 'cases':results,
}
with (root / 'analysis-v1.json').open('x') as stream:
    json.dump(value,stream,indent=2)
    stream.write('\n')
