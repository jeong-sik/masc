module Exact = Agent_core.Exact_output
module Addon = Lane_addon_exact
module Failure = Exact_lane_failure
module Registry = Runtime_exact_output_registry
module Receipt = Keeper_exact_walk_receipt
open Result.Syntax

(* What one tried slot said. Every slot the call reached leaves one. *)
type slot_failure =
  { slot : string
  ; failure : Failure.t
  ; detail : string
  }

let may_pass = function
  | Failure.Transient | Failure.Auth_refused | Failure.Configuration_refused -> true
  | Failure.Input_refused _ | Failure.Output_unusable | Failure.Output_limit -> false

let input_refusal = function
  | Failure.Request_body -> Addon.Request_body_refused
  | Failure.Invalid_request -> Addon.Invalid_request
  | Failure.Context_overflow -> Addon.Context_overflow
  | Failure.Input_capacity -> Addon.Input_capacity

(* A refusal that may pass outranks one that cannot: the slot that refused for
   now may answer on the next trigger. Among those, the reason shown is the
   one most likely to clear by itself. An input refusal ends the request only
   when no slot may still pass, with the kind [Failure.ending_input_refusal]
   chooses; [invalid_output] only when every slot answered. *)
let ending = function
  | [] ->
    (* A walk that reached no slot leaves no evidence about the input or the
       answer, so it cannot end the request. *)
    Addon.Call_refused (Addon.Provider_configuration_refused { detail = "no slot reported an outcome" })
  | failures ->
    let detail =
      String.concat "; " (List.map (fun { slot; detail; _ } -> slot ^ ": " ^ detail) failures)
    in
    let has failure = List.exists (fun f -> f.failure = failure) failures in
    if List.exists (fun f -> may_pass f.failure) failures
    then
      Addon.Call_refused
        (if has Failure.Transient then Addon.Provider_unavailable { detail }
         else if has Failure.Configuration_refused then Addon.Provider_configuration_refused { detail }
         else Addon.Provider_auth_refused { detail })
    else
      match Failure.ending_input_refusal (List.map (fun f -> f.failure) failures) with
      | Some kind -> Addon.Call_ended (Addon.Input_refused (input_refusal kind))
      | None ->
        if has Failure.Output_limit then Addon.Call_ended (Addon.Output_limit_reached {detail})
        else Addon.Call_ended (Addon.Invalid_output { detail })

let raw_excerpt = Keeper_exact_flow_detail.raw_response_excerpt

type http_outcome =
  | Http_answered of { output : Addon.checked; slot : string; usage : Addon.usage option }
  | Http_exhausted  (** Every HTTP slot was tried, or there was none. *)
  | Http_stopped
      (** The flow refused to advance, so no later slot may be dispatched. *)

let usage_of_api (usage : Agent_core.Types.api_usage) =
  { Addon.input_tokens = usage.input_tokens; output_tokens = usage.output_tokens }

