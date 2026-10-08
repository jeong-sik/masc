from pathlib import Path
import subprocess,tempfile,json,hashlib,shutil,re,sys
wd=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();out=Path(tempfile.mkdtemp(prefix='masc-fusion-unicode-native-'));print(out)
cached=root/'_build/default/lib/fusion_core/.masc_fusion_core.objs'
basecmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-thread','-package','alcotest,yojson,ppx_deriving_yojson.runtime,uutf,uucp']
probe='''let () =
 let inputs = Yojson.Safe.from_file Sys.argv.(1) |> Yojson.Safe.Util.to_list in
 let results = List.map (fun json -> match Fusion_judge_parse.of_string (Yojson.Safe.to_string json) with
 | Ok synthesis -> `Assoc ["accepted",`Bool true;"resolved",`String synthesis.resolved_answer]
 | Error detail -> `Assoc ["accepted",`Bool false;"error",`String detail]) inputs in
 Yojson.Safe.to_file "results.json" (`List results);
 Yojson.Safe.to_file "schema.json" Fusion_judge_parse.output_schema
'''
points=list(range(9,14))+[0x20,0x85,0xa0,0x1680]+list(range(0x2000,0x200b))+[0x2028,0x2029,0x202f,0x205f,0x3000]
blanks=['']+[chr(n) for n in points]+[''.join(map(chr,points))]
cases=[]
for blank in blanks:
 for resolved,decision in [(blank,dict(kind='answer',answer='Supported')),('Supported',dict(kind='answer',answer=blank)),(blank,dict(kind='recommend',action='Act',rationale='Evidence')),('Supported',dict(kind='recommend',action=blank,rationale='Evidence')),('Supported',dict(kind='recommend',action='Act',rationale=blank))]:
  cases.append(dict(resolved_answer=resolved,decision=decision))
blank_count=len(cases)
for value in ['Supported','근거를 보존합니다.','\u00a0Supported\u3000','\u2003검증\u202f','😀']:
 cases.append(dict(resolved_answer=value,decision=dict(kind='answer',answer=value)))
cases.append(dict(resolved_answer='',decision=dict(kind='insufficient',missing=['evidence'])))
(out/'cases.json').write_text(json.dumps(cases,ensure_ascii=False))
source=(wd/'test/fusion_core/test_fusion.ml').read_text();start=source.index('let jdecision =');end=source.index('\n(*',source.index('let test_judge_rejects_lossy_collections',start));test_slice=source[start:end]
names=re.findall(r'^let (test_judge_\w+) \(\) =',test_slice,re.M)
consumer=(wd/'test/test_keeper_structured_output_schema.ml').read_text();helpers=consumer[consumer.index('let schema_member'):consumer.index('let has_no_response_format')];check=consumer[consumer.index('let test_fusion_judge_schema_uses_parser_wire_contract'):consumer.index('let test_librarian_claim_schema_is_closed')]
alias=next(line for line in (wd/'lib/keeper/keeper_structured_output_schema.ml').read_text().splitlines() if line.startswith('let fusion_judge_output_schema ='))
logs={}
for variant in ['baseline','candidate']:
 dest=out/variant;dest.mkdir();cmd=basecmd+['-I',str(dest),'-I',str(cached/'byte'),'-I',str(cached/'native')]
 def run(args):
  p=subprocess.run(args,cwd=dest,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  if p.returncode:raise RuntimeError(p.stdout)
  return p.stdout
 for ext in ['mli','ml']:
  rel='lib/fusion_core/fusion_judge_parse.'+ext
  (dest/('fusion_judge_parse.'+ext)).write_bytes((wd/rel).read_bytes() if variant=='candidate' else subprocess.check_output(['git','show','fe6964a5f55bd65db3bc2cdd96463fa2ee0e4f12:'+rel],cwd=root))
  run(cmd+['-c','fusion_judge_parse.'+ext])
 (dest/'probe.ml').write_text(probe)
 link=cmd+['-linkpkg',str(cached/'native/fusion_types.cmx'),'fusion_judge_parse.cmx']
 run(link+['probe.ml','-o','probe.exe']);run([str(dest/'probe.exe'),str(out/'cases.json')])
 results=json.loads((dest/'results.json').read_text());rejected=sum(not x['accepted'] for x in results[:blank_count]);print(variant,'blank rejected',rejected,'/',blank_count)
 logs[variant]=dict(blank_rejected=rejected,blank_total=blank_count)
 if variant=='candidate':
  assert rejected==blank_count
  assert all(x['accepted'] for x in results[blank_count:])
  for expected,actual in zip(cases[blank_count:],results[blank_count:]):assert expected['resolved_answer']==actual['resolved']
  tests='open Fusion_types\n'+test_slice+'\nlet () = Alcotest.run "Judge unicode contract" [("parse",['+';'.join('Alcotest.test_case '+json.dumps(n)+' `Quick '+n for n in names)+'])]\n'
  (dest/'judge_tests.ml').write_text(tests);run(link+['judge_tests.ml','-o','judge_tests.exe']);(out/'judge-tests.txt').write_text(run([str(dest/'judge_tests.exe')]))
  (dest/'consumer.ml').write_text('open Alcotest\nmodule Keeper_structured_output_schema = struct\n'+alias+'\nend\n'+helpers+check+'\nlet () = test_fusion_judge_schema_uses_parser_wire_contract (); print_endline "Consumer PASS"\n')
  run(link+['consumer.ml','-o','consumer.exe']);(out/'consumer.txt').write_text(run([str(dest/'consumer.exe')]))
node=r'''const fs=require('fs');const schema=JSON.parse(fs.readFileSync(process.argv[2]));const points=JSON.parse(fs.readFileSync(process.argv[3]));let count=0;function visit(x){if(x&&typeof x==='object'){if(typeof x.pattern==='string'){const re=new RegExp(x.pattern,'u');for(const p of points){if(re.test(String.fromCodePoint(p)))throw Error('schema accepts whitespace '+p);if(!re.test(String.fromCodePoint(p)+'검증'))throw Error('schema rejects content');}if(re.test(''))throw Error('schema accepts empty');count++;}for(const v of Object.values(x))visit(v)}}visit(schema);if(count!==5)throw Error('expected five constrained conclusion fields');console.log('PASS: five generated schema patterns reject all 25 Unicode White_Space characters and empty strings; preserve meaningful text');'''
(out/'check-pattern.cjs').write_text(node);(out/'whitespace.json').write_text(json.dumps(points));p=subprocess.run(['node',str(out/'check-pattern.cjs'),str(out/'candidate/schema.json'),str(out/'whitespace.json')],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);print(p.stdout);assert p.returncode==0;(out/'schema-pattern.txt').write_text(p.stdout)
logs['parser_tests']=len(names);logs['schema_pattern_fields']=5;logs['meaningful_and_insufficient']=len(cases)-blank_count
(out/'summary.json').write_text(json.dumps(logs,indent=2)+'\n')
manifest={'scope':'actual native decoder plus source-sliced parser and schema consumer tests; real ECMAScript regex over generated schema; cached Fusion_types dependency; no full suites or provider run','baseline':'fe6964a5f55bd65db3bc2cdd96463fa2ee0e4f12','source_sha256':{file:hashlib.sha256((wd/file).read_bytes()).hexdigest() for file in ['lib/fusion_core/fusion_judge_parse.ml','lib/fusion_core/fusion_judge_parse.mli','lib/fusion_core/dune','config/prompts/fusion.judge.md','test/fusion_core/test_fusion.ml','lib/keeper/keeper_structured_output_schema.ml','test/test_keeper_structured_output_schema.ml']}}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(logs)
