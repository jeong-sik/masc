type lane_configuration =
  | Configured of
      { admitted_slots : string list
      ; cli_slots : string list
      ; dropped_slots : string list
      ; admission_error : string option
      }
  | Unconfigured of string
  | Registry_unavailable of string

type terminal_kind =
  | Succeeded
  | Failed
  | Cancelled

type observed_terminal =
  { kind : terminal_kind
  ; elapsed_s : float
  ; elapsed_measured : bool
    (** [false] when the duration was synthesised rather than measured — a
        server-restart orphan is written back as Failed with
        [now - started_at], an arbitrarily large value that must not enter
        the latency percentile (lane audit W7). It still bounds
        [last_terminal_at]. *)
  ; selected_slot : string option
  }

type observed_status =
  | Running
  | Terminal of observed_terminal

type observed_run =
  { lane_id : string
  ; started_at : float
  ; status : observed_status
  }

type lane_spec =
  { lane_id : string
  ; label : string
  ; required : bool
  }

let lane_specs =
  [ { lane_id = Exact_lane_run_registry.lane_key Exact_lane_run_registry.Board_attention
    ; label = "Board Attention"
    ; required = true
    }
  ; { lane_id = Exact_lane_run_registry.lane_key Exact_lane_run_registry.Hitl_auto_judge
    ; label = "HITL Auto Judge"
    ; required = true
    }
  ; { lane_id = Exact_lane_run_registry.lane_key Exact_lane_run_registry.Librarian
    ; label = "Librarian"
    ; required = false
    }
  ; { lane_id = Runtime.verifier_exact_lane_id; label = "Verifier"; required = false }
  ]
;;

let terminal_kind_to_string = function
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"
;;

let json_float_opt = function
  | None -> `Null
  | Some value -> `Float value
;;

let json_string_opt = function
  | None -> `Null
  | Some value -> `String value
;;

let terminal_of_exact_outcome = function
  | Exact_lane_run_registry.Succeeded -> Succeeded
  | Exact_lane_run_registry.Cancelled -> Cancelled
  | Exact_lane_run_registry.Failed _ -> Failed
;;

let observed_exact_run (run : Exact_lane_run_registry.run) =
  let status =
    match run.status with
    | Exact_lane_run_registry.Running -> Running
    | Exact_lane_run_registry.Completed { outcome; elapsed_s; selected_slot; _ } ->
      let elapsed_measured =
        match outcome with
        | Exact_lane_run_registry.Failed { code; _ } ->
          not (String.equal code "server_restarted")
        | Exact_lane_run_registry.Succeeded
        | Exact_lane_run_registry.Cancelled -> true
      in
      Terminal
        { kind = terminal_of_exact_outcome outcome
        ; elapsed_s
        ; elapsed_measured
        ; selected_slot
        }
    | Exact_lane_run_registry.Completion_persistence_failed
        { elapsed_s; selected_slot; _ } ->
      Terminal { kind = Failed; elapsed_s; elapsed_measured = true; selected_slot }
  in
  { lane_id = Exact_lane_run_registry.lane_key run.lane; started_at = run.started_at; status }
;;

(* Success for this lane means A VERDICT WAS PRODUCED. [Not_reviewed] is
   emitted when every evaluator slot was exhausted without a verdict
   (Evaluator_unavailable / Invalid_verdict) — counting it as succeeded made
   the panel unreadable as a judgement metric (lane audit W5). *)
let terminal_of_verification_outcome = function
  | Verification_run_registry.Infrastructure_unavailable _
  | Verification_run_registry.Commit_failed _
  | Verification_run_registry.Raised _
  | Verification_run_registry.Not_reviewed _ -> Failed
  | Verification_run_registry.Approved _
  | Verification_run_registry.Rejected _ -> Succeeded
  | Verification_run_registry.Review_cancelled _ -> Cancelled
;;

let observed_verification_run (run : Verification_run_registry.run) =
  let status =
    match run.status with
    | Verification_run_registry.Running -> Running
    | Verification_run_registry.Completed
        { outcome; evaluator_runtime; elapsed_s; _ } ->
      Terminal
        { kind = terminal_of_verification_outcome outcome
        ; elapsed_s
        ; elapsed_measured = true
        ; selected_slot = evaluator_runtime
        }
  in
  { lane_id = Runtime.verifier_exact_lane_id; started_at = run.started_at; status }
;;

let terminal_of_goal_verification_outcome = function
  | Goal_verification_run_registry.Raised _
  | Goal_verification_run_registry.Deferred _ -> Failed
  | Goal_verification_run_registry.Reviewed
  | Goal_verification_run_registry.Committed -> Succeeded
  | Goal_verification_run_registry.Review_cancelled _ -> Cancelled
;;

