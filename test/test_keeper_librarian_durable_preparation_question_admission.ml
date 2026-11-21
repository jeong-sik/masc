open Alcotest
open Masc
module R = Keeper_librarian_runtime
module L = Keeper_librarian
module T = Agent_core.Types
module C = Keeper_librarian_context

let get = function Ok value -> value | Error detail -> fail detail
let fact claim = Keeper_memory_os_types.observed ~claim ~category:Keeper_memory_os_types.Fact
  ~now:10. ~origin:{kind=Keeper_memory_os_types.Authored;trace_id="durable-preparation"}
let input () : L.input =
  {turn_ref=Ids.Turn_ref.make ~trace_id:"durable-preparation" ~absolute_turn:8;
   keeper_id=Masc_test_deps.keeper_id_fixture "history-owner";
   keeper_instructions="Retain the original completed history";
   goal_context=L.Task_goals {task_id="original-task";criteria=Error "original goal read failed"};
   historical_task_contexts=[];current=Some {L.facts=[fact "Original source"]};
   working_context={C.empty with sources=[{C.reference="queued-source";content=`String "Unconsumed source"}]};
   messages=[T.user_msg "Original completed user message";
     T.make_message ~role:T.Tool [T.ToolResult {tool_use_id="original-result";content="Original result";
       outcome=T.Tool_succeeded;json=Some (`Assoc ["complete",`Bool true]);content_blocks=Some []}]];
   tool_observations=[{L.tool_name="browser_read";outcome=L.Succeeded}];
   counterpart_observations=[]}

let with_prompts f =
  Prompt_registry.set_markdown_dir "../config/prompts";
  Prompt_defaults.init ();
  let keys=[Prompt_names.librarian;Prompt_names.librarian_working_contexts_rule;
    Prompt_names.librarian_working_context_input;Prompt_names.librarian_turn_inputs] in
  let originals=List.map (fun key -> key,(Prompt_registry.resolve_prompt key).override_value) keys in
  Fun.protect ~finally:(fun () -> List.iter (fun (key,value) -> match value with
    | None -> Prompt_registry.clear_prompt_override key
    | Some value -> Prompt_registry.set_override key value |> get) originals) (fun () ->
    Prompt_registry.set_override Prompt_names.librarian_working_contexts_rule
      "Original shared working-context rule" |> get;
    Prompt_registry.set_override Prompt_names.librarian_turn_inputs "{{conversation_history}}" |> get;
    Prompt_registry.set_override Prompt_names.librarian
      "Original Memory prompt\n{{keeper_instructions}}{{turn_inputs}}\n{{working_contexts_rule}}\n{{facts_budget}}"
      |> get;
    f ())

let test_restoration_keeps_the_frozen_contract () = with_prompts (fun () ->
  let original=R.prepare_durable ~source_lines:[] ~now:123. (input ()) |> get in
  let restore (p:R.durable_preparation)=R.restore_durable_preparation
    ~source_input:p.source_input ~parsing_now:p.parsing_now ~policy:p.policy
    ~rule_prompt:p.rule_prompt ~turn_prompts:p.turn_prompts ~prompt:p.prompt
    ~output_schema:p.output_schema in
  let restored=restore original |> get in
  check bool "restoration preserves the complete frozen question" true (restored=original);
  List.iter (fun changed ->
    check bool "invalid frozen fields still refuse during restoration" true
      (Result.is_error (restore changed)))
    [{original with parsing_now=Float.nan};
     {original with parsing_now=(-1.)};
     {original with policy={original.policy with category_cap=0}};
     {original with rule_prompt={original.rule_prompt with effective="Unbound rule"}};
     {original with turn_prompts={original.turn_prompts with
       working_context_input={original.turn_prompts.working_context_input with source=Prompt_registry.Missing}}};
     {original with prompt={original.prompt with effective="Unbound body"}};
     {original with output_schema=`Assoc ["type",`String "string"]}];
  let frozen=Keeper_librarian_durable_question.(of_json (to_json original)) |> get in
  let changed_source=restore {original with source_input={original.source_input with
    keeper_instructions="Another captured instruction"}} |> get in
  check bool "the retained prompt digest still refuses changed captured input" true
    (Result.is_error (Keeper_librarian_durable_question.rendered_matches frozen changed_source));
  let context:R.durable_step_context={previous_state=Some "Carried state";unread_messages=[]} in
  Prompt_registry.set_override Prompt_names.librarian_turn_inputs
    "{{conversation_history}}\n{{continuity}}" |> get;
  Prompt_registry.set_override Prompt_names.librarian
    "{{turn_inputs}}\n{{working_contexts_rule}}" |> get;
  let step=R.prepare_durable_step ~source_lines:[] ~now:123. ~context (input ()) |> get in
  let p=step.preparation in
  let restore_step ~context ~source_input=R.restore_durable_step_preparation ~context ~source_input
    ~parsing_now:p.parsing_now ~policy:p.policy ~rule_prompt:p.rule_prompt
    ~turn_prompts:p.turn_prompts ~prompt:p.prompt ~output_schema:p.output_schema in
  check bool "floor restoration preserves its source, carried state and schema" true
    (get (restore_step ~context ~source_input:p.source_input)=step);
  check bool "a restored floor cannot carry the ordinary working context" true
    (Result.is_error (restore_step ~context ~source_input:{p.source_input with
      working_context=(input ()).working_context}));
  check bool "a supplied floor record cannot change carried state without its prompt" true
    (Result.is_error (R.validate_durable_step_preparation
      {step with context={context with previous_state=Some "Changed carried state"}})))

(* A Keeper whose earlier [source_path] write left one file-source fact. *)
let source_lines =
  Keeper_memory_source_current.budget_lines (Some
    {Keeper_memory_source_current.revision=1;updated_at=10.;trace_id="durable-preparation";
     facts=[{claim="The deployment notes name the release owner";first_seen=10.;
       source={path="notes.txt";sha256="sha256:" ^ String.make 64 'a'}}];
     invalidations=[]})

let test_restored_budget_counts_source_memory () = with_prompts (fun () ->
  let original=input () in
  let prepared,ordinary_variables=Masc_test_deps.with_process_env
    Env_config.KeeperMemoryOs.facts_max_bytes_env_key (Some "100") (fun () ->
      R.prepare_durable ~source_lines ~now:123. original |> get,
      R.librarian_prompt_variables ~source_lines original |> get) in
  let bytes ~ordinary_facts ~source_lines =
    Keeper_memory_os_render.facts_payload_bytes ~ordinary_facts ~source_lines in
  let ordinary_facts=match original.current with Some current -> current.facts | None -> [] in
  let shown=Printf.sprintf "max=100 bytes; current=%d bytes (ordinary=%d bytes, source=%d bytes)"
    (bytes ~ordinary_facts ~source_lines) (bytes ~ordinary_facts ~source_lines:[])
    (bytes ~ordinary_facts:[] ~source_lines) in
  check (option string) "the prompt shows the total the commit measures" (Some shown)
    (List.assoc_opt "facts_budget" prepared.variables);
  check bool "the ordinary substitutions share the captured source lines" true
    (prepared.variables=ordinary_variables);
  let frozen=Keeper_librarian_durable_question.(of_json (to_json prepared)) |> get in
  let restored=Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key
    (Some "1") (fun () ->
      R.restore_durable_preparation ~source_input:original ~parsing_now:frozen.parsing_now
        ~policy:frozen.policy ~rule_prompt:frozen.rule_prompt ~turn_prompts:frozen.turn_prompts
        ~prompt:frozen.prompt
        ~output_schema:frozen.output_schema |> get) in
  Keeper_librarian_durable_question.rendered_matches frozen restored |> get;
  check string "a restored question renders the budget it was sent" prepared.rendered_prompt
    restored.rendered_prompt;
  check bool "a capture whose source lines were dropped does not restore" true
    (Result.is_error (R.validate_durable_preparation
      {prepared with policy={prepared.policy with facts_source_lines=[]}})))

(* The turn material lives in two slots of librarian.md. A durable question
   renders both into the body; admission carries no turn material, so its
   prompt holds neither slot and the rest of the body is unchanged. *)
let admission_batch () =
  let module Queue=Keeper_memory_admission_queue in
  let keepers_dir=Filename.temp_dir "admission-turn-slots-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree keepers_dir) (fun () ->
    Queue.append ~keepers_dir ~keeper_id:"history-owner" ~request_id:"source" (fact "Pending evidence")
      |> Result.map_error Queue.append_error_to_string |> get |> ignore;
    match Queue.read_pending ~keepers_dir ~keeper_id:"history-owner" |> get with
    | Some batch -> batch
    | None -> fail "the appended candidate is not pending")

let test_admission_omits_turn_material () =
  Prompt_registry.set_markdown_dir "../config/prompts";
  Prompt_defaults.init ();
  let slot_head key=match String.split_on_char '\n'
      (String.trim (Prompt_registry.resolve_prompt key).effective) with
    | head :: _ when String.trim head<>"" -> head
    | _ -> failf "%s has no first line" key in
  let heads=[slot_head Prompt_names.librarian_working_context_input;
    slot_head Prompt_names.librarian_turn_inputs] in
  let contains text piece=Astring.String.is_infix ~affix:piece text in
  let durable=R.prepare_durable ~source_lines:[] ~now:123. (input ()) |> get in
  List.iter (fun head -> check bool ("a durable question shows " ^ head) true
    (contains durable.rendered_prompt head)) heads;
  let blank=List.map (fun (name,value) ->
    if name="working_context_input" || name="turn_inputs" then name,"" else name,value) durable.variables in
  let empty=Prompt_registry.render_resolved_prompt_template Prompt_names.librarian durable.prompt blank |> get in
  let remove text name=match Astring.String.cut ~sep:(List.assoc name durable.variables) text with
    | Some (before,after) -> before ^ after
    | None -> failf "the durable prompt does not hold its %s substitution" name in
  check string "emptying the two slots removes exactly their text from the durable body"
    (remove (remove durable.rendered_prompt "working_context_input") "turn_inputs") empty;
  let admission_input={(input ()) with working_context=C.empty;messages=[];tool_observations=[]} in
  let batch=admission_batch () and retirement=Keeper_memory_admission_judgment.Available [] in
  let admission=R.prepare_admission ~batch ~retirement ~source_lines:[] admission_input |> get in
  List.iter (fun name -> check (option string) ("admission leaves " ^ name ^ " empty") (Some "")
    (List.assoc_opt name admission.variables)) ["working_context_input";"turn_inputs"];
  List.iter (fun head -> check bool ("admission omits " ^ head) false
    (contains admission.rendered_prompt head)) heads;
  R.validate_admission_preparation ~batch ~retirement ~input:admission_input admission |> get

(* Admission renders neither slot, so an input that carries turn material would
   be judged without it. Every kind of turn material is refused, both when the
   question is prepared and when a captured one is checked. *)
let test_admission_refuses_turn_material () =
  Prompt_registry.set_markdown_dir "../config/prompts";
  Prompt_defaults.init ();
  let original=input () in
  let empty={original with working_context=C.empty;messages=[];tool_observations=[]} in
  let counterpart : Keeper_counterpart_observation.t =
    {origin=Durable_chat;channel="direct";workspace_id=None;user_id=Some "speaker";
     user_name=Some "Speaker";authority=External;content="Original counterpart evidence"} in
  let task_context : Keeper_librarian_task_context.t =
    {scope={source=Boundary_only;attribution=Unattributed};first_message=0;after_message=0;
     first_tool_observation=0;after_tool_observation=0} in
  let batch=admission_batch () and retirement=Keeper_memory_admission_judgment.Available [] in
  let prepared=R.prepare_admission ~batch ~retirement ~source_lines:[] empty |> get in
  let refusal=Error "Admission input carries turn material that its prompt does not render" in
  List.iter (fun (kind,(carrying : L.input)) ->
    check bool ("the fixture carries " ^ kind) true (L.carries_turn_material carrying);
    check (result unit string) ("preparing refuses " ^ kind) refusal
      (R.prepare_admission ~batch ~retirement ~source_lines:[] carrying |> Result.map ignore);
    check (result unit string) ("checking a capture refuses " ^ kind) refusal
      (R.validate_admission_preparation ~batch ~retirement ~input:carrying prepared))
    ["a pending working context",{empty with working_context=original.working_context};
     "messages",{empty with messages=original.messages};
     "tool observations",{empty with tool_observations=original.tool_observations};
     "counterpart observations",{empty with counterpart_observations=[counterpart]};
     "past Task/Goal records",{empty with historical_task_contexts=[task_context]}];
  check bool "an input without turn material carries none" false (L.carries_turn_material empty)

let test_admission_proposal_enforces_facts_commit_budget () =
  let original = input () in
  let base_input = {original with working_context=C.empty; messages=[]; tool_observations=[]} in
  let batch = admission_batch () in
  let empty_evidence = `Assoc ["conversation",`List [];"tools",`List [];
    "counterpart",`Bool false;"task_contexts",`Bool false] in
  let grow_output = `Assoc [
    "memory", `Assoc [
      "new_claims", `List [`Assoc [
        "claim", `String "Pending evidence admitted without dropping existing memory";
        "category", `String "fact"; "board_post_id", `Null; "board_comment_id", `Null;
        "supersedes", `Null; "absorbs", `List []; "evidence", empty_evidence]];
      "dropped", `List []; "working_state", `Null; "working_contexts", `List []];
    "candidates", `List [`Assoc [
      "request_id", `String "source"; "outcome", `String "incorporated";
      "memory_claim", `String "Pending evidence admitted without dropping existing memory";
      "reason", `String "durable candidate"]];
    "change_support", `List [`String "source"]] in
  let tight_policy : R.admission_policy = {
    facts_max_bytes = 64; facts_source_lines = []; category_cap = 10; facts_per_category_cap = 50} in
  (match R.validate_admission_proposal ~policy:tight_policy ~now:123. ~batch ~input:base_input grow_output with
   | Error error ->
     let rendered = L.parse_error_to_string error in
     check bool "oversized admission proposal is rejected before commit" true
       (String.starts_with ~prefix:"admission_invalid: " rendered
        && Astring.String.is_infix ~affix:"exceed commit budget" rendered)
   | Ok (R.Accepted _ | R.Deferred) -> fail "oversized admission proposal should be rejected at validation");
  let bloated_input = {base_input with current=Some {L.facts=[
    fact "Bloated fact one that already pushed the snapshot far past the tight byte cap";
    fact "Bloated fact two that also needs to be retired so the snapshot can shrink"]}} in
  let shrink_output = `Assoc [
    "memory", `Assoc [
      "new_claims", `List [`Assoc [
        "claim", `String "Short summary";
        "category", `String "fact"; "board_post_id", `Null; "board_comment_id", `Null;
        "supersedes", `Null; "absorbs", `List [`String "m1"; `String "m2"];
        "evidence", empty_evidence]];
      "dropped", `List [];
      "working_state", `Null; "working_contexts", `List []];
    "candidates", `List [`Assoc [
      "request_id", `String "source"; "outcome", `String "incorporated";
      "memory_claim", `String "Short summary";
      "reason", `String "shrinks bloated memory"]];
    "change_support", `List [`String "source"]] in
  (match R.validate_admission_proposal ~policy:tight_policy ~now:123. ~batch ~input:bloated_input shrink_output with
   | Ok (R.Accepted _) -> ()
   | Ok R.Deferred -> fail "shrinking proposal should be accepted, not deferred"
   | Error err -> fail (L.parse_error_to_string err))

let () = run "Original history Memory preparation: restored question and admission" ["preparation",[
  test_case "a restored question's facts budget counts source memory" `Quick
    test_restored_budget_counts_source_memory;
  test_case "restoration preserves frozen validation and the floor context" `Quick
    test_restoration_keeps_the_frozen_contract;
  test_case "admission omits the turn-material slots that durable questions render" `Quick
    test_admission_omits_turn_material;
  test_case "admission refuses an input that carries turn material" `Quick
    test_admission_refuses_turn_material;
  test_case "admission proposal enforces captured facts commit budget while permitting net shrinkage" `Quick
    test_admission_proposal_enforces_facts_commit_budget]]
