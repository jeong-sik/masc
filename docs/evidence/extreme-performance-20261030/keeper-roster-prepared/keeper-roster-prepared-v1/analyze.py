from pathlib import Path
import hashlib
import json
import statistics

p=Path(__file__).resolve().parent
data=(p/'samples-v1.jsonl').read_bytes()
samples=[json.loads(line) for line in data.decode().splitlines()]
cases=[]
for count in sorted({r['roster_rows'] for r in samples[1:]}):
    for name in dict.fromkeys(r['case'] for r in samples[1:]):
        rows=[r for r in samples[1:] if r['roster_rows']==count and r['case']==name]
        cases.append({'roster_rows':count,'case':name,'batches':len(rows),
          'iterations_per_batch':[r['iterations'] for r in rows],
          'median_operation_batch_wall_ns':statistics.median(r['wall_ns']/r['iterations'] for r in rows),
          'median_operation_batch_cpu_s':statistics.median(r['cpu_s']/r['iterations'] for r in rows),
          'median_operation_batch_allocated_bytes':statistics.median(r['allocated_bytes']/r['iterations'] for r in rows)})
memory_data=(p/'live-memory-samples-v1.jsonl').read_bytes()
memory=[json.loads(line) for line in memory_data.decode().splitlines()]
retained=[{'roster_rows':count,'delta_live_words':[r['delta_live_words'] for r in memory[1:] if r['roster_rows']==count],
           'median_delta_live_bytes':statistics.median(r['delta_live_words']*r['word_bits']/8 for r in memory[1:] if r['roster_rows']==count)}
          for count in sorted({r['roster_rows'] for r in memory[1:]})]
value={'scope':'Prototype over reduced typed records. Five batches per case; medians of per-operation batch averages, not individual latency quantiles. Batch lookup operations contain all N existing names of a complete roster in roster order. First means the first name, repeatedly queried after warmup. Cold batch includes prepare of an existing view; cold source preparation separately includes the source constructor. Neither includes actual fetch/JSON decode or UI/workspace admission. Warm allocation excludes prior construction and retained graph. GC live-word increments are not RSS or peak/reclamation proof.',
       'inputs_sha256':{'samples-v1.jsonl':hashlib.sha256(data).hexdigest(),'live-memory-samples-v1.jsonl':hashlib.sha256(memory_data).hexdigest()},
       'validation':samples[0],'cases':cases,'retained_live_graph':retained}
with (p/'analysis-v1.json').open('x') as f:json.dump(value,f,indent=2);f.write('\n')