let observed_goal_verification_run (run : Goal_verification_run_registry.run) =
  let status =
    match run.status with
    | Goal_verification_run_registry.Running -> Running
    | Goal_verification_run_registry.Completed
        { outcome; evaluator_runtime; elapsed_s; _ } ->
      Terminal
        { kind = terminal_of_goal_verification_outcome outcome
        ; elapsed_s
        ; elapsed_measured = true
        ; selected_slot = evaluator_runtime
        }
  in
  { lane_id = Runtime.verifier_exact_lane_id; started_at = run.started_at; status }
;;

let p50 values =
  match List.sort Float.compare values with
  | [] -> None
  | sorted -> Some (List.nth sorted (List.length sorted / 2))
;;

let latest_run runs =
  List.fold_left
    (fun latest run ->
       match latest with
       | None -> Some run
       | Some current when run.started_at > current.started_at -> Some run
       | Some _ -> latest)
    None
    runs
;;

let latest_terminal_run terminal_runs =
  List.fold_left
    (fun latest ((run, terminal) as candidate) ->
       match latest with
       | None -> Some candidate
       | Some (current_run, current_terminal)
         when run.started_at +. terminal.elapsed_s
              > current_run.started_at +. current_terminal.elapsed_s ->
         Some candidate
       | Some _ -> latest)
    None
    terminal_runs
;;

let slot_counts runs =
  let counts = Hashtbl.create 8 in
  List.iter
    (fun run ->
       match run.status with
       | Running -> ()
       | Terminal { selected_slot = None; _ } -> ()
       | Terminal { selected_slot = Some slot_id; _ } ->
         let previous_count =
           match Hashtbl.find_opt counts slot_id with
           | None -> 0
           | Some count -> count
         in
         Hashtbl.replace counts slot_id (1 + previous_count))
    runs;
  Hashtbl.to_seq counts
  |> List.of_seq
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
;;

let lane_json
      ~now:_
      ~resolve_lane
      (all_runs : observed_run list)
      (spec : lane_spec)
  =
  let runs =
    List.filter
      (fun (run : observed_run) -> String.equal run.lane_id spec.lane_id)
      all_runs
  in
  let running_count =
    List.fold_left (fun count run -> match run.status with Running -> count + 1 | Terminal _ -> count) 0 runs
  in
  let terminal_runs =
    List.filter_map
      (fun run -> match run.status with Running -> None | Terminal terminal -> Some (run, terminal))
      runs
  in
  let count_kind kind =
    List.fold_left
      (fun count (_, terminal) -> if terminal.kind = kind then count + 1 else count)
      0
      terminal_runs
  in
  let succeeded_count = count_kind Succeeded in
  let failed_count = count_kind Failed in
  let cancelled_count = count_kind Cancelled in
  let elapsed_values =
    List.filter_map
      (fun (_, terminal) ->
         if terminal.elapsed_measured then Some terminal.elapsed_s else None)
      terminal_runs
  in
  let latest = latest_run runs in
  let latest_terminal = latest_terminal_run terminal_runs in
  let latest_terminal_kind =
    match latest_terminal with
    | None -> None
    | Some (_, terminal) -> Some terminal.kind
  in
  let configuration = resolve_lane spec.lane_id in
  let configured, config_state, admitted_slots, admission_error =
    match configuration with
    | Configured { admitted_slots; cli_slots; dropped_slots; admission_error } ->
      Some true,
      (if admitted_slots = [] && cli_slots = [] then "degraded" else "ready"),
      (admitted_slots, cli_slots, dropped_slots),
      admission_error
    | Unconfigured error -> Some false, "unconfigured", ([], [], []), Some error
    | Registry_unavailable error -> None, "unavailable", ([], [], []), Some error
  in
  let admitted_slots, cli_slots, dropped_slots = admitted_slots in
  let status =
    match configuration with
    | Registry_unavailable _ | Unconfigured _ -> "unavailable"
    | Configured { admitted_slots = []; cli_slots = []; _ } -> "degraded"
    | Configured _ when running_count > 0 -> "running"
    | Configured _ when runs = [] -> "no_retained_observation"
    | Configured _ ->
      (match latest_terminal_kind with Some Failed -> "degraded" | Some _ | None -> "idle")
  in
  let last_started_at = Option.map (fun run -> run.started_at) latest in
  let last_terminal_at =
    Option.map
      (fun (run, terminal) -> run.started_at +. terminal.elapsed_s)
      latest_terminal
  in
  `Assoc
    [ "lane_id", `String spec.lane_id
    ; "label", `String spec.label
    ; "required", `Bool spec.required
    ; "observation_only", `Bool true
    ; "configured", (match configured with None -> `Null | Some value -> `Bool value)
    ; "configuration_state", `String config_state
    ; "admitted_slots", `List (List.map (fun slot -> `String slot) admitted_slots)
    ; "cli_slots", `List (List.map (fun slot -> `String slot) cli_slots)
    ; "dropped_slots", `List (List.map (fun slot -> `String slot) dropped_slots)
    ; "admission_error", json_string_opt admission_error
    ; "status", `String status
    ; "retained_run_count", `Int (List.length runs)
    ; "running_count", `Int running_count
    ; "succeeded_count", `Int succeeded_count
    ; "failed_count", `Int failed_count
    ; "cancelled_count", `Int cancelled_count
    ; "last_started_at", json_float_opt last_started_at
    ; "last_terminal_at", json_float_opt last_terminal_at
    ; ( "last_outcome"
      , match latest_terminal_kind with
        | None -> `Null
        | Some kind -> `String (terminal_kind_to_string kind) )
    ; "p50_elapsed_s", json_float_opt (p50 elapsed_values)
    ; ( "selected_slots"
      , `List
          (List.map
             (fun (slot_id, count) ->
                `Assoc [ "slot_id", `String slot_id; "count", `Int count ])
             (slot_counts runs)) )
    ]
