"""Execute exact pure official projection source; not Host/SDK/vendor execution."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
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
module Start = Host_start
let checks = ref 0
let check label okay = if not okay then failwith label else
  (incr checks; Printf.printf "PASS %s\n" label)
let binding piece = Link.binding_to_json ~slot:W.Whole_write piece (W.raw (Link.text piece))
let () =
  let issued text = A.assemble ~dynamic_context_partition:None
      ~existing_extra_system_context:None ~blocks:[P.Dynamic_context,"TASK GATE LANE"]
    |> A.with_system_observations ~base_text:"BASE" ~observations:(Option.to_list (Option.map (fun text -> A.Active_goals text) text)) in
  let messages a = match a.A.extra_system_context with None -> []
    | Some text -> [H.extra_system_context_message text] in
  let before = issued (Some "GOAL rev1 measure0/3") in
  let after = issued (Some "GOAL rev2 measure1/4\n관측 \"reported_only\"") in
  let held = H.start_held_context ~composed_context:before (messages before) in
  let result = H.resume_prompt ~goal:"OWNER" ~held ~composed_context:after (messages after) in
  let open Yojson.Safe.Util in

    let text = snd (List.hd (List.map A.observation_block (Option.get after.system_prompt).observations)) in
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
    let stale = Link.encoded_system_observation ~target:Official_resume_user ~block:P.Active_goals ~assembly:(Some before) (H.user_message text) in
    check "stale System issuer cannot prove new observation"
      (binding stale |> member "issuer_attribution" |> member "status" = `String "unavailable");
    let authority_text = "Approved task-1 vrf-1 human_operator fixture-operator" in
    let authority = A.assemble ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks:[]
        |> A.with_system_observations ~base_text:"BASE" ~observations:[A.Completion_authority authority_text] in
    let authority_held = {Keeper_official_client_session_store.context=Context_block P.Completion_authority;
      sha256=Digestif.SHA256.(digest_string authority_text |> to_hex)} :: held in
    let first_authority = H.resume_prompt ~goal:"OWNER" ~held:authority_held ~composed_context:authority [] in
    let next_authority = H.resume_prompt ~goal:"OWNER" ~held:first_authority.held_context ~composed_context:authority [] in
    check "Completion Authority remains Sent_every_resume" (P.resent_when_held P.Completion_authority);
    check "held authority is actually resent" (Astring.String.is_infix ~affix:authority_text next_authority.prompt);
    check "authority repeats exact bytes instead of accumulating" (first_authority.prompt = next_authority.prompt);
    let authority_binding = binding next_authority.context_projection in
    let proof = match authority_binding |> member "occurrences" |> to_list with
      | [occurrence] -> member "source" occurrence | _ -> failwith "one authority occurrence required" in
    check "authority receipt selects the physical System carrier" (member "source_carrier" proof = `String "system_prompt");
    let physical = Option.get authority.system_prompt in
    let index = match member "source_span_indices" proof |> to_list with [i] -> to_int i | _ -> failwith "one authority span" in
    let span = List.nth physical.partition.spans index in
    check "authority source selects its own unique block" (span.kind = A.Block P.Completion_authority);
    check "authority source bytes equal the delivered row" (String.sub physical.text span.offset span.bytes = authority_text);
    let missing = Link.encoded_system_observation ~target:Official_resume_user ~block:P.Completion_authority ~assembly:None (H.user_message authority_text) in
    check "missing authority issuer remains unknown" (binding missing |> member "issuer_attribution" |> member "status" = `String "unavailable");
    let stale = Link.encoded_system_observation ~target:Official_resume_user ~block:P.Completion_authority ~assembly:(Some authority) (H.user_message "FOREIGN") in
    check "stale authority issuer remains unknown" (binding stale |> member "issuer_attribution" |> member "status" = `String "unavailable");
    let absent = Link.encoded_system_observation ~target:Official_resume_user ~block:P.Completion_authority ~assembly:(Some after) (H.user_message authority_text) in
    check "Goal receipt cannot attest an absent authority observation" (binding absent |> member "issuer_attribution" |> member "status" = `String "unavailable");
    check "duplicate authority kinds are rejected before issuing a System carrier"
      (try ignore (A.assemble ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks:[]
         |> A.with_system_observations ~base_text:"BASE"
              ~observations:[A.Completion_authority authority_text;A.Completion_authority "FOREIGN"]);false
       with Invalid_argument _ -> true);
    let frame = `Assoc ["input", `List [`Assoc ["type",`String "text";"text",`String result.prompt]]] in
    let payload = Yojson.Safe.to_string frame in
    let write = W.json_line (W.Fields ["input",W.turn_input]) frame payload in
    check "JSON turn-text slot binds the actual projection"
      (Link.binding_to_json ~slot:(W.Turn_text 0) result.context_projection write |> member "status"
       = `String "matched_completed_slot");
  let make observations base = A.assemble ~dynamic_context_partition:None
      ~existing_extra_system_context:None ~blocks:[]
    |> A.with_system_observations ~base_text:base ~observations in
  let goal_text = "GOAL 현재 criterion" in
  let first_text = "Approved task-first vrf-first operator-첫번째" in
  let next_text = "Rejected task-other vrf-new operator-second" in
  let first = make [A.Active_goals goal_text; A.Completion_authority first_text] "BASE" in
  let canonical = Option.get first.system_prompt in
  let system, start_context, issuer = H.project_start_system
      ~system_prompt:canonical.text ~composed_context:(Some first) in
  let start = Start.start_prompt {Start.start_context} "FIRST OWNER" in
  check "fixed Start System preserves Goal and excludes the authority event"
    (system = "BASE\n\n" ^ goal_text);
  check "complete first User packet contains authority once and no Goal copy"
    (Link.text start = "USER:\n" ^ H.encode_history_message (H.user_message first_text) ^ "\n\nFIRST OWNER");
  let proof = match binding start |> member "occurrences" |> to_list with
    | [occurrence] -> member "source" occurrence | _ -> failwith "one initial authority occurrence" in
  check "initial proof names actual Start User target"
    (member "target_carrier" proof = `String "official_start_user_prompt");
  check "initial proof distinguishes canonical issuer from submitted System"
    (member "source_scope" proof = `String "canonical_issued_system_prompt"
     && member "sha256" (member "assembly" proof) = `String canonical.partition.sha256
     && canonical.text <> system);
  let held = H.start_held_context ?composed_context:issuer [] in
  let resumed = H.resume_prompt ~goal:"OWNER" ~held ?composed_context:issuer [] in
  check "same event Resume sends one authority and omits held Goal"
    (resumed.prompt = "USER:\n" ^ H.encode_history_message (H.user_message first_text) ^ "\n\nOWNER");
  let absent = make [A.Active_goals goal_text] "BASE" in
  let absent_system, absent_context, absent_issuer = H.project_start_system
      ~system_prompt:(Option.get absent.system_prompt).text ~composed_context:(Some absent) in
  let no_event = H.resume_prompt ~goal:"NEXT OWNER" ~held:resumed.held_context
      ?composed_context:absent_issuer [] in
  check "later owner with no event adds no observation to Start or Resume"
    (Link.text (Start.start_prompt {Start.start_context=absent_context} "NEXT OWNER") = "NEXT OWNER"
     && no_event.prompt = "NEXT OWNER" && absent_system = system);
  let changed = make [A.Active_goals goal_text; A.Completion_authority next_text] "BASE" in
  let changed_system, changed_context, changed_issuer = H.project_start_system
      ~system_prompt:(Option.get changed.system_prompt).text ~composed_context:(Some changed) in
  let changed_start = Start.start_prompt {Start.start_context=changed_context} "NEXT OWNER" in
  check "changed event and verification keys replace old keys at Start"
    (Link.text changed_start = "USER:\n" ^ H.encode_history_message (H.user_message next_text) ^ "\n\nNEXT OWNER"
     && changed_system = system);
  check "changed event and verification keys reach held Resume"
    ((H.resume_prompt ~goal:"NEXT OWNER" ~held:no_event.held_context
        ?composed_context:changed_issuer []).prompt = Link.text changed_start);
  List.iter (fun observations ->
    let assembly = make observations "  BASE  " in
    let actual, context, _ = H.project_start_system
      ~system_prompt:(Option.get assembly.system_prompt).text ~composed_context:(Some assembly) in
    check "four Goal/authority combinations preserve exact standing base and Goal"
      (actual = (if List.exists (function A.Active_goals _ -> true | Completion_authority _ -> false) observations
         then "  BASE  \n\n" ^ goal_text else "  BASE  "));
    check "authority is the only initial User observation"
      (Link.text context = (if List.exists (function A.Completion_authority _ -> true | Active_goals _ -> false) observations
        then "USER:\n" ^ H.encode_history_message (H.user_message first_text) else "")))
    [[]; [A.Active_goals goal_text]; [A.Completion_authority first_text];
     [A.Active_goals goal_text; A.Completion_authority first_text]];
  List.iter (fun candidate ->
    let actual, context, retained = H.project_start_system
      ~system_prompt:(Option.get changed.system_prompt).text ~composed_context:candidate in
    check "missing/stale issuer cannot rewrite or attest selected System"
      (actual = (Option.get changed.system_prompt).text && Link.text context = "" && retained = None);
    check "missing/stale issuer cannot lend an old event to Resume"
      ((H.resume_prompt ~goal:"OWNER" ~held:[] ?composed_context:retained []).prompt = "OWNER");
    let piece = Link.encoded_system_observation ~target:Official_start_user
      ~block:P.Completion_authority ~assembly:candidate (H.user_message next_text) in
    check "missing/stale initial event proof remains unavailable"
      (binding piece |> member "issuer_attribution" |> member "status" = `String "unavailable"))
    [None; Some first];
  List.iter (fun observation -> List.iter (fun base ->
    let assembly = make [observation] base in
    let reads = ref 0 in
    let result = Guard.prepare_guard ~system_prompt:base
      ~composed_context:(Some (fun () -> incr reads; Some assembly))
      {Guard.system_prompt_override=Some (Option.get assembly.system_prompt).text} in
    check "actual Host guard rejects blank base beneath Goal or authority"
      (match result with Error (Guard.InvalidConfig {field;_}) -> field = "system_prompt" | Ok _ -> false);
    check "actual Host guard acquires issuer only once" (!reads = 1)) [""; " \n\t "])
    [A.Active_goals goal_text; A.Completion_authority first_text];
  let frame = `Assoc ["input", `List [`Assoc ["type",`String "text";"text",`String (Link.text start)]]] in
  let write = W.json_line (W.Fields ["input", W.turn_input]) frame (Yojson.Safe.to_string frame) in
  check "complete actual Start User slot binds the exact source"
    (Link.binding_to_json ~slot:(W.Turn_text 0) start write |> member "status" = `String "matched_completed_slot");
  Printf.printf "PACKET %s\n" (Yojson.Safe.to_string (`Assoc [
    "canonical_issued_system", `String canonical.text;
    "submitted_start_system", `String system;
    "submitted_start_user", `String (Link.text start);
    "submitted_same_event_resume", `String resumed.prompt;
    "submitted_next_absent_resume", `String no_event.prompt;
    "submitted_changed_event_start", `String (Link.text changed_start);
    "start_source_binding", binding start]));
  Printf.printf "%d exact-source official Start/Resume checks passed\n" !checks
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
    put("host_start.ml", "type prepared_turn = {start_context:Keeper_context_submission_link.t}\n" + extract(
        "lib/keeper/keeper_official_client_host.ml", "let start_prompt prepared prompt =", "type transmitted_model_input ="),
        "exact Host.start_prompt; minimal record port, not full Host")
    put("string_util.ml", extract("lib/string_util/string_util.ml", "let trim_nonempty value =", "(* The .mli says this maps trim_nonempty"),
        "exact trim_nonempty fragment")
    host = read("lib/keeper/keeper_official_client_host.ml")
    host = host[host.index("let prepare_turn ~runtime_label"):]
    guard = host[host.index("  let system_prompt =\n"):host.index("  (* No preemptive cut of the seed.")]
    put("guard.ml", 'type turn_params = {system_prompt_override:string option}\n'
        'type error = InvalidConfig of {field:string; detail:string}\n'
        'let config_error ~field detail = InvalidConfig {field;detail}\n'
        'let ( let* ) = Result.bind\n'
        'let prepare_guard ~system_prompt ~composed_context turn_params =\n' + guard + '  Ok system_prompt\n',
        "exact Host selected-System/snapshot/blank-base guard statements; minimal typed ports")
    (directory / "probe.ml").write_text(probe)
    outputs = []
    for label, full in [("repair", read("lib/keeper/keeper_official_client_context_projection.ml"))]:
        projection = full[full.index("let encode_history_message ="):full.index("let last_tool_results messages =")]
        (directory / "projection.ml").write_text(projection)
        built = subprocess.run(["ocamlfind", "ocamlc", "-package", "yojson,digestif.ocaml,astring,ppx_deriving_yojson,ppx_deriving.show",
                                "-w", "+4+32+69", "-warn-error", "+a", "-linkpkg", *sources, "projection.ml", "probe.ml", "-o", "probe"], cwd=directory, capture_output=True, text=True)
        if built.returncode:
            print(built.stdout + built.stderr)
            raise SystemExit(built.returncode)
        ran = subprocess.run([str(directory / "probe"), label], cwd=directory, capture_output=True, text=True)
        outputs.append({"variant": label, "projection_sha256": hashlib.sha256(projection.encode()).hexdigest(),
                        "compile_exit": built.returncode, "compile_stderr": built.stderr, "run_exit": ran.returncode, "output": ran.stdout + ran.stderr})
        print(label + "\n" + ran.stdout + ran.stderr)
        if ran.returncode:
            raise SystemExit(ran.returncode)
    (OUT / "official-resume-check.json").write_text(json.dumps({"scope": "actual pure Start/Resume projection, codec, receipt, Host.start_prompt and selected Host issuer/blank guard statements; not full Host.prepare_turn, hooks, SDK, client, transport or remote retention proof",
        "base_head": "cc5104805e3963a9ef1a4fcb0013145514466a91", "sources": records, "results": outputs}, indent=2) + "\n")
