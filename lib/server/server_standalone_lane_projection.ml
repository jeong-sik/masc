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
        the latency percentile (lane audit W7). It keeps [last_terminal_at]
        empty too: a finish time synthesised from the restart is the
        restart's clock, and the lane detail draws that as an age. *)
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
  ; purpose : string
  ; required : bool
  }

let lane_specs =
  [ { lane_id = Exact_lane_run_registry.lane_key Exact_lane_run_registry.Board_attention
    ; label = "Board Attention"
    ; purpose = "Judges one durable Board candidate for Keeper attention."
    ; required = true
    }
  ; { lane_id = Exact_lane_run_registry.lane_key Exact_lane_run_registry.Hitl_auto_judge
    ; label = "HITL Auto Judge"
    ; purpose = "Produces the structured judgment for one held approval."
    ; required = true
    }
  ; { lane_id = Exact_lane_run_registry.lane_key Exact_lane_run_registry.Librarian
    ; label = "Librarian"
    ; purpose = "Selects the next Memory OS snapshot from immutable Keeper history."
    ; required = false
    }
  ; { lane_id = Runtime.verifier_exact_lane_id
    ; label = "Verifier"
    ; purpose = "Reviews Task completion and Goal proof evidence."
    ; required = false
    }
  ]
;;

(* The overview above joins three durable registries into four lanes. The run
   drill-down must read the same set: serving only [Exact_lane_run_registry]
   made the Verifier row open an empty list even while its task and Goal
   registries held reviews, tool observations, and verdicts. Keep the source
   variant private so no caller can accidentally flatten away which durable
   record owns the detail. *)
type retained_run =
  | Exact_run of Exact_lane_run_registry.run
  | Task_verification_run of Verification_run_registry.run
  | Goal_verification_run of Goal_verification_run_registry.run

type detail_lookup =
  | Detail_found of Yojson.Safe.t
  | Detail_not_found
  | Detail_ambiguous

let retained_run_id = function
  | Exact_run run -> run.Exact_lane_run_registry.run_id
  | Task_verification_run run -> run.Verification_run_registry.verification_id
  | Goal_verification_run run -> run.Goal_verification_run_registry.run_id
;;

let retained_run_lane = function
  | Exact_run run -> Exact_lane_run_registry.lane_key run.Exact_lane_run_registry.lane
  | Task_verification_run _ | Goal_verification_run _ -> Runtime.verifier_exact_lane_id
;;

let retained_run_started_at = function
  | Exact_run run -> run.Exact_lane_run_registry.started_at
  | Task_verification_run run -> run.Verification_run_registry.started_at
  | Goal_verification_run run -> run.Goal_verification_run_registry.started_at
;;

let known_lane lane_id =
  List.exists (fun spec -> String.equal spec.lane_id lane_id) lane_specs
;;

let selected_slot_field = function
  | None -> "selected_slot", `Null
  | Some slot -> "selected_slot", `String slot
;;

let task_verification_summary_fields (run : Verification_run_registry.run) =
  let completion =
    match run.status with
    | Verification_run_registry.Running -> []
    | Verification_run_registry.Completed
        { evaluator_runtime; elapsed_s; _ } ->
      [ "elapsed_s", `Float elapsed_s; selected_slot_field evaluator_runtime ]
  in
  [ "run_id", `String run.verification_id
  ; "run_kind", `String "task_verification"
  ; "lane", `String Runtime.verifier_exact_lane_id
  ; "subject_id", `String run.task_id
  ; "actor", `String run.authority_actor
  ; "started_at", `Float run.started_at
  ; "status", `String (Verification_run_registry.status_label run.status)
  ]
  @ completion
;;

let goal_verification_summary_fields (run : Goal_verification_run_registry.run) =
  let completion =
    match run.status with
    | Goal_verification_run_registry.Running -> []
    | Goal_verification_run_registry.Completed
        { evaluator_runtime; elapsed_s; _ } ->
      [ "elapsed_s", `Float elapsed_s; selected_slot_field evaluator_runtime ]
  in
  [ "run_id", `String run.run_id
  ; "run_kind", `String "goal_verification"
  ; "lane", `String Runtime.verifier_exact_lane_id
  ; "subject_id", `String run.goal_id
  ; "actor", `String run.authority_actor
  ; "started_at", `Float run.started_at
  ; "status", `String (Goal_verification_run_registry.status_label run.status)
  ]
  @ completion
