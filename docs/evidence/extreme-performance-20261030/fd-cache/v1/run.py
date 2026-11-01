from pathlib import Path
import hashlib,json,os,subprocess,statistics,time
out=Path(__file__).resolve().parent
source_hash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
rows=[]
start=time.time()
for sample in ['p50','p99']:
 for paths in [30,300,1500]:
  for batch in range(4):
   order=['cached','fresh'] if batch%2==0 else ['fresh','cached']
   for mode in order:
    name=f'{sample}-{paths}-{batch}-{mode}'
    work=out/name;work.mkdir()
    argv=[str(out/'bench.exe'),mode,str(work),str(paths),str(max(3000,paths*4)),str(out/(sample+'.json'))]
    result=subprocess.run(argv,capture_output=True,text=True,env={'PATH':os.environ['PATH'],'LANG':'C.UTF-8'})
    (out/(name+'.stderr')).write_text(result.stderr)
    if result.returncode:
     (out/(name+'.stdout')).write_text(result.stdout)
     raise RuntimeError(f'{name}: {result.returncode}')
    data=json.loads(result.stdout);data.update(sample=sample,batch=batch,order=order)
    (out/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
    assert data['calls']==data['validated_rows']
    assert not list(work.iterdir());work.rmdir()
    rows.append({k:v for k,v in data.items() if k!='files'})
summary=[]
for sample in ['p50','p99']:
 for paths in [30,300,1500]:
  by={mode:[r for r in rows if r['sample']==sample and r['paths']==paths and r['mode']==mode] for mode in ['cached','fresh']}
  modes={mode:{metric:statistics.median(r[metric]/r['calls'] for r in group) for metric in ['wall_us','cpu_us','allocated_bytes']} for mode,group in by.items()}
  ratios={m:modes['fresh'][m]/modes['cached'][m] for m in modes['cached']}
  summary.append({'sample':sample,'paths':paths,'encoded_row_bytes':by['cached'][0]['encoded_row_bytes'],'median_batch_mean_per_call':modes,'fresh_over_cached':ratios})
result={'scope':'Single-domain frozen Fd_cache append/flush + repeated JSON encoding component, no per-path mutex or mkdir overhead; no fsync, server, Eio, concurrency or main-domain interference measurement. Includes initial file creation, excludes final cache drain/readback/cleanup from timed loops. Four AB/BA batches per input/path shape; median of batch means, not per-call latency percentiles. Caller-owned generated data removed only after complete exact-byte/count reread; per-file hashes retained privately. Shared host not quiesced.','compile_identity':json.loads((out/'identity.json').read_text()),'driver_sha256':source_hash,'driver_unchanged':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()==source_hash,'started_at_unix':start,'ended_at_unix':time.time(),'validated_calls':sum(r['validated_rows'] for r in rows),'rows':rows,'summary':summary}
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['driver_unchanged','validated_calls','summary']},indent=2))