let execute_http ~before_dispatch ~admission_class ~note ~capture_http ~resolved ~requirement ~messages ~validate =
  let candidate (slot : Registry.selected_slot) =
    match Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target with
    | Ok candidate -> Some candidate
    | Error Exact.Blank_flow_candidate_id ->
      note slot.slot_id Failure.Configuration_refused "blank slot id";
      None
  in
  match List.filter_map candidate resolved.Registry.selected_slots with
  | [] -> Http_exhausted
  | first :: rest ->
    match Exact.snapshot_flow ~first ~rest ~messages requirement with
    | Error (Exact.Duplicate_flow_candidate_id { candidate_id; _ }) ->
      note candidate_id Failure.Configuration_refused "duplicate slot";
      Http_exhausted
    | Ok snapshot ->
      match Exact.start_flow ~admission_class snapshot with
      | Error (Exact.Flow_id_generation_failed detail) ->
        note "http" Failure.Transient detail;
        Http_exhausted
      | Ok attempt ->
        match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
        | None, _ | _, None ->
          note "http" Failure.Transient "the server execution context is unavailable";
          Http_exhausted
        | Some net, Some clock ->
          let slot_of (receipt : Exact.flow_attempt_receipt) = receipt.visit.identity.candidate_id in
          let execution_failed (receipt : Exact.flow_attempt_receipt) (error : Exact.execution_error) =
            note (slot_of receipt) (Failure.execution error.cause)
              (Exact.execution_error_to_string ~raw_response_to_string:raw_excerpt error)
          in
          let rejected rejection =
            note (Exact.candidate_rejection_identity rejection).candidate_id (Failure.candidate rejection)
              (Exact.candidate_rejection_to_string rejection)
          in
          let check success =
            let raw = (Exact.flow_success_output success).output in
            match validate raw with
            | Ok output -> Exact.Accept output
            | Error detail ->
              note (slot_of (Exact.flow_success_candidate success)) Failure.Output_unusable
                ("the answer does not match the declared schema: " ^ detail);
              Exact.Reject_and_advance detail
          in
          let flow =
            Exact_lane_slot_capture.flow attempt (fun () ->
            Exact.execute_flow_once ~net ~clock
              ~before_measurement_dispatch:(fun _ -> Eio.Fiber.check (); before_dispatch Addon.Measurement)
              ~on_measurement_terminal:(fun _ -> Ok ())
              ~before_dispatch:(fun _ -> Eio.Fiber.check (); before_dispatch Addon.Generation)
              ~before_advance:(fun ~failed ~next:_ ->
                Eio.Fiber.check ();
                (match failed with
                 | Exact.Flow_candidate_execution_failed { candidate; cause } -> execution_failed candidate cause
                 | Exact.Flow_candidate_rejected rejection -> rejected rejection);
                Ok ())
              ~validate:check attempt)
          in
          capture_http (match flow with
            | Ok success -> Receipt.http_success success ~rejection_to_string:Fun.id
            | Error error -> Receipt.http_failure ~callback_error_to_string:Fun.id
                ~rejection_to_string:Fun.id error);
          Runtime_exact_lane_backpressure.observe ~resolved flow;
          match flow with
          | Ok success ->
            let transport = success.transport_success in
            Http_answered
              { output = success.accepted
              ; slot = slot_of (Exact.flow_success_candidate transport)
              ; usage = Option.map usage_of_api (Exact.flow_success_output transport).usage
              }
          | Error (Exact.Flow_semantic_candidates_exhausted _) -> Http_exhausted
          | Error (Exact.Flow_execution_terminal { cause; _ }) ->
            (match cause with
             | Exact.Flow_exact_execution_failed { candidate; cause = error; _ } -> execution_failed candidate error
             | Exact.Flow_candidates_exhausted { rejection; _ } -> rejected rejection
             | Exact.Flow_attempt_already_started _ | Exact.Flow_attempt_start_failed _
             | Exact.Flow_measurement_start_failed _ | Exact.Flow_before_measurement_dispatch_callback_failed _
             | Exact.Flow_measurement_terminal_callback_failed _ | Exact.Flow_before_dispatch_callback_failed _
             | Exact.Flow_before_advance_callback_failed _ ->
               (* Bookkeeping that stopped this flow says nothing about the
                  provider or the input. *)
               note "http" Failure.Transient
                 (Exact.flow_execution_error_to_string ~callback_error_to_string:Fun.id
                    ~raw_response_to_string:raw_excerpt cause));
            (match Exact.flow_execution_terminal_kind cause with
             | Exact.Advanceable_candidates_exhausted -> Http_exhausted
             | Exact.Non_advanceable_terminal -> Http_stopped)

let cli_failure_slot = function
  | Keeper_lane_cli_oneshot.Unknown_runtime { runtime_id }
  | Keeper_lane_cli_oneshot.Not_an_official_client { runtime_id }
  | Keeper_lane_cli_oneshot.Execution_failed { runtime_id; _ }
  | Keeper_lane_cli_oneshot.Invalid_json_output { runtime_id; _ }
  | Keeper_lane_cli_oneshot.Invalid_domain_output { runtime_id; _ }
  | Keeper_lane_cli_oneshot.Held { runtime_id; _ } -> runtime_id

let cli_prompt messages =
  let rec texts acc = function
    | [] -> Ok (String.concat "\n\n" (List.rev acc))
    | { Addon.role = User; text } :: rest -> texts (text :: acc) rest
    | { Addon.role = Assistant; text = _ } :: _ -> Error ()
  in
  texts [] messages