;;

let assoc_fields = function
  | `Assoc fields -> fields
  | _ -> invalid_arg "standalone lane run serializer returned a non-object"
;;

let retained_run_summary_json = function
  | Exact_run run ->
    `Assoc
      (("run_kind", `String "exact_output")
       :: assoc_fields (Exact_lane_run_registry.run_summary_to_yojson run))
  | Task_verification_run run -> `Assoc (task_verification_summary_fields run)
  | Goal_verification_run run -> `Assoc (goal_verification_summary_fields run)
;;

let verifier_input ~kind ~subject_key ~subject_id fields =
  `Assoc
    [ "kind", `String "exact"
    ; ( "payload"
      , `Assoc
          ([ "kind", `String kind; subject_key, `String subject_id ] @ fields) )
    ]
;;

let retained_run_skill_evidence_json = function
  | Exact_run run ->
    (match run.Exact_lane_run_registry.lane with
     | Exact_lane_run_registry.Librarian
     | Exact_lane_run_registry.Hitl_auto_judge
     | Exact_lane_run_registry.Board_attention ->
       `Assoc [ "state", `String "no_keeper_skills" ])
  | Task_verification_run _ | Goal_verification_run _ ->
    `Assoc [ "state", `String "no_keeper_skills" ]
;;

let retained_run_detail_json run =
  let with_skill_evidence fields =
    `Assoc (("skill_evidence", retained_run_skill_evidence_json run) :: fields)
  in
  match run with
  | Exact_run run ->
    with_skill_evidence
      (("run_kind", `String "exact_output")
       :: assoc_fields (Exact_lane_run_registry.run_to_yojson run))
  | Task_verification_run run ->
    let output =
      match run.Verification_run_registry.status with
      | Verification_run_registry.Running -> []
      | Verification_run_registry.Completed _ ->
        [ "output", Verification_run_registry.run_to_yojson run ]
    in
    with_skill_evidence
      (task_verification_summary_fields run
       @ [ ( "input"
           , verifier_input
               ~kind:"task_verification"
               ~subject_key:"task_id"
               ~subject_id:run.task_id
               [ "producer", `String run.producer
               ; "authority_kind", `String run.authority_kind
               ; "authority_actor", `String run.authority_actor
               ] ) ]
       @ output)
  | Goal_verification_run run ->
    let output =
      match run.Goal_verification_run_registry.status with
      | Goal_verification_run_registry.Running -> []
      | Goal_verification_run_registry.Completed _ ->
        [ "output", Goal_verification_run_registry.run_to_yojson run ]
    in
    with_skill_evidence
      (goal_verification_summary_fields run
       @ [ ( "input"
           , verifier_input
               ~kind:"goal_verification"
               ~subject_key:"goal_id"
               ~subject_id:run.goal_id
               [ "review_kind", `String "proof"
               ; "authority_actor", `String run.authority_actor
               ] ) ]
       @ output)
;;

let newer_first left right =
  match Float.compare (retained_run_started_at right) (retained_run_started_at left) with
  | 0 -> String.compare (retained_run_id right) (retained_run_id left)
  | order -> order
;;

let is_older_than ~before run =
  match before with
  | None -> true
  | Some (started_at, run_id) ->
    Float.compare (retained_run_started_at run) started_at < 0
    || (Float.equal (retained_run_started_at run) started_at
        && String.compare (retained_run_id run) run_id < 0)
;;

let retained_runs ~exact_runs ~verification_runs ~goal_verification_runs =
  List.map (fun run -> Exact_run run) exact_runs
  @ List.map (fun run -> Task_verification_run run) verification_runs
  @ List.map (fun run -> Goal_verification_run run) goal_verification_runs
;;

let take_page ~limit runs =
  let rec loop taken count = function
    | [] -> List.rev taken, false
    | _ :: _ when count >= limit -> List.rev taken, true
    | run :: rest -> loop (run :: taken) (count + 1) rest
  in
  if limit <= 0 then [], false else loop [] 0 runs
;;

let recent_run_page_json_with
      ~limit
      ~before
      ~lane
      ~exact_runs
      ~verification_runs
      ~goal_verification_runs
  =
  match lane with
  | Some lane_id when not (known_lane lane_id) ->
    Error (Printf.sprintf "unknown standalone lane %S" lane_id)
  | None | Some _ ->
    let all = retained_runs ~exact_runs ~verification_runs ~goal_verification_runs in
    let relevant =
      match lane with
      | None -> all
      | Some lane_id ->
        List.filter (fun run -> String.equal (retained_run_lane run) lane_id) all
    in
    let candidates =
      relevant |> List.filter (is_older_than ~before) |> List.sort newer_first
    in
    let runs, has_more = take_page ~limit candidates in
    Ok
      (`Assoc
        [ "generated_at", `String (Masc_domain.now_iso ())
        ; "count", `Int (List.length runs)
        ; "total", `Int (List.length relevant)
        ; "has_more", `Bool has_more
        ; "runs", `List (List.map retained_run_summary_json runs)
        ])
;;

let recent_run_page_json ~limit ~before ~lane =
  recent_run_page_json_with
    ~limit
    ~before
    ~lane
    ~exact_runs:
      (Exact_lane_run_registry.list_runs (Exact_lane_run_registry.global ()))
    ~verification_runs:
      (Verification_run_registry.list_runs (Verification_run_registry.global ()))
    ~goal_verification_runs:
      (Goal_verification_run_registry.list_runs
         (Goal_verification_run_registry.global ()))
;;

let run_detail_json_with
      ~run_id
      ~exact_runs
      ~verification_runs
      ~goal_verification_runs
  =
  let matches =
    retained_runs ~exact_runs ~verification_runs ~goal_verification_runs
    |> List.filter (fun run -> String.equal (retained_run_id run) run_id)
  in
  match matches with
  | [] -> Detail_not_found
  | [ run ] ->
    Detail_found
      (`Assoc
        [ "generated_at", `String (Masc_domain.now_iso ())
        ; "run", retained_run_detail_json run
        ])
  | _ -> Detail_ambiguous
;;

let run_detail_json ~run_id =
  let exact_runs =
    match Exact_lane_run_registry.get (Exact_lane_run_registry.global ()) ~run_id with
    | Some run -> [ run ]
    | None -> []
  in
  run_detail_json_with
    ~run_id
    ~exact_runs
    ~verification_runs:
      (Verification_run_registry.list_runs (Verification_run_registry.global ()))
    ~goal_verification_runs:
      (Goal_verification_run_registry.list_runs
         (Goal_verification_run_registry.global ()))
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
   the panel unreadable as a judgement metric (lane audit W5). An
   operator-routed claim asked no evaluator anything: it is not a run of this
   lane, so it has no terminal kind here and enters neither the counts nor
   the latency. *)
let terminal_of_verification_outcome = function
  | Verification_run_registry.Infrastructure_unavailable _
  | Verification_run_registry.Commit_failed _
  | Verification_run_registry.Raised _
  | Verification_run_registry.Not_reviewed _ -> Some Failed
  | Verification_run_registry.Approved _
  | Verification_run_registry.Rejected _ -> Some Succeeded
  | Verification_run_registry.Review_cancelled _ -> Some Cancelled
  | Verification_run_registry.Operator_routed -> None
;;

let observed_verification_run (run : Verification_run_registry.run) =
  let status =
    match run.status with
    | Verification_run_registry.Running -> Some Running
    | Verification_run_registry.Completed
        { outcome; evaluator_runtime; elapsed_s; _ } ->
      Option.map
        (fun kind ->
           Terminal
             { kind; elapsed_s; elapsed_measured = true; selected_slot = evaluator_runtime })
        (terminal_of_verification_outcome outcome)
  in
  Option.map
    (fun status ->
       { lane_id = Runtime.verifier_exact_lane_id; started_at = run.started_at; status })
    status
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
  (* Only a measured finish. A server-restart orphan is written back with
     [now - started_at], so started_at + elapsed_s lands on the moment the
     server noticed rather than the moment the run ended -- and a reader
     drawing "last run failed 3m ago" off it is reading the restart, not the
     run. Same reason the percentile above refuses the synthesised value. *)
  let last_terminal_at =
    Option.bind latest_terminal (fun (run, terminal) ->
      if terminal.elapsed_measured
      then Some (run.started_at +. terminal.elapsed_s)
      else None)
  in
  `Assoc
    [ "lane_id", `String spec.lane_id
    ; "label", `String spec.label
    ; "purpose", `String spec.purpose
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
    @ List.filter_map observed_verification_run verification_runs
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
  let recent_run_page_json_with = recent_run_page_json_with
  let run_detail_json_with = run_detail_json_with
end
