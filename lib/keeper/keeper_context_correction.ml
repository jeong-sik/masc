module Exact_output = Agent_sdk.Exact_output

let ( let* ) = Result.bind
let lane_id = "context_correction_exact"
let state_context_key = "keeper.context_correction.v1"
let state_version = 1
let max_closed_units = 16
let max_closed_bytes = 65_536

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

type submission = Unavailable | Coalesced | Submitted

let executor_sw : Eio.Switch.t option ref = ref None
let executor_mu = Stdlib.Mutex.create ()
let in_flight_keys : (string, unit) Hashtbl.t = Hashtbl.create 16

let init ~sw =
  Stdlib.Mutex.protect executor_mu (fun () -> executor_sw := Some sw)
;;

let executor_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path keeper_name
;;

let release_key key =
  Stdlib.Mutex.protect executor_mu (fun () -> Hashtbl.remove in_flight_keys key)
;;

let submit ~base_path ~keeper_name job =
  let key = executor_key ~base_path ~keeper_name in
  let admitted =
    Stdlib.Mutex.protect executor_mu (fun () ->
      match !executor_sw with
      | None -> `Unavailable
      | Some _ when Hashtbl.mem in_flight_keys key -> `Coalesced
      | Some sw ->
        Hashtbl.add in_flight_keys key ();
        `Admitted sw)
  in
  match admitted with
  | `Unavailable -> Unavailable
  | `Coalesced -> Coalesced
  | `Admitted sw ->
    (try
       Eio.Fiber.fork ~sw (fun () ->
         Fun.protect
           ~finally:(fun () -> release_key key)
           (fun () ->
              try job () with
              | Eio.Cancel.Cancelled _ -> ()
              | exn ->
                Log.Keeper.warn
                  ~keeper_name
                  "context correction detached fiber failed: %s"
                  (Printexc.to_string exn)));
       Submitted
     with
     | _ ->
       release_key key;
       Unavailable)
;;

let canonical_messages messages =
  messages
  |> List.map Keeper_context_core.message_to_json
  |> fun values -> Yojson.Safe.to_string (`List values)
;;

type marker =
  { semantic_message_count : int; semantic_state_sha256 : string;
    accepted_closed_unit_count : int; accepted_closed_prefix_sha256 : string }

let genesis_marker =
  { semantic_message_count = 0
  ; semantic_state_sha256 = sha256 "[]"
  ; accepted_closed_unit_count = 0
  ; accepted_closed_prefix_sha256 = sha256 "context-correction:v1:root"
  }
;;

let marker_to_json marker =
  `Assoc
    [ "version", `Int state_version
    ; "semantic_message_count", `Int marker.semantic_message_count
    ; "semantic_state_sha256", `String marker.semantic_state_sha256
    ; "accepted_closed_unit_count", `Int marker.accepted_closed_unit_count
    ; ( "accepted_closed_prefix_sha256"
      , `String marker.accepted_closed_prefix_sha256 )
    ]
;;

type preserved_reason =
  | Control_checkpoint | Raw_save_superseded | Start_checkpoint_unavailable
  | Fresh_state_required | Marker_corrupt | Start_prefix_mismatch
  | No_closed_delta | Closed_unit_over_budget | Network_unavailable
  | Clock_unavailable | Exact_lane_unavailable | Exact_flow_failed
  | Semantic_output_invalid | Deadline_exceeded
  | Deadline_exceeded_before_cas | Cas_conflict | Cas_not_installed

let preserved_reason_to_string = function
  | Control_checkpoint -> "control_checkpoint"
  | Raw_save_superseded -> "raw_save_superseded"
  | Start_checkpoint_unavailable -> "start_checkpoint_unavailable"
  | Fresh_state_required -> "fresh_state_required"
  | Marker_corrupt -> "marker_corrupt"
  | Start_prefix_mismatch -> "start_prefix_mismatch"
  | No_closed_delta -> "no_closed_delta"
  | Closed_unit_over_budget -> "closed_unit_over_budget"
  | Network_unavailable -> "network_unavailable"
  | Clock_unavailable -> "clock_unavailable"
  | Exact_lane_unavailable -> "exact_lane_unavailable"
  | Exact_flow_failed -> "exact_flow_failed"
  | Semantic_output_invalid -> "semantic_output_invalid"
  | Deadline_exceeded -> "deadline_exceeded"
  | Deadline_exceeded_before_cas -> "deadline_exceeded_before_cas"
  | Cas_conflict -> "cas_conflict"
  | Cas_not_installed -> "cas_not_installed"
;;

let marker_of_json = function
  | `Assoc fields ->
    let expected = [ "accepted_closed_prefix_sha256"; "accepted_closed_unit_count";
      "semantic_message_count"; "semantic_state_sha256"; "version" ] in
    let keys = List.map fst fields |> List.sort String.compare in
    let int_field name = match List.assoc_opt name fields with
      | Some (`Int value) -> Some value | _ -> None in
    let string_field name = match List.assoc_opt name fields with
      | Some (`String value) -> Some value | _ -> None in
    (match
       ( keys = expected
       , int_field "version"
       , int_field "semantic_message_count"
       , string_field "semantic_state_sha256"
       , int_field "accepted_closed_unit_count"
       , string_field "accepted_closed_prefix_sha256" )
     with
     | ( true
       , Some version
       , Some semantic_message_count
       , Some semantic_state_sha256
       , Some accepted_closed_unit_count
       , Some accepted_closed_prefix_sha256 )
       when version = state_version && semantic_message_count >= 0
            && semantic_message_count <= 1 && accepted_closed_unit_count >= 0
            && String.length semantic_state_sha256 = 64
            && String.length accepted_closed_prefix_sha256 = 64 ->
       Ok
         { semantic_message_count
         ; semantic_state_sha256
         ; accepted_closed_unit_count
         ; accepted_closed_prefix_sha256
         }
     | _ -> Error Marker_corrupt)
  | _ -> Error Marker_corrupt
;;

let marker_of_context context =
  match
    Agent_sdk.Context.get_scoped
      context
      Agent_sdk.Context.Session
      state_context_key
  with
  | None -> Error Fresh_state_required
  | Some json -> marker_of_json json
;;

let set_marker context marker =
  Agent_sdk.Context.set_scoped
    context
    Agent_sdk.Context.Session
    state_context_key
    (marker_to_json marker)
;;

type start = Fresh | Existing of Keeper_checkpoint_store.exact_checkpoint_snapshot
  | Unavailable

let capture_start ~session_dir ~session_id =
  match
    Keeper_checkpoint_store.load_oas_exact_snapshot ~session_dir ~session_id
  with
  | Ok snapshot -> Existing snapshot
  | Error Keeper_checkpoint_store.Ref_not_found -> Fresh
  | Error _ -> Unavailable
;;

let start_marker = function
  | Fresh -> Ok genesis_marker
  | Unavailable -> Error Start_checkpoint_unavailable
  | Existing snapshot ->
    snapshot
    |> Keeper_checkpoint_store.exact_snapshot_checkpoint
    |> fun checkpoint -> marker_of_context checkpoint.context
;;

let bind_start_context start context =
  match start_marker start with
  | Ok marker -> set_marker context marker
  | Error _ -> ()
;;

let prepare_raw_checkpoint ~start (checkpoint : Agent_sdk.Checkpoint.t) =
  match start_marker start with
  | Error _ -> checkpoint
  | Ok marker ->
    let context = Agent_sdk.Context.copy checkpoint.context in
    set_marker context marker;
    { checkpoint with Agent_sdk.Checkpoint.context }
;;

let rec split_at count acc values =
  if count = 0
  then Ok (List.rev acc, values)
  else
    match values with
    | [] -> Error Marker_corrupt
    | value :: rest -> split_at (count - 1) (value :: acc) rest
;;

let messages_of_closed_unit = function
  | Keeper_compaction_unit.Ordinary_message message -> [ message ]
  | Keeper_compaction_unit.Closed_tool_cycle messages -> messages
;;

let select_closed_units units =
  let rec loop count bytes selected = function
    | [] -> Ok (List.rev selected, [])
    | unit :: rest ->
      let unit_bytes =
        unit |> messages_of_closed_unit |> canonical_messages |> String.length
      in
      if count = 0 && unit_bytes > max_closed_bytes
      then Error Closed_unit_over_budget
      else if count >= max_closed_units || bytes + unit_bytes > max_closed_bytes
      then Ok (List.rev selected, unit :: rest)
      else loop (count + 1) (bytes + unit_bytes) (unit :: selected) rest
  in
  loop 0 0 [] units
;;

let advance_anchor marker units =
  List.fold_left
    (fun (count, digest) unit ->
       let canonical = unit |> messages_of_closed_unit |> canonical_messages in
       count + 1, sha256 (digest ^ "\000" ^ canonical))
    ( marker.accepted_closed_unit_count
    , marker.accepted_closed_prefix_sha256 )
    units
;;

let prepare_candidate
      ~marker
      ~(raw_checkpoint : Agent_sdk.Checkpoint.t)
      ~semantic_context
  =
  let semantic_context = String.trim semantic_context in
  if semantic_context = ""
  then Error Semantic_output_invalid
  else
    let* semantic_messages, backlog =
      split_at marker.semantic_message_count [] raw_checkpoint.messages
    in
    if not (String.equal marker.semantic_state_sha256 (sha256 (canonical_messages semantic_messages)))
    then Error Marker_corrupt
    else
      let* partition =
        Keeper_compaction_unit.partition backlog
        |> Result.map_error (fun _ -> Marker_corrupt)
      in
      let* selected, remaining =
        select_closed_units partition.closed_prefix
      in
      if selected = []
      then Error No_closed_delta
      else
        let semantic_message = Agent_sdk.Types.system_msg semantic_context in
        let remaining_messages =
          List.concat_map messages_of_closed_unit remaining
          @ partition.protected_suffix
        in
        let count, digest = advance_anchor marker selected in
        let marker =
          { semantic_message_count = 1
          ; semantic_state_sha256 = sha256 (canonical_messages [ semantic_message ])
          ; accepted_closed_unit_count = count
          ; accepted_closed_prefix_sha256 = digest
          }
        in
        let context = Agent_sdk.Context.copy raw_checkpoint.context in
        set_marker context marker;
        Ok
          ( { raw_checkpoint with
              Agent_sdk.Checkpoint.messages =
                semantic_message :: remaining_messages
            ; context
            ; working_context = None
            }
          , marker )
;;

type provenance =
  { slot_id : string; call_id : string; plan_fingerprint : string;
    request_body_sha256 : string }

type outcome =
  | Applied of
      { checkpoint : Agent_sdk.Checkpoint.t; raw_ref : Keeper_checkpoint_ref.t;
        installed_ref : Keeper_checkpoint_ref.t; provenance : provenance }
  | Preserved of
      { checkpoint : Agent_sdk.Checkpoint.t; raw_ref : Keeper_checkpoint_ref.t;
        reason : preserved_reason }
  | Skipped of preserved_reason

let preserved checkpoint raw_ref reason =
  Preserved { checkpoint; raw_ref; reason }
;;

let checkpoint_of_outcome = function
  | Applied { checkpoint; _ } | Preserved { checkpoint; _ } -> Some checkpoint
  | Skipped _ -> None
;;

let require_equal left right =
  if String.equal left right then Ok () else Error Semantic_output_invalid
;;

let semantic_of_success flow_success =
  let selected = Exact_output.flow_success_candidate flow_success in
  let success = Exact_output.flow_success_output flow_success in
  let call_id = Exact_output.call_id_to_string success.call_id in
  let selected_call_id =
    selected.receipt
    |> Exact_output.receipt_call_id
    |> Exact_output.call_id_to_string
  in
  let success_call_id =
    success.receipt
    |> Exact_output.receipt_call_id
    |> Exact_output.call_id_to_string
  in
  let plan_fingerprint =
    Exact_output.receipt_plan_fingerprint selected.receipt
  in
  let request_body_sha256 =
    Exact_output.receipt_request_body_sha256 selected.receipt
  in
  let* () = require_equal call_id selected_call_id in
  let* () = require_equal call_id success_call_id in
  let* () =
    require_equal
      plan_fingerprint
      (Exact_output.receipt_plan_fingerprint success.receipt)
  in
  let* () =
    require_equal
      request_body_sha256
      (Exact_output.receipt_request_body_sha256 success.receipt)
  in
  match success.output with
  | `Assoc [ "semantic_context", `String semantic_context ]
    when String.trim semantic_context <> "" ->
    Ok
      ( semantic_context
      , { slot_id = selected.visit.identity.candidate_id
        ; call_id
        ; plan_fingerprint
        ; request_body_sha256
        } )
  | _ -> Error Semantic_output_invalid
;;

let flow_candidates selected_slots =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (candidate :: acc) rest
       | Error _ -> Error Exact_lane_unavailable)
  in
  loop [] selected_slots
;;

let exact_schema =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; ( "properties"
      , `Assoc
          [ "semantic_context"
          , `Assoc [ "type", `String "string" ]
          ] )
    ; "required", `List [ `String "semantic_context" ]
    ]
;;

let correction_messages marker semantic_messages selected =
  let request =
    `Assoc
      [ "accepted_closed_unit_count", `Int marker.accepted_closed_unit_count
      ; "prior_semantic_messages",
        `List (List.map Keeper_context_core.message_to_json semantic_messages)
      ; ( "new_closed_units"
        , `List
            (List.map
               (fun unit ->
                  `List
                    (List.map
                       Keeper_context_core.message_to_json
                       (messages_of_closed_unit unit)))
               selected) )
      ]
  in
  [ Agent_sdk.Types.system_msg
      "Update the Keeper's semantic context from the prior semantic state and \
       the new closed turn units. Preserve decisions, constraints, goals, \
       unresolved work, durable facts, and causal context. Return only the \
       requested JSON object. Do not reproduce protocol shells."
  ; Agent_sdk.Types.user_msg (Yojson.Safe.to_string request)
  ]
;;

let execute_exact ~net ~clock ~marker ~semantic_messages ~selected =
  let* registry =
    Runtime_exact_output_registry.current ()
    |> Result.map_error (fun _ -> Exact_lane_unavailable)
  in
  let* lane =
    Runtime_exact_output_registry.resolve_lane registry ~lane_id
    |> Result.map_error (fun _ -> Exact_lane_unavailable)
  in
  let* candidates = flow_candidates lane.selected_slots in
  match candidates with
  | [] -> Error Exact_lane_unavailable
  | first :: rest ->
    let requirement =
      Exact_output.make_output_requirement
        ~schema:exact_schema
        ~minimum_guarantee:Exact_output.Json_syntax
    in
    let* snapshot =
      Exact_output.snapshot_flow
        ~first
        ~rest
        ~messages:(correction_messages marker semantic_messages selected)
        requirement
      |> Result.map_error (fun _ -> Exact_flow_failed)
    in
    let* attempt =
      Exact_output.start_flow snapshot
      |> Result.map_error (fun _ -> Exact_flow_failed)
    in
    let validate success =
      match semantic_of_success success with
      | Ok value -> Exact_output.Accept value
      | Error reason -> Exact_output.Reject_and_advance reason
    in
    (match
       Exact_output.execute_flow_once
         ~net
         ~clock
         ~before_measurement_dispatch:(fun _ -> Ok ())
         ~on_measurement_terminal:(fun _ -> Ok ())
         ~before_dispatch:(fun _ -> Ok ())
         ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
         ~validate
         attempt
     with
     | Ok success -> Ok success.accepted
     | Error
         (Exact_output.Flow_semantic_candidates_exhausted _) ->
       Error Semantic_output_invalid
     | Error (Exact_output.Flow_execution_terminal _) ->
       Error Exact_flow_failed)
;;

let classify_installation ~raw_checkpoint ~raw_ref ~candidate ~provenance = function
  | Keeper_checkpoint_store.Installed { installed_ref; _ } ->
    Applied { checkpoint = candidate; raw_ref; installed_ref; provenance }
  | Keeper_checkpoint_store.Not_installed
      { cause = Keeper_checkpoint_store.Source_changed _; _ } ->
    preserved raw_checkpoint raw_ref Cas_conflict
  | Keeper_checkpoint_store.Not_installed _ ->
    preserved raw_checkpoint raw_ref Cas_not_installed
;;

let run
      ~timeout_s
      ~keeper_name
      ~session_dir
      ~start
      ~history_messages
      ~raw_checkpoint
      ~raw_ref
  =
  let preserve = preserved raw_checkpoint raw_ref in
  let raw_checkpoint_result =
    match
      Keeper_checkpoint_store.load_oas_exact_snapshot
        ~session_dir
        ~session_id:raw_checkpoint.session_id
    with
    | Error _ -> Error Cas_not_installed
    | Ok snapshot ->
      let current_ref =
        Keeper_checkpoint_store.exact_snapshot_reference snapshot
      in
      if Keeper_checkpoint_ref.equal current_ref raw_ref
      then
        Ok (Keeper_checkpoint_store.exact_snapshot_checkpoint snapshot)
      else Error Cas_conflict
  in
  match raw_checkpoint_result with
  | Error reason -> preserve reason
  | Ok raw_checkpoint ->
  let preserve = preserved raw_checkpoint raw_ref in
  let prepared =
    let* marker = start_marker start in
    let* () =
      match start with
      | Fresh ->
        if history_messages = [] then Ok () else Error Start_prefix_mismatch
      | Unavailable -> Error Start_checkpoint_unavailable
      | Existing snapshot ->
        let checkpoint =
          Keeper_checkpoint_store.exact_snapshot_checkpoint snapshot
        in
        if checkpoint.messages = history_messages
        then Ok ()
        else Error Start_prefix_mismatch
    in
    let* raw_marker = marker_of_context raw_checkpoint.context in
    let* () = if raw_marker = marker then Ok () else Error Marker_corrupt in
    let* semantic_messages, backlog =
      split_at marker.semantic_message_count [] raw_checkpoint.messages
    in
    let* () =
      if String.equal marker.semantic_state_sha256 (sha256 (canonical_messages semantic_messages))
      then Ok ()
      else Error Marker_corrupt
    in
    let* partition =
      Keeper_compaction_unit.partition backlog
      |> Result.map_error (fun _ -> Marker_corrupt)
    in
    let* selected, _remaining = select_closed_units partition.closed_prefix in
    if selected = []
    then Error No_closed_delta
    else Ok (marker, semantic_messages, selected)
  in
  match prepared with
  | Error reason -> preserve reason
  | Ok (marker, semantic_messages, selected) ->
    (match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
     | None, _ -> preserve Network_unavailable
     | _, None -> preserve Clock_unavailable
     | Some net, Some clock ->
       let deadline = Unix.gettimeofday () +. timeout_s in
       let exact_result =
         try
           Eio.Time.with_timeout_exn clock timeout_s (fun () ->
             execute_exact ~net ~clock ~marker ~semantic_messages ~selected)
         with
         | Eio.Time.Timeout -> Error Deadline_exceeded
       in
       (match exact_result with
        | Error reason ->
          Log.Keeper.warn
            ~keeper_name
            "context correction preserved raw checkpoint reason=%s"
            (preserved_reason_to_string reason);
          preserve reason
        | Ok (semantic_context, provenance) ->
          (match prepare_candidate ~marker ~raw_checkpoint ~semantic_context with
           | Error reason -> preserve reason
           | Ok (candidate, _marker) ->
             if Unix.gettimeofday () >= deadline
             then preserve Deadline_exceeded_before_cas
             else
               Keeper_checkpoint_store.save_oas_if_source
                 ~session_dir
                 ~expected_source_ref:raw_ref
                 candidate
               |> classify_installation
                    ~raw_checkpoint
                    ~raw_ref
                    ~candidate
                    ~provenance)))
;;

let provenance_to_json provenance =
  `Assoc
    [ "slot_id", `String provenance.slot_id
    ; "call_id", `String provenance.call_id
    ; "plan_fingerprint", `String provenance.plan_fingerprint
    ; "request_body_sha256", `String provenance.request_body_sha256
    ]
;;

let outcome_to_json = function
  | Applied { raw_ref; installed_ref; provenance; _ } ->
    `Assoc
      [ "status", `String "applied"
      ; "raw_checkpoint_sha256", `String raw_ref.sha256
      ; "installed_checkpoint_sha256", `String installed_ref.sha256
      ; "receipt", provenance_to_json provenance
      ]
  | Preserved { raw_ref; reason; _ } ->
    `Assoc
      [ "status", `String "preserved"
      ; "raw_checkpoint_sha256", `String raw_ref.sha256
      ; "reason", `String (preserved_reason_to_string reason)
      ]
  | Skipped reason ->
    `Assoc
      [ "status", `String "skipped"
      ; "reason", `String (preserved_reason_to_string reason)
      ]
;;

let submission_to_json (submission : submission) =
  match submission with
  | Unavailable -> `Assoc [ "status", `String "unavailable" ]
  | Coalesced -> `Assoc [ "status", `String "coalesced" ]
  | Submitted -> `Assoc [ "status", `String "submitted" ]
;;

module For_testing = struct
  type nonrec marker = marker

  let genesis_marker = genesis_marker
  let marker_to_json = marker_to_json
  let marker_of_json = marker_of_json
  let prepare_candidate = prepare_candidate
  let classify_installation = classify_installation

  let reset_executor () =
    Stdlib.Mutex.protect executor_mu (fun () ->
      executor_sw := None;
      Hashtbl.reset in_flight_keys)
  ;;

  let in_flight ~base_path ~keeper_name =
    let key = executor_key ~base_path ~keeper_name in
    Stdlib.Mutex.protect executor_mu (fun () ->
      Hashtbl.mem in_flight_keys key)
  ;;
end