let call ~before_dispatch ~admission_class ~cli_runner ~base_path
    ~(ordered : Runtime_exact_lane_backpressure.ordered) ~schema (request : Addon.request) ~validate =
  let resolved = ordered.lane in
  let held_http =
    List.map (fun (held : Runtime_exact_lane_backpressure.held_slot) -> held.slot_id) ordered.held_http
  in
  let http=ref (Receipt.http_not_started ~detail:"no HTTP generation flow started") in
  let visited=ref [] and dispatched=ref [] and cli_failures=ref [] in
  let failures = ref [] in
  let note slot failure detail = failures := { slot; failure; detail } :: !failures in
  (* A held slot ends this call as a slot that refused for its account's rest
     would, minus the call (RFC-exact-lane-waits-for-a-stated-reset R5): it
     may pass once its time comes, so [ending] keeps the request open even if
     every walked slot refuses the input. *)
  List.iter
    (fun ({ slot_id; until } : Runtime_exact_lane_backpressure.held_slot) ->
       note slot_id Failure.Transient
         ("not called: its provider stated it waits until "
          ^ Masc_domain.iso8601_of_unix_seconds until))
    ordered.held_http;
  let requirement = Exact.make_output_requirement ~schema ~minimum_guarantee:Exact.Json_syntax in
  let messages =
    Option.to_list
      (Option.map
         (fun system -> Llm_provider.Types.make_message ~role:System [ Llm_provider.Types.text_block system ])
         request.system)
    @ List.map
        (fun (message : Addon.message) ->
           let role = match message.role with User -> Llm_provider.Types.User | Assistant -> Llm_provider.Types.Assistant in
           Llm_provider.Types.make_message ~role [ Llm_provider.Types.text_block message.text ])
        request.messages
  in
  let ended () = ending (List.rev !failures) in
  let complete cli_result outcome =
    let cli=Receipt.cli ~visited:(List.rev !visited) ~dispatched:(List.rev !dispatched) ~failures:(List.rev !cli_failures) ~result:cli_result in
    (* The receipt compares the walked candidates with [declared_http] minus
       [excluded_http] in order, so the walked slots come first and the held
       ones, which no flow saw, follow as exclusions. *)
    let receipt=match Receipt.make_v2
      ~declared_http:(List.map (fun (slot : Registry.selected_slot) -> slot.slot_id) resolved.selected_slots
                      @ held_http)
      ~excluded_http:held_http ~declared_cli:resolved.cli_slots ~http:!http ~cli with
      | Ok receipt -> receipt
      | Error detail -> invalid_arg ("invalid original Addon walk: " ^ detail) in
    {Addon.outcome;receipt} in
  match execute_http ~before_dispatch ~admission_class ~note ~capture_http:(fun captured -> http:=captured)
    ~resolved ~requirement ~messages ~validate with
  | Http_answered { output; slot; usage } -> complete Receipt.Not_reached (Addon.Call_ended (Addon.Answered { output; slot; usage }))
  | Http_stopped -> complete Receipt.Not_reached (ended ())
  | Http_exhausted ->
    Eio.Fiber.check ();
    match resolved.cli_slots with
    | [] -> complete Receipt.Not_reached (ended ())
    | cli_slots ->
      match cli_prompt request.messages with
      | Error () ->
        List.iter (fun slot -> note slot Failure.Configuration_refused
          "a one-shot CLI cannot preserve assistant conversation turns") cli_slots;
        complete Receipt.Prompt_unavailable (ended ())
      | Ok prompt ->
      match
        Exact_lane_slot_capture.walk_cli_gated ?runner:cli_runner
          ~before_dispatch:(fun () -> before_dispatch Addon.Generation) ~base_dir:base_path ~cli_slots
          ~system_prompt:(Option.value request.system ~default:"") ~requirement
          ~prompt ~validate
          ~observe:(function
            | Keeper_lane_cli_oneshot.Dispatching {runtime_id} -> dispatched:=runtime_id::!dispatched
            | Raw_response _ -> ())
          ~on_failure:(fun failure ->
            visited:=cli_failure_slot failure::!visited;
            cli_failures:=failure::!cli_failures;
            note (cli_failure_slot failure) (Failure.cli_failure failure)
              (Keeper_lane_cli_oneshot.failure_to_string failure)) ()
      with
      | Ok (slot, output) ->
        visited:=slot::!visited;
        complete (Receipt.Answered slot)
          (Addon.Call_ended (Addon.Answered { output; slot; usage = None }))
      | Error (Keeper_lane_cli_oneshot.Slots_exhausted _cli_failures) -> complete Receipt.Exhausted (ended ())
      | Error (Keeper_lane_cli_oneshot.Stopped_before_dispatch { runtime_id; failures = _; stop = detail }) ->
        (* The guard refused before this slot was sent to. Nothing was sent and
           no other client is tried, so the request stays open, as it does when
           the guard refuses an HTTP slot. *)
        visited:=runtime_id::!visited;
        note runtime_id Failure.Transient detail;
        complete (Receipt.Stopped_before_dispatch runtime_id) (ended ())

