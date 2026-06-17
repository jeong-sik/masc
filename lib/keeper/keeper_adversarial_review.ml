type review_input = {
  task_id : string;
  task_title : string;
  task_description : string;
  author_keeper : string;
  evidence_refs : string;
}

let prompt_name = "verification.adversarial_review"

let build_prompt (input : review_input) : string =
  match
    Prompt_registry.render_prompt_template prompt_name
      [
        ("task_title", input.task_title);
        ("task_description", input.task_description);
        ("evidence_refs", input.evidence_refs);
      ]
  with
  | Ok p -> p
  | Error msg ->
    Log.Keeper.warn
      "adversarial_review: prompt %s render failed (%s); using raw template"
      prompt_name msg;
    Prompt_registry.get_prompt prompt_name

(* Mirrors [Verifier_oas.verify]: structured verdict via the [report_verdict]
   tool, with a lenient text fallback. The judgment itself is the model's; this
   only routes its structured output back as a typed [Verifier_core.verdict]. *)
let run_review ~runtime_id (input : review_input) :
    (Verifier_core.verdict, string) result =
  let prompt = build_prompt input in
  let verdict_ref = ref None in
  let dispatch ~name ~args =
    let start_time = Time_compat.now () in
    match Verifier_core.parse_verdict_from_json args with
    | Ok v ->
      verdict_ref := Some v;
      Tool_result.error ~tool_name:name ~start_time
        (Printf.sprintf "Verdict recorded: %s" (Verifier_core.verdict_to_string v))
    | Error msg ->
      Log.Keeper.warn "adversarial_review: verdict parse failed: %s" msg;
      Tool_result.error ~tool_name:name ~start_time
        (Printf.sprintf "Invalid verdict format: %s" msg)
  in
  match
    Keeper_turn_driver_wrappers.run_named_with_masc_tools ~runtime_id
      ~goal:prompt
      ~masc_tools:[ Verifier_core.report_verdict_schema ]
      ~dispatch
      ~temperature:Runtime_provider_defaults.deterministic_temperature
      ~approval:Approval_callbacks.auto_approve ()
  with
  | Ok result -> (
    match !verdict_ref with
    | Some v -> Ok v
    | None ->
      (* Model answered in text instead of calling report_verdict. *)
      let text = Agent_sdk_response.text_of_response result.response in
      Verifier_core.parse_verdict text)
  | Error err -> Error (Agent_sdk.Error.to_string err)

(* Identity routing: the work's author is known, so waking them is structural,
   not a judgment. Dedup is content-addressed on (task_id, reason) so a given
   rejection wakes the author exactly once. *)
let wake_author ~base_path ~(input : review_input) ~reason : unit =
  let dedupe_key =
    Printf.sprintf "adversarial_review:%s:%s" input.task_id
      (Digest.to_hex (Digest.string reason))
  in
  let event_id = Keeper_external_attention.event_id_of_dedupe_key dedupe_key in
  let conversation_id = Printf.sprintf "review:%s" input.task_id in
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
        ];
    }
  in
  match Keeper_external_attention.record ~base_path item with
  | `Recorded | `Duplicate _ -> ()
  | `Error error ->
    Log.Keeper.warn "adversarial_review: wake author %s failed: %s"
      input.author_keeper error

let act_on_verdict ~base_path ~(input : review_input)
    (verdict : Verifier_core.verdict) : unit =
  match verdict with
  | Verifier_core.Fail reason -> wake_author ~base_path ~input ~reason
  | Verifier_core.Pass | Verifier_core.Warn _ -> ()

let review_and_wake_on_fail ~base_path ~runtime_id (input : review_input) :
    (Verifier_core.verdict, string) result =
  match run_review ~runtime_id input with
  | Error _ as e -> e
  | Ok verdict ->
    act_on_verdict ~base_path ~input verdict;
    Ok verdict
