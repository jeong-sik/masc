#!/usr/bin/env python3
"""Compare original/candidate preparation control flow with deterministic renderer ports."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',type=Path,required=True)
p.add_argument('--baseline',required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();root=a.source_root.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
path='lib/keeper/keeper_librarian_runtime.ml'
before=subprocess.check_output(['git','show',a.baseline+':'+path],cwd=root,text=True)
after=(root/path).read_text()
def between(s,start,end): return s[s.index(start):s.index(end,s.index(start))]
canonical=(root/'lib/lane_addon/lane_addon_json.ml').read_text()
prefix='''open Result.Syntax
module Prompt_registry = struct
 type source = Override | File | Missing
 type prompt_resolution = {source:source;effective:string;override_value:string option;
   file_value:string option;file_exists:bool;has_override:bool}
end
module Keeper_librarian = struct type input={payload:string;working_context:string} end
module Keeper_librarian_context = struct let empty="" end
module Keeper_librarian_unread = struct
 type t=string
 let list_to_json xs=`List (List.map (fun x -> `String x) xs)
end
module Lane_addon_action = struct
'''+canonical+'''end
module Keeper_structured_output_schema = struct
 let librarian_current_output_schema=`Assoc ["type",`String "object"]
 let librarian_continuity_output_schema=`Assoc ["type",`String "string"]
end
type turn_input_prompts={working_context_input:Prompt_registry.prompt_resolution;
 turn_inputs:Prompt_registry.prompt_resolution}
let materializations=ref 0
'''
renderer='''
let durable_substitutions ?continuity ~(policy:durable_policy) ~rule_prompt ~turn_prompts ~prompt
    (source_input:Keeper_librarian.input) =
 incr materializations;
 let payload=Yojson.Safe.to_string (`Assoc ["input",`String source_input.payload;
   "limit",`Int policy.facts_max_bytes;"source",`List (List.map (fun x -> `String x) policy.facts_source_lines)]) in
 let continuity=match continuity with None -> "" | Some x -> Yojson.Safe.to_string x in
 let variables=["input",payload;"continuity",continuity] in
 let rendered=if prompt.Prompt_registry.effective="" then "" else
   prompt.effective^turn_prompts.turn_inputs.effective^turn_prompts.working_context_input.effective^payload^continuity in
 Ok (rule_prompt.Prompt_registry.effective,variables,rendered)
'''
wrapper='''
let resolution text : Prompt_registry.prompt_resolution =
 {source=Override;effective=text;override_value=Some text;file_value=None;file_exists=false;has_override=true}
let policy={facts_max_bytes=4096;facts_source_lines=["source memory"];category_cap=5;facts_per_category_cap=4}
let args={Keeper_librarian.payload="completed observation: \\"quoted\\"\\n한글";working_context=""}
let rule_prompt=resolution "rule" and prompt=resolution "body"
let turn_prompts={working_context_input=resolution "context";turn_inputs=resolution "turn"}
let restore (p:durable_preparation)=restore_durable_preparation ~source_input:p.source_input
 ~parsing_now:p.parsing_now ~policy:p.policy ~rule_prompt:p.rule_prompt ~turn_prompts:p.turn_prompts
 ~prompt:p.prompt ~output_schema:p.output_schema
let must = function Ok x -> x | Error e -> failwith e
let prepared ()=restore_durable_preparation ~source_input:args ~parsing_now:123. ~policy ~rule_prompt
 ~turn_prompts ~prompt ~output_schema:Keeper_structured_output_schema.librarian_current_output_schema |> must
let shape (p:durable_preparation)=Yojson.Safe.to_string (`Assoc [
 "rendered",`String p.rendered_prompt;"variables",`List (List.map (fun (k,v)->`List [`String k;`String v]) p.variables);
 "schema",p.output_schema;"input",`String p.source_input.payload])
let outcome f = match f () with Ok p -> "ok:"^shape p | Error e -> "error:"^e
let fields p = [p;{p with parsing_now=Float.nan};{p with parsing_now=(-1.)};
 {p with policy={p.policy with category_cap=0}};
 {p with rule_prompt={p.rule_prompt with effective="unbound"}};
 {p with turn_prompts={p.turn_prompts with turn_inputs={p.turn_prompts.turn_inputs with source=Prompt_registry.Missing}}};
 {p with prompt={p.prompt with effective="unbound"}};
 {p with prompt=resolution ""};{p with rule_prompt=resolution ""};
 {p with output_schema=`Bool true};{p with variables=["invented","unbound"]};
 {p with rendered_prompt=p.rendered_prompt^"changed"};
 {p with source_input={p.source_input with payload="different source"}}]
let check_cases () =
 let p=prepared () in
 let ordinary=List.concat_map (fun p -> [outcome (fun () -> restore p);
   (match validate_durable_preparation p with Ok () -> "valid" | Error e -> "invalid:"^e)]) (fields p) in
 let context={previous_state=Some "carried state";unread_messages=["not consumed"]} in
 let restore_step ~context ~source_input ~output_schema=restore_durable_step_preparation
   ~context ~source_input ~parsing_now:p.parsing_now ~policy:p.policy ~rule_prompt:p.rule_prompt
   ~turn_prompts:p.turn_prompts ~prompt:p.prompt ~output_schema in
 let result x=match x with Ok step -> "ok:"^shape step.preparation | Error e -> "error:"^e in
 let schema=Keeper_structured_output_schema.librarian_continuity_output_schema in
 let step=restore_step ~context ~source_input:p.source_input ~output_schema:schema |> must in
 ordinary@[result (Ok step);
   result (restore_step ~context ~source_input:{args with working_context="not empty"} ~output_schema:schema);
   result (restore_step ~context ~source_input:args ~output_schema:`Null);
   (match validate_durable_step_preparation {step with context={context with previous_state=Some "changed"}} with
    | Ok () -> "valid" | Error e -> "invalid:"^e)]
let benchmark () =
 let p=prepared () in let p={p with source_input={args with payload=String.make 12_000_000 'x'}} in
 Gc.full_major ();materializations:=0;
 let cpu=Sys.time () and allocated=Gc.allocated_bytes () in
 let result=restore p |> must in
 let cpu=Sys.time ()-.cpu and allocated=Gc.allocated_bytes ()-.allocated in
 ignore (Sys.opaque_identity result);
 `Assoc ["materializations",`Int !materializations;"cpu_s",`Float cpu;"allocated_bytes",`Float allocated]
'''
def module(name,source):
    validation=between(source,'let validate_resolution','(* This is an admission check,')
    start=validation.index('let durable_substitutions')
    end=validation.index('let check_durable_',start)
    validation=validation[:start]+validation[end:]
    return 'module '+name+' = struct\n'+between(source,'type durable_policy =','type admission_policy =')+renderer+validation+between(source,'type durable_step_context =','(* A floor step reads the input')+wrapper+'\nend\n'
harness='''let () =
 let old=Before.check_cases () and fresh=After.check_cases () in
 if old<>fresh then failwith "frozen validation/rendering outcomes differ";
 print_endline (Yojson.Safe.to_string (`Assoc ["matching_cases",`Int (List.length old);
  "before",Before.benchmark ();"after",After.benchmark ()]))
'''
(out/'probe.ml').write_text(prefix+module('Before',before)+module('After',after)+harness)
cmd=['ocamlfind','ocamlopt','-linkpkg','-package','yojson','-w','+4+8','-warn-error','+4+8','probe.ml','-o','probe']
r=subprocess.run(cmd,cwd=out,capture_output=True,text=True);(out/'compile.stderr').write_text(r.stderr)
if r.returncode: print(r.stderr);raise SystemExit(r.returncode)
r=subprocess.run([str(out/'probe')],cwd=out,capture_output=True,text=True);(out/'run.stderr').write_text(r.stderr)
if r.returncode: print(r.stderr);raise SystemExit(r.returncode)
result=json.loads(r.stdout);result.update({'baseline':a.baseline,'before_sha256':hashlib.sha256(before.encode()).hexdigest(),
 'after_sha256':hashlib.sha256(after.encode()).hexdigest(),'limits':['Runtime preparation control flow is source-extracted. Renderer/input/schema ports are deterministic fixtures, not production rendering or full input types.','Public record validation, restore/floor outcomes and invocation counts only; no provider/store/preflight/process performance is proved.']})
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
