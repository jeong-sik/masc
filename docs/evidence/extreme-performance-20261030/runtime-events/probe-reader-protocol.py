"""Real reader-process boundaries with synthetic report/clock metadata only."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
sys.path.insert(0,str(args.repo.resolve(strict=True)/'scripts/harness/perf'))
import keeper_scale_trace as trace

root=args.output.resolve()
root.mkdir(parents=True,exist_ok=False)
stub='#!'+sys.executable+'\n'+'''
from pathlib import Path
import os,sys,time
d=Path(os.environ['MASC_RTEV_CONTROL_DIR'])
mode=MODE
(d/'ready').write_text(str(time.time()))
print('ready pid='+sys.argv[2]+' started_at_unix='+str(time.time()),flush=True)
if mode=='early':
    while not (d/'allow-end').exists():time.sleep(.01)
else:
    while not (d/'stop').exists():time.sleep(.01)
    (d/'stop-ack').write_text(str(time.time()))
(d/'ended').write_text(str(time.time()))
print('events=1 lost=0',flush=True)
if mode!='missing_footer':(d/'report-complete').write_text(str(time.time()))
'''
rows=[]
for case in ['missing_footer','ended_before_stop']:
    out=root/case;out.mkdir();tools=out/'tools';tools.mkdir();base=out/'base'
    ring=base/'.masc/runtime/events';ring.mkdir(parents=True)
    for name in ['rtev_watch','rtev_fibers']:
        mode=('missing_footer' if case=='missing_footer' else 'early') if name=='rtev_watch' else 'normal'
        p=tools/(name+'.exe');p.write_text(stub.replace('MODE',repr(mode)));p.chmod(0o700)
    server=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True)
    (ring/(str(server.pid)+'.events')).touch()
    try:
        capture=trace.start(output=out,base=base,tools=tools,server=server,seconds=30,ready_timeout=5)
        start=time.time()
        if case=='ended_before_stop':
            (capture.readers[0].directory/'allow-end').touch()
            capture.readers[0].process.wait(timeout=5)
            # Model a backwards wall-clock step without changing the host clock:
            # the numerical containment predicate alone will still be true.
            end=start+.000001
        else:end=time.time()
        result=trace.finish(capture,started_at_unix=start,ended_at_unix=end)
        assert result['complete'] is False
        watch=result['readers'][0]
        assert watch['returncode']==0 and watch['lost']==0 and watch['covers_workload']
        assert not watch['report_flush_acknowledged'] if case=='missing_footer' else not watch['post_workload_stop_acknowledged']
        assert all(reader.process.poll() is not None for reader in capture.readers)
        rows.append({'case':case,'rejected':not result['complete'],'reader':watch})
    finally:
        server.terminate();server.wait(timeout=5)
(root/'result.json').write_text(json.dumps({'scope':'Synthetic protocol and clock metadata, actual owned OS children. Not native runtime-events or performance evidence.','cases':rows,'tested_source_sha256':hashlib.sha256(Path(trace.__file__).read_bytes()).hexdigest()},indent=2)+'\n')
print(json.dumps(rows))
