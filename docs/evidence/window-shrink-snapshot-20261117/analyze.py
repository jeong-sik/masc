from pathlib import Path
import hashlib,json,statistics

ROOT=Path(__file__).resolve().parent
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def key(row): return row['lane'],row['bounded'],row['turns'],row['payload_bytes']

def main():
    pairs=[]
    for pair in range(1,5):
        rows={side:json.loads((ROOT/'cost-r4'/f'cost-{pair}-{side}.stdout').read_text())['rows'] for side in ['baseline','candidate']}
        b={key(r):r for r in rows['baseline']};c={key(r):r for r in rows['candidate']}
        if b.keys()!=c.keys(): raise ValueError('row mismatch')
        for k in b:
            for field in ['full_bytes','next','floor','iterations','messages']:
                if b[k][field]!=c[k][field]: raise ValueError(f'oracle mismatch {pair} {k} {field}')
        pairs.append((b,c))
    results=[]
    for k in pairs[0][0]:
        base=[p[0][k] for p in pairs];candidate=[p[1][k] for p in pairs]
        cpu=[c['cpu_seconds']/b['cpu_seconds'] for b,c in zip(base,candidate)]
        allocation=[c['allocated_bytes']/b['allocated_bytes'] for b,c in zip(base,candidate)]
        per_call=lambda side,field:[r[field]/r['iterations'] for r in side]
        row=dict(zip(['lane','bounded','turns','payload_bytes'],k))
        row.update({'iterations':base[0]['iterations'],'messages':base[0]['messages'],
            'cpu_ratio_pairs':cpu,'cpu_ratio_median':statistics.median(cpu),
            'cpu_change_percent':100*(statistics.median(cpu)-1),
            'allocation_ratio_pairs':allocation,'allocation_ratio_median':statistics.median(allocation),
            'baseline_cpu_microseconds_per_call_median':1e6*statistics.median(per_call(base,'cpu_seconds')),
            'candidate_cpu_microseconds_per_call_median':1e6*statistics.median(per_call(candidate,'cpu_seconds')),
            'baseline_allocated_bytes_per_call_median':statistics.median(per_call(base,'allocated_bytes')),
            'candidate_allocated_bytes_per_call_median':statistics.median(per_call(candidate,'allocated_bytes')),
            'baseline_encoder_calls':base[0]['encoder_calls'],'candidate_encoder_calls':candidate[0]['encoder_calls'],
            'baseline_encoded_bytes':base[0]['encoded_bytes'],'candidate_encoded_bytes':candidate[0]['encoded_bytes'],
            'full_bytes':base[0]['full_bytes'],'next':base[0]['next'],'floor':base[0]['floor']})
        for field in ['encoder_calls','encoded_bytes','full_bytes','next','floor']:
            if len({r[field] for r in base})!=1 or len({r[field] for r in candidate})!=1: raise ValueError('unstable oracle')
        results.append(row)
    files=[ROOT/'compare.ml',ROOT/'run_native.py',ROOT/'run_checks.py',ROOT/'analyze.py',
           ROOT/'source-review-r1.json',ROOT/'review-response-r1.json']
    for directory in ['native-r1','checks-r2','checks-r3','cost-r4']:
        files += [p for p in (ROOT/directory).iterdir() if p.suffix in ['.json','.stdout','.stderr']]
    manifest={str(p.relative_to(ROOT)):sha(p) for p in files}
    analysis={'base':'c97d0f9b850c812885a7f89a4fcdc280a6738416',
        'source_commit':'8509f161b1d498fbc0001c3fdfae047b012de3b6',
        'scope':'Owned post-windowed shrink calculation only; complete actual baseline/candidate Window and canonical codec. Both baseline lanes unconditionally fold full bytes; bounded declared capacity is2000000, target1000000; unbounded target isfull/2. No full projection, CPU job scheduling, provider or runtime measured.',
        'pairs':4,'process_order':[['baseline','candidate'],['candidate','baseline'],['baseline','candidate'],['candidate','baseline']],
        'processes':8,'rows_per_process':16,'total_measured_rows':128,
        'method':'Same linked executable selects mode in fresh process, 3 warmups/row then one untimed full_major. Fixed lane,bound,size row order. CPU=Sys.time, wall=gettimeofday, allocation=Gc.allocated_bytes, Gc.counters deltas; loop/clock/sink costs included. Encoder counters sampled separately before timed loop. Ratio is median of four paired candidate/baseline ratios; per-side medians are separate statistics. No weighting or aggregate server speedup.',
        'controls':'Full bytes,next,floor,iterations,messages equal for all64 paired rows. Call/encoded-byte counts and outputs stable across4pairs per side.',
        'differential':json.loads((ROOT/'cost-r4/differential.run.stdout').read_text()),
        'superseded':'native-r1 suite failed7 preexisting fatal warning4s; checks-r2 suite failed3 warning8s from incomplete explicit enumeration; final checks-r3 maintained41PASS. r3 cost bounded baseline omitted actual outer fold and2 intended pinned marker fixture rows had Conversation origin; all r3 cost results superseded by cost-r4 corrected driver and true Agent_instruction marker fixtures. Raw failed/superseded captures retained.',
        'limits':['Fresh renamed actual complete units and prebuilt dependency archives, not original-name full ABI/dependency rebuild. Mutable prebuilt inputs have capture-time hashes, not verified full source-build provenance.',
          'Finished measured_history releases source message/payload under maintained weak-root test; transient tuples/arrays add metadata work and were not a peak-memory/RSS measurement.',
          'No operational workload distribution, actual provider retry, installed candidate, live totalCPU/RSS or original stalled-request recovery proof.'],
        'rows':results,'evidence_sha256':manifest}
    (ROOT/'analysis.json').write_text(json.dumps(analysis,indent=2)+'\n')
    for r in results:
        print(r['lane'],'bounded' if r['bounded'] else 'unbounded',r['turns'],r['payload_bytes'],
            'CPU%% %.2f'%r['cpu_change_percent'],'allocratio %.6f'%r['allocation_ratio_median'])

if __name__=='__main__': main()