let resolve ~lane_key =
  match Registry.current () with
  | Error error -> Error (Addon.Lane_registry_unavailable { detail = Registry.publication_error_to_string error })
  | Ok registry ->
    match Registry.resolve_lane registry ~lane_id:lane_key with
    | Error (Registry.Exact_lane_unconfigured _) -> Error Addon.Lane_unconfigured
    | Error (Registry.Exact_lane_off _) -> Error Addon.Lane_off
    | Error (Registry.No_admitted_lane_slots _) -> Error Addon.No_admitted_slots
    | Ok { Registry.selected_slots = []; cli_slots = []; _ } -> Error Addon.No_admitted_slots
    | Ok resolved -> Ok resolved

(* The earliest stated time when no slot of either kind may be called now.
   [resolve] admits a lane only with a slot, and both orders keep every slot
   in [walk] or [held], so an empty walk on both sides has a held slot. *)
let every_slot_held ({ lane; held_http } : Runtime_exact_lane_backpressure.ordered) =
  let { Runtime_candidate_standing.walk = cli_walk; held = cli_held } =
    Keeper_lane_cli_oneshot.order_slots lane.Registry.cli_slots
  in
  match lane.Registry.selected_slots, cli_walk with
  | _ :: _, _ | [], _ :: _ -> None
  | [], [] ->
    (match
       List.map (fun (held : Runtime_exact_lane_backpressure.held_slot) -> held.until) held_http
       @ List.map snd cli_held
     with
     | [] -> None
     | first :: rest -> Some (List.fold_left Float.min first rest))

let runner_with ~cli_runner ~base_path : Addon.runner =
  fun ~before_dispatch ~admission_class ~lane_key ~schema request ->
  Result.bind (resolve ~lane_key) (fun resolved ->
    let ordered = Runtime_exact_lane_backpressure.order resolved in
    match every_slot_held ordered with
    | Some until -> Error (Addon.Every_slot_held { until })
    | None ->
      Ok (fun ~validate ->
        call ~before_dispatch ~admission_class ~cli_runner ~base_path ~ordered ~schema request ~validate))

let runner ~base_path = runner_with ~cli_runner:None ~base_path
let authorize_request ~base_path ~store ~declaration_id ~package request =
  let* curator=Server_workspace_memory_addon_validation.authorize
    ~base_path ~store ~declaration_id ~package request in
  let* librarian=Server_librarian_addon_validation.authorize
    ~base_path ~store ~declaration_id ~package request in
  match librarian with
  | None -> Ok {Addon.admission_class=Agent_core.Llm_provider.Admission_class.Standard;
      validate_output=curator; before_dispatch=(fun () -> Ok ()); with_execution=(fun run -> run ())}
  | Some librarian ->
    Ok {Addon.admission_class=Agent_core.Llm_provider.Admission_class.Background;
      validate_output=(fun answer -> let* ()=curator answer in librarian.validate_output answer);
      before_dispatch=librarian.before_dispatch;with_execution=librarian.with_execution}

module For_testing = struct
  let runner ~base_path ~cli_runner = runner_with ~cli_runner:(Some cli_runner) ~base_path
end
