"""Execute exact pure official projection source; not Host/SDK/vendor execution."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import argparse
parser=argparse.ArgumentParser()
parser.add_argument("--repo", type=Path, required=True)
args=parser.parse_args()
ROOT = args.repo.resolve()
OUT = Path(__file__).resolve().parent
BASE = "2be9d21697fb4c9da9aafd769f5fa691bae2e757"
records = []


def read(path):
    return (ROOT / path).read_text()


def extract(path, start, end):
    text = read(path)
    return text[text.index(start):text.index(end)]


types = read("packages/agent_core/lib/llm_provider/types.ml")
types = (types[types.index("type role ="):types.index("(** {1 Tool Types} *)")]
         + types[types.index("(** Tool execution outcome types. *)"):types.index("(** Exact producer binding")]
         + types[types.index("type message_origin ="):types.index("module Message_value =")])

import re

def bounded(text,start,end):
    return text[text.index(start):text.index(end,text.index(start))]

PROMPT=read("config/prompts/keeper.md")
markers=list(re.finditer(r"^### ([a-z][a-z0-9_.]*)(?: \(vars:[^\n]*\))?$",PROMPT,re.M))
templates={}
for index,marker in enumerate(markers):
    if marker.group(1).startswith("world.active_goals."):
        end=markers[index+1].start() if index+1<len(markers) else len(PROMPT)
        templates["keeper."+marker.group(1)]=PROMPT[marker.end():end].strip()
registry=read("lib/prompt_registry/prompt_registry.ml")
renderer=(bounded(registry,"let template_variable_regex =","(** {1 In-memory Registry Storage} *)")
          + bounded(registry,"let render_template ?template_variables", "(** {1 Utility Functions} *)"))
name_lines=read("lib/prompt_registry/prompt_names.ml")
fixture_types=r"""
module Goal_phase=struct type t=Verifying|Awaiting_confirmation|Executing|Completed|Dropped|Paused of unit|Blocked of unit end
module Goal_store=struct
 type criterion=Yojson.Safe.t
 type unavailable={file:string;reason:string;mirror:string;reset_step:string}
 let criterion_to_yojson value=value
end
module Goal_measurement=struct type t=Yojson.Safe.t let to_yojson value=value end
module Goal_store_unavailable=struct
 let reason_to_string value=value
 let mirror_status_to_string value=value
 let reset_step_to_string value=value
end
"""

def producer(label):
    candidate=read("lib/keeper/keeper_unified_prompt.ml")
    # Reverse ONLY the two functional withdrawal repair hunks in the same current source.
    formatter_start=candidate.index("let format_active_goal_summaries =")
    at=candidate.index("  | Ok summaries ->",formatter_start)
    old=candidate[:at]+"  | Ok [] -> None\n"+candidate[at:]
    start=old.index("      (match observation.active_goals, active_goal_summaries with",old.index("let content_of :"))
    end=old.index("    (* 1b. Current task",start)
    old=old[:start]+"""      let source =
        match observation.active_goals, active_goal_summaries with
        | Error unavailable, _ | _, Some (Error unavailable) -> Error unavailable
        | Ok _, Some (Ok summaries) -> Ok summaries
        | Ok _, None -> Ok []
      in
      format_active_goal_summaries source
