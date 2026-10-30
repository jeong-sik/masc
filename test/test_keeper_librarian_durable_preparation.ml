open Alcotest
open Masc
module R = Keeper_librarian_runtime
module L = Keeper_librarian
module T = Agent_core.Types
module C = Keeper_librarian_context

let get = function Ok value -> value | Error detail -> fail detail
let proposal = function
  | Ok value -> value
  | Error (R.Preparation_invalid detail) -> fail detail
  | Error (R.Proposal_invalid error) -> fail (L.parse_error_to_string error)
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
  let keys=[Prompt_names.librarian;Prompt_names.librarian_working_contexts_rule] in
  let originals=List.map (fun key -> key,(Prompt_registry.resolve_prompt key).override_value) keys in
  Fun.protect ~finally:(fun () -> List.iter (fun (key,value) -> match value with
    | None -> Prompt_registry.clear_prompt_override key
    | Some value -> Prompt_registry.set_override key value |> get) originals) (fun () ->
    Prompt_registry.set_override Prompt_names.librarian_working_contexts_rule
      "Original shared working-context rule" |> get;
    Prompt_registry.set_override Prompt_names.librarian
      "Original Memory prompt\n{{keeper_instructions}}\n{{conversation_history}}\n{{working_contexts_rule}}\n{{facts_budget}}"
      |> get;
    f ())

let test_original_preparation () = with_prompts (fun () ->
  let original=input () in
  let prepared=R.prepare_durable ~now:123. original |> get in
  check bool "the complete original input, including nested tool JSON, is retained" true
    (prepared.source_input=original);
  check bool "the ordinary synchronous Memory substitutions are shared" true
    (prepared.variables=(R.librarian_prompt_variables original |> get));
  let sent=R.messages_for_librarian original |> get in
  check bool "the ordinary public Memory message uses these exact rendered bytes" true
    (sent=[Llm_provider.Types.user_msg prepared.rendered_prompt]);
  let saved=prepared.rendered_prompt in
  Prompt_registry.set_override Prompt_names.librarian "Changed current prompt" |> get;
  Prompt_registry.set_override Prompt_names.librarian_working_contexts_rule "Changed current rule" |> get;
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key (Some "1") (fun () ->
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.category_cap_env_key (Some "1") (fun () ->
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.facts_per_category_cap_env_key (Some "1") (fun () ->
    R.validate_durable_preparation prepared |> get;
    check string "restoration never re-renders with current prompt or policy" saved prepared.rendered_prompt;
    check bool "fresh work really observes the changed configuration" true
      ((R.prepare_durable ~now:124. original |> get).rendered_prompt<>saved)))))

let answer = `Assoc [
  "new_claims",`List [`Assoc ["claim",`String "Original source plus completed observation";
    "category",`String "fact";"board_post_id",`Null;"board_comment_id",`Null;
    "supersedes",`Null;"absorbs",`List [`String "m1"]]];
  "dropped",`List [];"working_state",`Null;"working_contexts",`List []]

let test_original_validation_and_absorption () = with_prompts (fun () ->
  let prepared=R.prepare_durable ~now:123. (input ()) |> get in
  let judged=R.validate_durable_proposal prepared answer |> proposal in
  let expected=L.selection_of_json_result ~now:123. prepared.source_input answer
    |> Result.map_error L.parse_error_to_string |> get in
  check bool "the complete original selection parser owns the proposal" true
    (judged.accepted.selection=expected);
  check bool "history cannot acquire explicit-candidate authority" true
    (judged.accepted.continuity_answer=R.Memory_only
     && judged.accepted.required_memory_ids=[] && judged.accepted.explicit_candidate_ids=[]
     && judged.accepted.admission_support=[] && judged.accepted.admission_recall_bindings=[]);
  check bool "the same normal absorption inputs retain original observations and current facts" true
    (judged.absorption.observations=L.observations_for_absorption prepared.source_input
     && judged.absorption.facts=(match prepared.source_input.current with None -> [] | Some state -> state.facts)
     && judged.absorption.new_claims=expected.new_claims
     && judged.absorption.absorbed=expected.absorbed
     && judged.absorption.superseding=[]);
  check int "the original absorption identity is resolved, not a surrogate or empty gate" 1
    (List.length judged.absorption.absorbed);
  check int "the proposal carries the new fact to the host gate" 1
    (List.length judged.absorption.new_claims);
  check bool "new fact timestamps come from the retained parse instant" true
    (List.for_all (fun (value:Keeper_memory_os_types.fact) -> value.first_seen=123.) judged.absorption.new_claims);
  let extra=match answer with `Assoc fields -> `Assoc (("unexpected",`Bool true)::fields)
    | _ -> fail "answer must be an object" in
  (match R.validate_durable_proposal prepared extra with
   | Error (R.Proposal_invalid error) -> check bool "raw errors retain the normal typed parser cause" true
       (error=L.Unexpected_field "unexpected")
   | Error (R.Preparation_invalid detail) -> fail detail
   | Ok _ -> fail "unexpected raw proposal field was accepted"))

let test_restore_refuses_tampering () = with_prompts (fun () ->
  let original=R.prepare_durable ~now:123. (input ()) |> get in
  let mutations : R.durable_preparation list = [
    {original with source_input={original.source_input with keeper_instructions="Different source"}};
    {original with parsing_now=Float.nan};
    {original with policy={original.policy with facts_max_bytes=0}};
    {original with variables=("unexpected","invented")::original.variables};
    {original with rule_prompt={original.rule_prompt with effective="Different effective rule"}};
    {original with prompt={original.prompt with source=Prompt_registry.Missing}};
    {original with rendered_prompt=original.rendered_prompt ^ " changed"};
    {original with output_schema=`Assoc ["type",`String "string"]}] in
  List.iter (fun changed ->
    check bool "captured input/policy/template/schema inconsistencies refuse" true
      (Result.is_error (R.validate_durable_preparation changed));
    (match R.validate_durable_proposal changed answer with
     | Error (R.Preparation_invalid _) -> ()
     | Error (R.Proposal_invalid error) -> fail (L.parse_error_to_string error)
     | Ok _ -> fail "invalid restored preparation reached proposal parsing")) mutations;
  check bool "invalid caller time refuses before durable dispatch" true
    (Result.is_error (R.prepare_durable ~now:(-1.) (input ()))))

let () = run "Original history Memory preparation" ["preparation",[
  test_case "original capture survives current prompt and policy changes" `Quick test_original_preparation;
  test_case "normal raw parser and absorption inputs remain original" `Quick test_original_validation_and_absorption;
  test_case "restore inconsistency never reaches domain parsing" `Quick test_restore_refuses_tampering]]