;;

let snapshot_json_with
      ~now
      ~resolve_lane
      ~exact_runs_total
      ~exact_runs
      ~verification_runs
      ~goal_verification_runs
  =
  let all_runs =
    List.map observed_exact_run exact_runs
    @ List.map observed_verification_run verification_runs
    @ List.map observed_goal_verification_run goal_verification_runs
  in
  let exact_run_projection_count = List.length exact_runs in
  let exact_run_source_total = max exact_run_projection_count exact_runs_total in
  `Assoc
    [ "schema", `String "masc.standalone_llm_lanes.v1"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "observed_at_unix", `Float now
    ; "observation_only", `Bool true
    ; "exact_run_projection_count", `Int exact_run_projection_count
    ; "exact_run_source_total", `Int exact_run_source_total
    ; ( "exact_run_projection_truncated"
      , `Bool (exact_run_projection_count < exact_run_source_total) )
    ; "lanes", `List (List.map (lane_json ~now ~resolve_lane all_runs) lane_specs)
    ]
;;

let live_lane_configuration registry lane_id =
  (* Publication keeps declared-but-inadmissible slots as typed observations;
     surfacing them per lane is what lets an operator distinguish "configured
     single" from "configured double, one silently dropped" without going
     back to the boot log. *)
  let dropped_slots =
    Runtime_exact_output_registry.rejected_slots registry
    |> List.filter_map
         (fun (rejected : Runtime_exact_output_registry.rejected_slot) ->
            if String.equal rejected.lane_id lane_id
            then Some rejected.slot_id
            else None)
  in
  match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
  | Ok { selected_slots; cli_slots } ->
    Configured
      { admitted_slots =
          List.map
            (fun (slot : Runtime_exact_output_registry.selected_slot) -> slot.slot_id)
            selected_slots
      ; cli_slots
      ; dropped_slots
      ; admission_error = None
      }
  | Error (Runtime_exact_output_registry.Exact_lane_unconfigured _) ->
    Unconfigured
      (Runtime_exact_output_registry.lane_resolution_error_to_string
         (Runtime_exact_output_registry.Exact_lane_unconfigured { lane_id }))
  | Error (Runtime_exact_output_registry.No_admitted_lane_slots _) ->
    Configured
      { admitted_slots = []
      ; cli_slots = []
      ; dropped_slots
      ; admission_error =
          Some
            (Runtime_exact_output_registry.lane_resolution_error_to_string
               (Runtime_exact_output_registry.No_admitted_lane_slots { lane_id }))
      }
;;

let snapshot_json () =
  let registry_result = Runtime_exact_output_registry.current () in
  let resolve_lane lane_id =
    match registry_result with
    | Ok registry -> live_lane_configuration registry lane_id
    | Error error ->
      Registry_unavailable
        (Runtime_exact_output_registry.publication_error_to_string error)
  in
  (* [list_runs] is already newest-first from the registry's immutable
     projection. Do not call [recent_runs] here: it sorts the entire list
     again, and persistence-failed core rows can remain Running beyond normal
     completed retention. Traverse once for the source count and take only the
     bounded prefix used by this matrix. *)
  let exact_run_source =
    Exact_lane_run_registry.list_runs (Exact_lane_run_registry.global ())
  in
  let rec take_exact_runs remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | run :: rest -> take_exact_runs (remaining - 1) (run :: acc) rest
  in
  let exact_runs =
    take_exact_runs
      Exact_lane_run_registry.max_completed_retained
      []
      exact_run_source
  in
  snapshot_json_with
    ~now:(Time_compat.now ())
    ~resolve_lane
    ~exact_runs_total:(List.length exact_run_source)
    ~exact_runs
    ~verification_runs:
      (Verification_run_registry.list_runs (Verification_run_registry.global ()))
    ~goal_verification_runs:
      (Goal_verification_run_registry.list_runs
         (Goal_verification_run_registry.global ()))
;;

module For_testing = struct
  let snapshot_json_with = snapshot_json_with
end
