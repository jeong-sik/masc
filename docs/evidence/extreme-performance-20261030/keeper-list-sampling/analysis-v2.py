from pathlib import Path
import json,re,hashlib,collections
root=Path.cwd()
for population in (2,300):
 run=root/f'artifacts/extreme-perf-20261030/native-tui-profile{population}-v1'
 observation=json.loads((run/'tui-observer/observation.json').read_text())
 capture=run/'tui-observer/native-stacks.txt'
 report=capture.read_text()
 graph_offset=report[:report.index('Call graph:\n')+len('Call graph:\n')].count('\n')
 graph=report.split('Call graph:\n',1)[1].split('Total number in stack',1)[0]
 records=[];thread=None
 for number,line in enumerate(graph.splitlines(),1):
  match=re.fullmatch(r'([ +!:\|]+)([0-9]+) (.+)',line)
  if not match:continue
  prefix,count,symbol=match.groups();count=int(count)
  if symbol.startswith('Thread_'):
   thread=symbol
  records.append({'call_graph_relative_line':number,'report_line':graph_offset+number,'prefix_width':len(prefix),'count':count,'symbol':symbol,'thread':thread})
 main=next(row for row in records if row['prefix_width']==4 and 'com.apple.main-thread' in row['symbol'])
 named_prefixes=['camlMasc_tui_types$keeper_reading_', 'camlMasc_tui_keeper_control$liveness_of_roster_',
                 'camlMasc_tui_types$selected_keeper_', 'camlDune__exe__Masc_tui_render_keepers$render_keeper_list_']
 named={prefix:{'sample_occurrences':sum(row['count'] for row in records if row['thread']==main['symbol'] and row['symbol'].startswith(prefix)),
                'occurrences':[row for row in records if row['thread']==main['symbol'] and row['symbol'].startswith(prefix)]} for prefix in named_prefixes}
 frames=[json.loads(line) for line in (run/'tui-observer/frame-timing.txt').read_text().splitlines() if line.startswith('{')]
 durations=sorted(int(row['elapsed_ns']) for row in frames if row.get('schema')=='masc.tui.frame.v2' and row['phase']=='build' and row['surface']=='keeper-list')
 def quantile(q):return durations[int(q*(len(durations)-1)+.5)]
 durable=json.loads((run/'durable-operations.json').read_text());durable_rows=[row for entry in durable for row in entry['rows']]
 terminal=json.loads((run/'terminal.json').read_text())['operations']
 failure=json.loads((run/'failure.json').read_text()) if (run/'failure.json').exists() else None
 result={'scope':'Native source 529 profile with stack-sampler overhead. Inclusive main-thread stack sample occurrences are not exclusive CPU, call counts, loaded Keeper cardinality or uninstrumented latency. Tail-call/unwind ancestry does not bind the named samples to a specific render, Build or eliminated duplicate call. Cleanup cancels live turns; post-shutdown store states are separate from settlement API receipts.',
 'analyzer_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
 'population':population,'capture_qualified':observation['capture_qualified'],'profiler':observation['profiler'],
 'main_thread_sample_count':main['count'],'named_inclusive_sample_occurrences':named,
 'keeper_list_builds':{'count':len(durations),'p50_ns':str(quantile(.5)),'p95_ns':str(quantile(.95)),'max_ns':str(max(durations))},
 'post_shutdown_store_states':dict(collections.Counter(row['state'] for row in durable_rows)),
 'post_shutdown_store_failure_kinds':dict(collections.Counter(str(row['failure_kind']) for row in durable_rows)),
 'settlement_api_terminal_receipts':len(terminal),'failure':failure,'workload_success':(run/'summary.json').exists() and failure is None,
 'inputs':{str(path.relative_to(run)):hashlib.sha256(path.read_bytes()).hexdigest() for path in [capture,run/'tui-observer/observation.json',run/'tui-observer/frame-timing.txt',run/'durable-operations.json',run/'terminal.json',run/'cleanup.json']}}
 target=run.parent/(run.name+'.analysis-v2.json')
 with target.open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
 print({key:value for key,value in result.items() if key not in ['inputs','named_inclusive_sample_occurrences']})
 print({key:value['sample_occurrences'] for key,value in named.items()})
