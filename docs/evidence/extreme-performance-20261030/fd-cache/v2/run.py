from pathlib import Path
import hashlib,json,os,subprocess,statistics,time
out=Path(__file__).resolve().parent
source_hash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
rows=[]
start=time.time()
for sample in ['p50','p99']:
 for paths in [30,300,1500]:
  for workers in [1,8]:
   for batch in range(4):
    order=['cached','split'] if batch%2==0 else ['split','cached']
    for mode in order:
     name=f'{sample}-{paths}-d{workers}-{batch}-{mode}'
     work=out/name;work.mkdir()
     argv=[str(out/'bench.exe'),mode,str(work),str(paths),str(max(3000,paths*4)),str(out/(sample+'.json')),str(workers)]
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
  for workers in [1,8]:
   by={mode:[r for r in rows if r['sample']==sample and r['paths']==paths and r['worker_domains']==workers and r['mode']==mode] for mode in ['cached','split']}
   modes={mode:{metric:statistics.median(r[metric]/r['calls'] for r in group) for metric in ['wall_us','cpu_us','allocated_bytes']} for mode,group in by.items()}
   ratios={m:modes['split'][m]/modes['cached'][m] for m in modes['cached']}
   summary.append({'sample':sample,'paths':paths,'worker_domains':workers,'encoded_row_bytes':by['cached'][0]['encoded_row_bytes'],'median_batch_mean_per_call':modes,'split_over_cached':ratios})
result={'scope':'Frozen Fd_cache versus prototype lease validation outside global cache mutex; per-path mutexes in both. Worker domain counts 1/8 plus idle coordinator. Timed window includes coordinator polling, excludes domain start/join/final cache drain/readback; no Eio or HTTP/main-domain stall measurement, no fsync or external rename/invalidation stress. Four AB/BA batches per shape; median batch means, not per-call latency percentile. All exact bytes/counts reread; generated data removed only afterwards. Shared host not quiesced. Allocation is sum of worker-local counter deltas captured before any worker exits.','compile_identity':json.loads((out/'identity.json').read_text()),'driver_sha256':source_hash,'driver_unchanged':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()==source_hash,'started_at_unix':start,'ended_at_unix':time.time(),'validated_calls':sum(r['validated_rows'] for r in rows),'rows':rows,'summary':summary}
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['driver_unchanged','validated_calls','summary']},indent=2))