"""+old[end:]

    selected=old if label=="before" else candidate
    world=old if label=="unsafe_formatter_only" else selected
    row_source=bounded(selected,"type held_task_link =","let format_task_skills")
    fragment=bounded(selected,"let render_fragment key vars =","(* The diagnostic attached")
    error_vars=bounded(selected,"let goal_store_unavailable_fragment_vars", "let format_active_goal_summaries")
    formatter=bounded(selected,"let format_active_goal_summaries", "let build_system_prompt")
    start=world.index("    | Keeper_context_layers.Active_goals ->",world.index("let content_of :"))
    finish=world.index("    (* 1b. Current task",start)
    arm=world[start:finish].split("->",1)[1]
    table="["+";".join("("+json.dumps(k,ensure_ascii=False)+","+json.dumps(v,ensure_ascii=False)+")" for k,v in templates.items())+"]"
    code=("module Empty_goal_producer = struct\n"+fixture_types
          +"module Prompt_names=struct\n"+name_lines+"\nend\n"
          +"module Prompt_registry=struct\n"+renderer+"\nlet templates="+table+"\n"
          +"let render_prompt_template key vars = match List.assoc_opt key templates with None -> failwith \\\"unregistered fixture template\\\" | Some template -> render_template ~template ~vars ()\nend\n"
          +fragment+"\n"+row_source+"\n"+error_vars+"\n"+formatter+"\n"
          +"type observed_goals={active_goals:(string list,Goal_store.unavailable) result}\n"
          +"let world_goal ~(observation:observed_goals) ~(active_goal_summaries:(goal_summary list,Goal_store.unavailable) result option) =\n"+arm+"\nend\n")
    code=code.replace('\\\"','"')
    records.append({"variant":label,"source":"actual unified formatter/Goal rows/world Active_goals arm/render_fragment and actual registry renderer; fixture registry table from exact keeper.md bytes; Goal data types are fixture stand-ins", "sha256":hashlib.sha256(code.encode()).hexdigest(),"formatter_sha256":hashlib.sha256(formatter.encode()).hexdigest(),"world_arm_sha256":hashlib.sha256(arm.encode()).hexdigest(),"template_source_sha256":hashlib.sha256(PROMPT.encode()).hexdigest()})
    return code

probe_template = '\n__PRODUCER__\n\nmodule H = Projection\nmodule A = Keeper_context_assembly\nmodule P = Prompt_block_id\nmodule Link = Keeper_context_submission_link\nmodule W = Runtime_official_client_write\nlet checks = ref 0\nlet check label okay = if not okay then failwith label else\n  (incr checks; Printf.printf "PASS %s\\n" label)\nlet binding piece = Link.binding_to_json ~slot:W.Whole_write piece (W.raw (Link.text piece))\nlet () =\n  let issued text = A.assemble ~dynamic_context_partition:None\n      ~existing_extra_system_context:None ~blocks:[P.Dynamic_context,"TASK GATE LANE"]\n    |> A.with_system_observations ~base_text:"BASE" ~observations:(Option.to_list (Option.map (fun text -> A.Active_goals text) text)) in\n  let messages a = match a.A.extra_system_context with None -> []\n    | Some text -> [H.extra_system_context_message text] in\n  let summary : Empty_goal_producer.goal_summary =\n    { summary_goal_id="goal-A"; summary_title="authoritative Goal A";\n      summary_phase=None; summary_criterion=None; summary_review_note=None;\n      summary_measurement=Ok None; summary_held_task_link=Not_served_by_held_task } in\n  let before = issued (Empty_goal_producer.format_active_goal_summaries (Ok [summary])) in\n  let after = issued (Empty_goal_producer.format_active_goal_summaries\n      (Ok [{summary with summary_review_note=Some "a later retained observation"}])) in\n  let held = H.start_held_context ~composed_context:before (messages before) in\n  let result = H.resume_prompt ~goal:"OWNER" ~held ~composed_context:after (messages after) in\n  let open Yojson.Safe.Util in\n  if Sys.argv.(1) = "baseline" then (\n    check "baseline drops the changed System Goal from Resume" (result.prompt = "OWNER");\n    check "baseline held set names no System Goal" (not (List.exists\n      (fun (item : Keeper_official_client_session_store.held_context) ->\n        item.context = Context_block P.Active_goals) held)))\n  else (\n    let text = Option.get (List.find_map (function A.Active_goals text -> Some text | A.Completion_authority _ -> None) (Option.get after.system_prompt).observations) in\n    check "changed Goal reaches a separate Resume User message"\n      (result.prompt = "USER:\\n" ^ H.encode_history_message (H.user_message text) ^ "\\n\\nOWNER");\n    check "Start names the Goal it sent through System" (List.exists\n      (fun (item : Keeper_official_client_session_store.held_context) ->\n        item.context = Context_block P.Active_goals) held);\n    check "same Goal does not accumulate in Resume history"\n      ((H.resume_prompt ~goal:"OWNER" ~held:result.held_context ~composed_context:after (messages after)).prompt = "OWNER");\n    check "existing non-Goal world stays held" (not (Astring.String.is_infix ~affix:"TASK" result.prompt));\n    let absent = issued None in\n    check "a new Goal after session Start is delivered"\n      ((H.resume_prompt ~goal:"OWNER" ~held:(H.start_held_context ~composed_context:absent (messages absent))\n        ~composed_context:after (messages after)).prompt = result.prompt);\n    check "Goal never becomes an extra-context source block" (not (List.mem_assoc P.Active_goals after.blocks));\n    let receipt = binding result.context_projection in\n    check "actual projected text matches its receipt slot" (member "status" receipt = `String "matched_completed_slot");\n    let proof = match receipt |> member "occurrences" |> to_list with\n      | [occurrence] -> member "source" occurrence | _ -> failwith "one Goal occurrence required" in\n    check "source proof names System" (member "source_carrier" proof = `String "system_prompt");\n    check "target proof names official Resume User" (member "target_carrier" proof = `String "official_resume_user_prompt");\n    let physical = Option.get after.system_prompt in\n    check "source proof hashes the actual System partition"\n      (member "sha256" (member "assembly" proof) = `String physical.partition.sha256);\n    let index = match member "source_span_indices" proof |> to_list with [i] -> to_int i | _ -> assert false in\n    let span = List.nth physical.partition.spans index in\n    check "selected raw System span is exactly the delivered Goal"\n      (String.sub physical.text span.offset span.bytes = text);\n    let same = H.resume_prompt ~goal:"OWNER" ~held:result.held_context ~composed_context:after (messages after) in\n    check "local held omission retains System-derived evidence"\n      (List.exists (fun proof -> member "source_carrier" proof = `String "system_prompt")\n        (binding same.context_projection |> member "omitted_held" |> to_list));\n    let stale = Link.encoded_system_observation ~target:Official_resume_user ~block:P.Active_goals ~assembly:(Some before) (H.user_message text) in\n    check "stale System issuer cannot prove new observation"\n      (binding stale |> member "issuer_attribution" |> member "status" = `String "unavailable");\n    let unknown = Empty_goal_producer.world_goal\n      ~observation:{active_goals=Ok ["goal-A"]} ~active_goal_summaries:None in\n    let unknown_delivery = H.resume_prompt ~goal:"OWNER" ~held\n        ~composed_context:(issued unknown) (messages (issued unknown)) in\n    check "known nonempty IDs without summary observation do not manufacture a clearance"\n      (unknown_delivery.prompt = "OWNER"\n       && member "occurrences" (binding unknown_delivery.context_projection) = `List []);\n    let absent_delivery = H.resume_prompt ~goal:"OWNER" ~held\n        ~composed_context:absent (messages absent) in\n    check "unobserved None does not assert an empty Goal set" (absent_delivery.prompt="OWNER");\n    let unavailable : Empty_goal_producer.Goal_store.unavailable =\n      {file="fixture-goals.json";reason="fixture_unreadable";mirror="not_used";reset_step="store_specific_review"} in\n    let unavailable_text = Empty_goal_producer.world_goal\n      ~observation:{active_goals=Error unavailable} ~active_goal_summaries:(Some (Ok [])) in\n    let error_delivery = H.resume_prompt ~goal:"OWNER" ~held\n        ~composed_context:(issued unavailable_text) (messages (issued unavailable_text)) in\n    check "unavailable source still has a distinct sourced Resume observation"\n      (unavailable_text <> Empty_goal_producer.format_active_goal_summaries (Ok [])\n       && List.length (binding error_delivery.context_projection |> member "occurrences" |> to_list)=1);\n    let unavailable_summaries=Empty_goal_producer.world_goal\n      ~observation:{active_goals=Ok []} ~active_goal_summaries:(Some (Error unavailable)) in\n    check "unavailable summaries never assert an authoritative empty Goal set" (unavailable_summaries=unavailable_text);\n    let empty = Empty_goal_producer.format_active_goal_summaries (Ok []) in\n    let cleared = issued empty in\n    let cleared_delivery = H.resume_prompt ~goal:"OWNER" ~held ~composed_context:cleared (messages cleared) in\n    let old_goal = List.find (fun (item : Keeper_official_client_session_store.held_context) ->\n      item.context = Context_block P.Active_goals) held in\n    let retained = List.exists (fun (item : Keeper_official_client_session_store.held_context) ->\n      item.context = old_goal.context && item.sha256 = old_goal.sha256) cleared_delivery.held_context in\n    let clear_binding = binding cleared_delivery.context_projection in\n    let occurrences = clear_binding |> member "occurrences" |> to_list in\n    Printf.printf "REMOVAL_ACTUAL prompt=%S retained_old_goal=%b source_occurrences=%d\\n"\n      cleared_delivery.prompt retained (List.length occurrences);\n    check "last Goal removal delivers an explicit current Goal clearance observation"\n      (List.exists (fun occurrence -> member "target_carrier" (member "source" occurrence)\n         = `String "official_resume_user_prompt") occurrences);\n    check "old nonempty Goal hash is retired after authoritative zero" (not retained);\n    let zero_text=Option.get empty in\n    let zero_system=Option.get cleared.system_prompt in\n    let clear_occurrence=List.hd occurrences in\n    let clear_source=member "source" clear_occurrence in\n    let clear_index=member "source_span_indices" clear_source |> to_list |> List.hd |> to_int in\n    let clear_span=List.nth zero_system.partition.spans clear_index in\n    check "clearance source hashes exact current System partition"\n      (member "sha256" (member "assembly" clear_source)=`String zero_system.partition.sha256\n       && String.sub zero_system.text clear_span.offset clear_span.bytes=zero_text);\n    check "clearance receipt targets the actual current Resume payload"\n      (member "status" clear_binding=`String "matched_completed_slot"\n       && cleared_delivery.prompt="USER:\\n" ^ H.encode_history_message (H.user_message zero_text) ^ "\\n\\nOWNER");\n    let zero_frame=`Assoc ["input",`List [`Assoc ["type",`String "text";"text",`String cleared_delivery.prompt]]] in\n    let zero_write=W.json_line (W.Fields ["input",W.turn_input]) zero_frame (Yojson.Safe.to_string zero_frame) in\n    check "clearance binds the actual JSON turn text write slot"\n      (Link.binding_to_json ~slot:(W.Turn_text 0) cleared_delivery.context_projection zero_write\n       |> member "status" = `String "matched_completed_slot");\n    let zero_again=H.resume_prompt ~goal:"OWNER" ~held:cleared_delivery.held_context\n        ~composed_context:cleared (messages cleared) in\n    check "unchanged authoritative zero does not accumulate Resume messages" (zero_again.prompt="OWNER");\n    let world_empty=Empty_goal_producer.world_goal\n      ~observation:{active_goals=Ok []} ~active_goal_summaries:None in\n    check "authoritative empty IDs and resolved empty summaries issue the same observation" (world_empty=empty);\n    let frame = `Assoc ["input", `List [`Assoc ["type",`String "text";"text",`String result.prompt]]] in\n    let payload = Yojson.Safe.to_string frame in\n    let write = W.json_line (W.Fields ["input",W.turn_input]) frame payload in\n    check "JSON turn-text slot binds the actual projection"\n      (Link.binding_to_json ~slot:(W.Turn_text 0) result.context_projection write |> member "status"\n       = `String "matched_completed_slot"));\n  Printf.printf "%d exact-source official Resume checks passed\\n" !checks\n'

with tempfile.TemporaryDirectory(prefix="masc-official-goal-source-") as temporary:
    directory = Path(temporary)
    sources = []

    def put(name, text, origin):
        (directory / name).write_text(text)
        sources.append(name)
        records.append({"compiled": name, "source": origin, "sha256": hashlib.sha256(text.encode()).hexdigest()})

    put("llm_provider.ml", "module Types = struct\n"+types+"\nend\n", "exact current role/content/metadata/message_origin/message fragments; schema and provider-reasoning types excluded")
    put("agent_core.ml", "module Types = Llm_provider.Types\n", "nominal alias port mirrors the actual Agent Core to Llm_provider Types identity")
    for module in ["lib/types/prompt_block_id", "lib/keeper/keeper_context_layers", "lib/keeper/keeper_context_assembly",
                   "lib/keeper/keeper_official_client_context_codec"]:
        for extension in [".mli", ".ml"]:
            path = module + extension
            put(Path(path).name, read(path), path)
    put("runtime_official_client_write.ml", extract("lib/runtime/runtime_official_client_write.ml", "type slot =", "let report ~label"), "exact pure write-receipt prefix, excludes effectful report")
    put("keeper_official_client_session_store.ml", extract("lib/keeper/keeper_official_client_session_store.ml", "type carried_context =", "type context_frontier ="), "exact carried/held type fragment")
    put("runtime_model_input_tail_window.ml", extract("lib/runtime/runtime_model_input_tail_window.ml", "let working_state_marker_key", "type budget_error ="), "exact metadata classifiers fragment")
    put("keeper_official_task_reference.ml", extract("lib/keeper/keeper_official_task_reference.ml", "let marker_key =", "let message ~current"), "exact task-reference classifier fragment")
    # These unrelated notice/log effects must not execute in this whole-block fixture.
    put("prompt_names.ml", 'let keeper_world_frame_unchanged_sections = ()\nlet keeper_world_frame_held_rows_sections = ()\n', "unexecuted notice key placeholders")
    put("prompt_registry.ml", 'let render_prompt_template _ _ = failwith "unexpected notice rendering"\n', "unreachable notice dependency")
    put("log.ml", 'module Keeper = struct let warn _ _ : unit = failwith "unexpected log effect" end\n', "unreachable log dependency")
    for extension in [".mli", ".ml"]:
        path = "lib/keeper/keeper_context_submission_link" + extension
        put(Path(path).name, read(path), path)
    outputs = []
    for label in ["before","unsafe_formatter_only","after"]:
        full=read("lib/keeper/keeper_official_client_context_projection.ml")
        probe=probe_template.replace("__PRODUCER__",producer(label))
        (directory / "probe.ml").write_text(probe)
        projection = full[full.index("let encode_history_message ="):full.index("let last_tool_results messages =")]
        (directory / "projection.ml").write_text(projection)
        built = subprocess.run(["ocamlfind", "ocamlc", "-package", "yojson,re.pcre,digestif.ocaml,astring,ppx_deriving_yojson,ppx_deriving.show",
                                "-w", "+4+32+69", "-linkpkg", *sources, "projection.ml", "probe.ml", "-o", "probe"], cwd=directory, capture_output=True, text=True)
        if built.returncode:
            (OUT / "compile-failure.txt").write_text(built.stdout+built.stderr)
            print(built.stdout + built.stderr)
            raise SystemExit(built.returncode)
        ran = subprocess.run([str(directory / "probe"), "repair"], cwd=directory, capture_output=True, text=True)
        outputs.append({"variant": label, "projection_sha256": hashlib.sha256(projection.encode()).hexdigest(),
                        "compile_exit": built.returncode, "compile_stderr": built.stderr, "run_exit": ran.returncode, "output": ran.stdout + ran.stderr})
        print(label + "\n" + ran.stdout + ran.stderr)
        expected=0 if label=="after" else 2
        if ran.returncode!=expected:
            raise SystemExit("unexpected variant outcome: "+label+" "+str(ran.returncode))
    (OUT / "independent-official-removal-check.json").write_text(json.dumps({"scope": "actual extracted formatter, full Goal row function, world Active_goals arm, registry template renderer and actual pure projection/codec/receipt; fixture registry resolution and Goal data type stand-ins; no Goal-store decoder/I/O, full Keeper assembly/Host/hooks/SDK/client/transport/provider/remote-retention proof",
        "candidate_head": subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(), "reverted_before_scope":"same current source, only formatter Ok[]->None and world Active_goals functional hunk reversed", "sources": records, "results": outputs}, indent=2) + "\n")
