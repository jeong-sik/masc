type review_input = {
  task_id : string;
  task_title : string;
  task_description : string;
  author_keeper : string;
  evidence_refs : string;
}

let prompt_name = "verification.adversarial_review"

let build_prompt (input : review_input) : (string, string) result =
  Prompt_registry.render_prompt_template prompt_name
    [
      ("task_title", input.task_title);
      ("task_description", input.task_description);
      ("evidence_refs", input.evidence_refs);
    ]

let apply_report_verdict_output_schema provider_cfg =
  let schema = Keeper_structured_output_schema.verification_verdict_output_schema in
  Ok
    (Keeper_structured_output_schema.apply_schema_or_prompt_tier
       ~log_label:"adversarial review output contract"
       schema
       provider_cfg)

let parse_grounded_verdict_from_response_text text =
  match Yojson.Safe.from_string (String.trim text) with
  | json -> Verifier_core.parse_grounded_verdict_from_json json
  | exception Yojson.Json_error msg ->
    Error
      (Printf.sprintf
         "adversarial review response must be strict JSON: %s"
         msg)

let parse_grounded_verdict_from_response response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"verification_adversarial_review"
      response
  with
  | Ok json -> Verifier_core.parse_grounded_verdict_from_json json
  | Error msg ->
    Error
      (Printf.sprintf
         "adversarial review response must be structured JSON: %s"
         msg)

module For_testing = struct
  let parse_grounded_verdict_from_response_text =
    parse_grounded_verdict_from_response_text
end

(* Mirrors [Verifier_oas.verify]: structured verdict via the [report_verdict]
   tool, with a strict JSON fallback if the model answers without the tool.
   The judgment itself is the model's; this only routes its structured output
   back as a typed [Verifier_core.verdict]. *)
let run_grounded_review ~base_path ~runtime_id (input : review_input) :
    (Verifier_core.grounded_verdict, string) result =
  match build_prompt input with
  | Error msg ->
    Log.Keeper.warn "adversarial_review: prompt render/validation failed: %s" msg;
    Error msg
  | Ok prompt ->
    let verdict_ref = ref None in
    let dispatch ~name ~args =
      let start_time = Time_compat.now () in
      match !verdict_ref with
      | Some v ->
        let msg =
          Printf.sprintf
            "Verdict already recorded (%s); only one report_verdict call is allowed"
            (Verifier_core.verdict_to_string v.Verifier_core.verdict)
        in
        Log.Keeper.warn "adversarial_review: %s" msg;
        Tool_result.error ~tool_name:name ~start_time msg
      | None -> (
        match Verifier_core.parse_grounded_verdict_from_json args with
        | Ok v ->
          verdict_ref := Some v;
          Tool_result.ok ~tool_name:name ~start_time
            (Printf.sprintf "Verdict recorded: %s"
               (Verifier_core.verdict_to_string v.Verifier_core.verdict))
        | Error msg ->
          Log.Keeper.warn "adversarial_review: verdict parse failed: %s" msg;
          Tool_result.error ~tool_name:name ~start_time
            (Printf.sprintf "Invalid verdict format: %s" msg))
    in
    match
      Keeper_turn_driver_wrappers.run_named_with_masc_tools ~runtime_id
        ~base_path
        ~goal:prompt
        ~masc_tools:[ Verifier_core.report_verdict_schema ]
        ~dispatch
        ~temperature:Runtime_provider_defaults.deterministic_temperature
        ~approval:Approval_callbacks.auto_approve
        ~provider_config_transform:apply_report_verdict_output_schema
        ()
    with
    | Ok result -> (
      match !verdict_ref with
      | Some v -> Ok v
      | None ->
        (* Model answered without calling report_verdict. Provider-native
           schema still requires a strict JSON grounded verdict object. *)
        parse_grounded_verdict_from_response result.response)
    | Error err -> Error (Agent_sdk.Error.to_string err)

let run_review ~base_path ~runtime_id (input : review_input) :
    (Verifier_core.verdict, string) result =
  match run_grounded_review ~base_path ~runtime_id input with
  | Ok grounded -> Ok grounded.Verifier_core.verdict
  | Error msg -> Error msg

(* Identity routing: the work's author is known, so waking them is structural,
   not a judgment. Dedup is keyed on the stable task-level FAIL outcome so
   reason wording drift cannot repeatedly wake the author for the same task. *)
let wake_author ?grounded ~base_path ~(input : review_input) ~reason () :
    (unit, string) result =
  let dedupe_key = Printf.sprintf "adversarial_review:%s:fail" input.task_id in
  let event_id = Keeper_external_attention.event_id_of_dedupe_key dedupe_key in
  let conversation_id = Printf.sprintf "review:%s" input.task_id in
  let grounded_metadata =
    match grounded with
    | None -> []
    | Some grounded ->
      [
        ( "grounded_verdict",
          Yojson.Safe.to_string
            (Verifier_core.grounded_verdict_to_yojson grounded) );
        ( "evidence_count",
          string_of_int (List.length grounded.Verifier_core.evidence) );
      ]
  in
  let item : Keeper_external_attention.item =
    {
      event_id;
      dedupe_key;
      keeper_name = input.author_keeper;
      conversation = { conversation_id; surface = Surface_ref.Agent };
      external_message = None;
      source_label = "adversarial_review";
      actor =
        {
          actor_id = Some "adversarial_review";
          display_name = Some "Adversarial reviewer";
          authority = Keeper_chat_store.External;
        };
      urgency = Keeper_external_attention.System;
      content_preview = reason;
      content_ref = None;
      received_at = Time_compat.now ()
      (* NDT-OK: attention received_at is evidence and pending-order only; it
         does not branch deterministic policy. *);
      metadata =
        [
          ("kind", "review_rejected");
          ("task_id", input.task_id);
          ("verdict", "FAIL");
        ]
        @ grounded_metadata;
    }
  in
  match Keeper_external_attention.record ~base_path item with
  | `Recorded | `Duplicate _ -> Ok ()
  | `Error error ->
    let msg =
      Printf.sprintf "adversarial_review: wake author %s failed: %s"
        input.author_keeper error
    in
    Log.Keeper.warn "%s" msg;
    Error msg

let act_on_verdict ~base_path ~(input : review_input)
    (verdict : Verifier_core.verdict) : (unit, string) result =
  match verdict with
  | Verifier_core.Fail reason -> wake_author ~base_path ~input ~reason ()
  | Verifier_core.Pass | Verifier_core.Warn _ -> Ok ()

let act_on_grounded_verdict ~base_path ~(input : review_input)
    (grounded : Verifier_core.grounded_verdict) : (unit, string) result =
  match grounded.Verifier_core.verdict with
  | Verifier_core.Fail reason -> wake_author ~grounded ~base_path ~input ~reason ()
  | Verifier_core.Pass | Verifier_core.Warn _ -> Ok ()

let review_and_wake_on_fail ~base_path ~runtime_id (input : review_input) :
    (Verifier_core.verdict, string) result =
  match run_grounded_review ~base_path ~runtime_id input with
  | Error msg -> Error msg
  | Ok grounded ->
    Result.map
      (fun () -> grounded.Verifier_core.verdict)
      (act_on_grounded_verdict ~base_path ~input grounded)
