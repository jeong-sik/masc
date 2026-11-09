#!/usr/bin/env python3
"""Alternate pinned native binaries; each sample owns a synthetic server/PTy."""
import argparse
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import time

parser=argparse.ArgumentParser()
parser.add_argument('--before',type=Path,required=True)
parser.add_argument('--after',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--messages',type=int,default=800)
parser.add_argument('--pairs',type=int,default=5)
parser.add_argument('--conditions',nargs='+',default=['typing','pageup','pagedown','wheelup','wheeldown'])
parser.add_argument('--type-gap',type=float,default=.05)
parser.add_argument('--scroll-gap',type=float,default=.02)
a=parser.parse_args()
source=Path(__file__).with_name('active_probe.py')
spec=importlib.util.spec_from_file_location('mixed_probe',source)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
root=a.output.resolve();root.mkdir(parents=True,exist_ok=False)
(root/'mixed_probe.py').write_bytes(source.read_bytes())
order=[]
for pair in range(a.pairs):
    labels=['before','after'] if pair%2==0 else ['after','before']
    conditions=a.conditions
    conditions=conditions[pair%len(conditions):]+conditions[:pair%len(conditions)]
    for condition in conditions:
        for label in labels:
            run=root/f'pair-{pair:02d}-{label}-{condition}'
            options=SimpleNamespace(output=run,exe=getattr(a,label).resolve(),messages=a.messages,
                                    lines=8,type_gap=a.type_gap,scroll_gap=a.scroll_gap,profile=False,
                                    alloc=False,text='abcdefghijklmnopqrstuvwxyz012345',verify_submit=False)
            print(json.dumps({'pair':pair,'label':label,'condition':condition,'started':time.monotonic()}),flush=True)
            m.run(options,condition)
            order.append({'pair':pair,'label':label,'condition':condition,'result':str(run/condition/'result.json')})
            (root/'order.json').write_text(json.dumps(order,indent=2))
print('All native observations finished.',flush=True)
