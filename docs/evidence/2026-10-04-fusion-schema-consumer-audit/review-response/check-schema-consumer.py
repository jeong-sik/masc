from pathlib import Path
import subprocess,tempfile,json,hashlib,shutil,sys
wd=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();out=Path(tempfile.mkdtemp(prefix='masc-schema-loop-native-'));print('Output:',out)
cached=root/'_build/default/lib/fusion_core/.masc_fusion_core.objs'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-thread','-package','alcotest,yojson,ppx_deriving_yojson.runtime','-I',str(out),'-I',str(cached/'byte'),'-I',str(cached/'native')]
def run(args):
 r=subprocess.run(args,cwd=out,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r.returncode:raise RuntimeError(r.stdout)
 return r.stdout
for ext in ['mli','ml']:
 shutil.copy2(wd/'lib/fusion_core'/('fusion_judge_parse.'+ext),out/('fusion_judge_parse.'+ext));run(cmd+['-c','fusion_judge_parse.'+ext])
mutation=r'''module Actual = Fusion_judge_parse
let remove key = function `Assoc fields -> `Assoc (List.remove_assoc key fields) | _ -> failwith "object required"
let map key f = function `Assoc fields -> `Assoc (List.map (fun (k,v)->k, if k=key then f v else v) fields) | _ -> failwith "object required"
let alter mode schema = map "oneOf" (function
 | `List (first::rest) -> `List ((match mode with
   | "missing-type" -> map "properties" (map "resolved_answer" (remove "type")) first
   | "missing-closedness" -> remove "additionalProperties" first
   | "real" -> first | _ -> failwith "unknown probe case")::rest)
 | _ -> failwith "branches required") schema
module Fusion_judge_parse = struct include Actual let output_schema = alter Sys.argv.(1) Actual.output_schema end
'''
source=(wd/'test/test_keeper_structured_output_schema.ml').read_text()
alias=next(line for line in (wd/'lib/keeper/keeper_structured_output_schema.ml').read_text().splitlines() if line.startswith('let fusion_judge_output_schema ='))
for name,text in [('before',subprocess.check_output(['git','show','2da38fc536be7ee9373edc5f3e06113d876bf1c8:test/test_keeper_structured_output_schema.ml'],cwd=wd,text=True)),('after',source)]:
 helpers=text[text.index('let schema_member'):text.index('let has_no_response_format')]
 test=text[text.index('let test_fusion_judge_schema_uses_parser_wire_contract'):text.index('let test_librarian_claim_schema_is_closed')]
 program='open Alcotest\n'+mutation+'module Keeper_structured_output_schema = struct\n'+alias+'\nend\n'+helpers+test+'\nlet () = try test_fusion_judge_schema_uses_parser_wire_contract (); print_endline "accepted" with _ -> print_endline "rejected"\n'
 (out/(name+'.ml')).write_text(program)
 run(cmd+['-linkpkg',str(cached/'native/fusion_types.cmx'),'fusion_judge_parse.cmx',name+'.ml','-o',name+'.exe'])
 results={}
 for mode in ['real','missing-type','missing-closedness']:
  log=run([str(out/(name+'.exe')),mode]);(out/(name+'-'+mode+'.log')).write_text(log);results[mode]=log.strip().splitlines()[-1]
 (out/(name+'.json')).write_text(json.dumps(results,indent=2)+'\n');print(name,results)
 assert results==({'real':'accepted','missing-type':'accepted','missing-closedness':'accepted'} if name=='before' else {'real':'accepted','missing-type':'rejected','missing-closedness':'rejected'})
manifest=dict(scope='unchanged source-sliced Fusion consumer test and exact production alias; real compiled Judge schema plus two synthetic schema faults; not full Keeper schema suite',source_sha256={str(p):hashlib.sha256((wd/p).read_bytes()).hexdigest() for p in map(Path,['lib/fusion_core/fusion_judge_parse.ml','lib/fusion_core/fusion_judge_parse.mli','lib/keeper/keeper_structured_output_schema.ml','test/test_keeper_structured_output_schema.ml'])})
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(out)
