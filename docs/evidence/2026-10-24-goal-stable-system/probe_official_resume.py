"""Execute exact pure official projection source; not Host/SDK/vendor execution."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BASE = "3badb88117794510dac576bf3fc34f0336e17d8a"
records = []


def read(path):
    return (ROOT / path).read_text()


def extract(path, start, end):
    text = read(path)
    return text[text.index(start):text.index(end)]


types = read("packages/agent_core/lib/llm_provider/types.ml")
types = (types[types.index("type role ="):types.index("(** {1 Tool Types} *)")]
         + types[types.index("(** Tool execution outcome types. *)"):types.index("(** Exact producer binding")]
         + types[types.index("type message ="):types.index("module Message_value =")])
probe = r'''
module H = Projection
module A = Keeper_context_assembly
module P = Prompt_block_id
module Link = Keeper_context_submission_link
module W = Runtime_official_client_write
let checks = ref 0
let check label okay = if not okay then failwith label else
  (incr checks; Printf.printf "PASS %s\n" label)
let binding piece = Link.binding_to_json ~slot:W.Whole_write piece (W.raw (Link.text piece))
let () =
  let issued text = A.assemble ~dynamic_context_partition:None
      ~existing_extra_system_context:None ~blocks:[P.Dynamic_context,"TASK GATE LANE"]
    |> A.with_goal_system_prompt ~base_text:"BASE" ~goal_text:text in
  let messages a = match a.A.extra_system_context with None -> []
    | Some text -> [H.extra_system_context_message text] in
  let before = issued (Some "GOAL rev1 measure0/3") in
  let after = issued (Some "GOAL rev2 measure1/4\n관측 \"reported_only\"") in
  let held = H.start_held_context ~composed_context:before (messages before) in
  let result = H.resume_prompt ~goal:"OWNER" ~held ~composed_context:after (messages after) in
  let open Yojson.Safe.Util in
  if Sys.argv.(1) = "baseline" then (
    check "baseline drops the changed System Goal from Resume" (result.prompt = "OWNER");
    check "baseline held set names no System Goal" (not (List.exists
      (fun (item : Keeper_official_client_session_store.held_context) ->
        item.context = Context_block P.Active_goals) held)))
  else (
    let text = Option.get (Option.get after.system_prompt).goal_text in
    check "changed Goal reaches a separate Resume User message"
      (result.prompt = "USER:\n" ^ H.encode_history_message (H.user_message text) ^ "\n\nOWNER");
    check "Start names the Goal it sent through System" (List.exists
      (fun (item : Keeper_official_client_session_store.held_context) ->
        item.context = Context_block P.Active_goals) held);
    check "same Goal does not accumulate in Resume history"
      ((H.resume_prompt ~goal:"OWNER" ~held:result.held_context ~composed_context:after (messages after)).prompt = "OWNER");
    check "existing non-Goal world stays held" (not (Astring.String.is_infix ~affix:"TASK" result.prompt));
    let absent = issued None in
    check "a new Goal after session Start is delivered"
      ((H.resume_prompt ~goal:"OWNER" ~held:(H.start_held_context ~composed_context:absent (messages absent))
        ~composed_context:after (messages after)).prompt = result.prompt);
    check "Goal never becomes an extra-context source block" (not (List.mem_assoc P.Active_goals after.blocks));
    let receipt = binding result.context_projection in
    check "actual projected text matches its receipt slot" (member "status" receipt = `String "matched_completed_slot");
    let proof = match receipt |> member "occurrences" |> to_list with
      | [occurrence] -> member "source" occurrence | _ -> failwith "one Goal occurrence required" in
    check "source proof names System" (member "source_carrier" proof = `String "system_prompt");
    check "target proof names official Resume User" (member "target_carrier" proof = `String "official_resume_user_prompt");
    let physical = Option.get after.system_prompt in
    check "source proof hashes the actual System partition"
      (member "sha256" (member "assembly" proof) = `String physical.partition.sha256);
    let index = match member "source_span_indices" proof |> to_list with [i] -> to_int i | _ -> assert false in
    let span = List.nth physical.partition.spans index in
    check "selected raw System span is exactly the delivered Goal"
      (String.sub physical.text span.offset span.bytes = text);
    let same = H.resume_prompt ~goal:"OWNER" ~held:result.held_context ~composed_context:after (messages after) in
    check "local held omission retains System-derived evidence"
      (List.exists (fun proof -> member "source_carrier" proof = `String "system_prompt")
        (binding same.context_projection |> member "omitted_held" |> to_list));
    let stale = Link.encoded_system_goal ~assembly:(Some before) (H.user_message text) in
    check "stale System issuer cannot prove new observation"
      (binding stale |> member "issuer_attribution" |> member "status" = `String "unavailable");
    let frame = `Assoc ["input", `List [`Assoc ["type",`String "text";"text",`String result.prompt]]] in
    let payload = Yojson.Safe.to_string frame in
    let write = W.json_line (W.Fields ["input",W.turn_input]) frame payload in
    check "JSON turn-text slot binds the actual projection"
      (Link.binding_to_json ~slot:(W.Turn_text 0) result.context_projection write |> member "status"
       = `String "matched_completed_slot"));
  Printf.printf "%d exact-source official Resume checks passed\n" !checks
'''

with tempfile.TemporaryDirectory(prefix="masc-official-goal-source-") as temporary:
    directory = Path(temporary)
    sources = []

    def put(name, text, origin):
        (directory / name).write_text(text)
        sources.append(name)
        records.append({"compiled": name, "source": origin, "sha256": hashlib.sha256(text.encode()).hexdigest()})

    put("agent_core.ml", "module Types = struct\n" + types + "\nend\n", "exact role/content/metadata/message fragments; schema and provider-reasoning types excluded")
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
    (directory / "probe.ml").write_text(probe)
    outputs = []
    for label, full in [("baseline", subprocess.check_output(["git", "show", BASE + ":lib/keeper/keeper_official_client_context_projection.ml"], cwd=ROOT, text=True)),
                        ("repair", read("lib/keeper/keeper_official_client_context_projection.ml"))]:
        projection = full[full.index("let encode_history_message ="):full.index("let last_tool_results messages =")]
        (directory / "projection.ml").write_text(projection)
        built = subprocess.run(["ocamlfind", "ocamlc", "-package", "yojson,digestif.ocaml,astring,ppx_deriving_yojson,ppx_deriving.show",
                                "-w", "+4+32+69", "-linkpkg", *sources, "projection.ml", "probe.ml", "-o", "probe"], cwd=directory, capture_output=True, text=True)
        if built.returncode:
            print(built.stdout + built.stderr)
            raise SystemExit(built.returncode)
        ran = subprocess.run([str(directory / "probe"), label], cwd=directory, capture_output=True, text=True)
        outputs.append({"variant": label, "projection_sha256": hashlib.sha256(projection.encode()).hexdigest(),
                        "compile_exit": built.returncode, "compile_stderr": built.stderr, "run_exit": ran.returncode, "output": ran.stdout + ran.stderr})
        print(label + "\n" + ran.stdout + ran.stderr)
        if ran.returncode:
            raise SystemExit(ran.returncode)
    (OUT / "official-resume-check.json").write_text(json.dumps({"scope": "actual pure projection/codec/receipt only; no Host.prepare_turn, hooks, SDK, client, transport or remote retention proof",
        "baseline": BASE, "sources": records, "results": outputs}, indent=2) + "\n")
