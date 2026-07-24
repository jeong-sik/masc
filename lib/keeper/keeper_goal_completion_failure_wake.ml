type projection =
  { owner_names : string list
  ; enqueued_owner_names : string list
  ; already_present_owner_names : string list
  ; observed_owner_names : string list
  ; signaled_owner_names : string list
  ; deferred_owner_names : string list
  }

type failure =
  | Invalid_goal_state of string
  | Owner_discovery_failed of (string * string) list
  | Delivery_failed of (string * string) list
  | Owner_discovery_and_delivery_failed of
      { metadata_errors : (string * string) list
      ; delivery_errors : (string * string) list
      }

type outcome =
  | Projected of projection
  | Unowned
  | Incomplete of
      { projection : projection
      ; failure : failure
      }

let failure_label = function
  | Goal_store.Rejected -> "rejected"
  | Goal_store.Unavailable -> "unavailable"
;;

let goal_review_fingerprint (goal : Goal_store.goal) =
  `Assoc
    [ "goal_id", `String goal.id
    ; "reviewed_at", Json_util.string_opt_to_json goal.last_review_at
    ; ( "failure"
      , match goal.completion_review_failure with
        | None -> `Null
        | Some failure -> `String (failure_label failure) )
    ; "note", Json_util.string_opt_to_json goal.last_review_note
    ]
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let rec failure_to_string = function
  | Invalid_goal_state detail -> detail
  | Owner_discovery_failed errors ->
    Printf.sprintf
      "Keeper owner discovery failed: %s"
      (errors
       |> List.map (fun (keeper_name, detail) ->
         Printf.sprintf "%s=%s" keeper_name detail)
       |> String.concat "; ")
  | Delivery_failed errors ->
    Printf.sprintf
      "Goal completion failure delivery failed: %s"
      (errors
       |> List.map (fun (keeper_name, detail) ->
         Printf.sprintf "%s=%s" keeper_name detail)
       |> String.concat "; ")
  | Owner_discovery_and_delivery_failed
      { metadata_errors; delivery_errors } ->
    Printf.sprintf
      "%s; %s"
      (failure_to_string (Owner_discovery_failed metadata_errors))
      (failure_to_string (Delivery_failed delivery_errors))
;;

let failure_kind = function
  | Goal_store.Rejected ->
    Keeper_event_queue.Goal_completion_rejected
  | Goal_store.Unavailable ->
    Keeper_event_queue.Goal_completion_unavailable
;;

let owners_for_goal ~(config : Workspace.config) ~goal_id =
  match Keeper_meta_store.keeper_names_result config with
  | Error detail -> [], [ "<keeper-directory>", detail ]
  | Ok keeper_names ->
    List.fold_left
      (fun (owners, errors) keeper_name ->
         match Keeper_meta_store.read_meta config keeper_name with
         | Ok (Some meta) ->
           (match
              Keeper_types_profile
              .load_keeper_profile_defaults_result_for_base_path
                ~base_path:config.base_path
                keeper_name
            with
            | Error error ->
              ( owners
              , ( keeper_name
                , Keeper_types_profile.keeper_toml_load_error_to_string
                    error )
                :: errors )
            | Ok defaults ->
              let active_goal_ids =
                Option.value
                  ~default:meta.active_goal_ids
                  defaults.active_goal_ids
              in
              if List.exists (String.equal goal_id) active_goal_ids
              then meta.name :: owners, errors
              else owners, errors)
         | Ok None ->
           ( owners
           , (keeper_name, "metadata disappeared during owner discovery")
             :: errors )
         | Error detail -> owners, (keeper_name, detail) :: errors)
      ([], [])
      keeper_names
    |> fun (owners, errors) -> List.rev owners, List.rev errors
;;

let empty_projection owner_names =
  { owner_names
  ; enqueued_owner_names = []
  ; already_present_owner_names = []
  ; observed_owner_names = []
  ; signaled_owner_names = []
  ; deferred_owner_names = []
  }
;;

let wake_owner ~base_path keeper_name projection =
  match
    Keeper_registry.wakeup_running
      ~intent:Keeper_registry.Goal_signal
      ~base_path
      keeper_name
  with
  | Keeper_registry.Signaled ->
    { projection with
      signaled_owner_names = keeper_name :: projection.signaled_owner_names
    }
  | Keeper_registry.Deferred_unregistered ->
    Log.Keeper.info
      "Goal completion failure wake persisted for unregistered owner=%s"
      keeper_name;
    { projection with
      deferred_owner_names = keeper_name :: projection.deferred_owner_names
    }
  | Keeper_registry.Deferred_not_running phase ->
    Log.Keeper.info
      "Goal completion failure wake deferred by registry phase owner=%s phase=%s"
      keeper_name
      (Keeper_state_machine.phase_to_string phase);
    { projection with
      deferred_owner_names = keeper_name :: projection.deferred_owner_names
    }
  | Keeper_registry.Deferred_lifecycle denial ->
    Log.Keeper.info
      "Goal completion failure wake deferred by lifecycle owner=%s reason=%s"
      keeper_name
      (Keeper_lifecycle_admission.autonomous_denial_to_wire denial);
    { projection with
      deferred_owner_names = keeper_name :: projection.deferred_owner_names
    }
;;

let finalize_projection projection =
  { projection with
    enqueued_owner_names = List.rev projection.enqueued_owner_names
  ; already_present_owner_names =
      List.rev projection.already_present_owner_names
  ; observed_owner_names = List.rev projection.observed_owner_names
  ; signaled_owner_names = List.rev projection.signaled_owner_names
  ; deferred_owner_names = List.rev projection.deferred_owner_names
  }
;;

let delivery_observed ~base_path ~keeper_name stimulus =
  let stimulus_id =
    Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus
  in
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
  with
  | Error error ->
    Error
      (Keeper_reaction_ledger
       .event_queue_reaction_evidence_error_to_string
         error)
  | Ok
      (Keeper_reaction_ledger.Evidence_quarantined
         { first_reason; _ }) ->
    Error
      ("reaction ledger contains quarantined matching evidence: "
       ^ Keeper_reaction_ledger.row_quarantine_reason_to_string
           first_reason)
  | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
    Ok
      (evidence.event_queue_ack_seen
       || evidence.event_queue_cancelled_seen)
;;

let project ~(config : Workspace.config) ~(goal : Goal_store.goal) ~failure =
  match
    ( goal.completion_review_failure
    , goal.last_review_at
    , goal.last_review_note )
  with
  | Some durable_failure, Some reviewed_at, Some _
    when durable_failure = failure
         && goal.phase = Goal_phase.Executing ->
    let owner_names, metadata_errors =
      owners_for_goal ~config ~goal_id:goal.id
    in
    if owner_names = [] && metadata_errors = []
    then (
      Log.Keeper.warn
        "Goal completion review failed without a Keeper owner goal_id=%s \
         review=%s"
        goal.id
        (goal_review_fingerprint goal);
      Unowned)
    else
      let review_fingerprint = goal_review_fingerprint goal in
      let payload : Keeper_event_queue.goal_completion_review_failure =
        { gcrf_goal_id = goal.id
        ; gcrf_goal_title = goal.title
        ; gcrf_reviewed_at = reviewed_at
        ; gcrf_review_fingerprint = review_fingerprint
        ; gcrf_failure = failure_kind failure
        }
      in
      let stimulus : Keeper_event_queue.stimulus =
        { post_id =
            Keeper_event_queue.goal_completion_review_failure_post_id payload
        ; urgency = Keeper_event_queue.Immediate
        ; arrived_at = Time_compat.now ()
        ; payload = Keeper_event_queue.Goal_completion_review_failed payload
        }
      in
      let projection, delivery_errors =
        List.fold_left
          (fun (projection, delivery_errors) keeper_name ->
             match
               delivery_observed
                 ~base_path:config.base_path
                 ~keeper_name
                 stimulus
             with
             | Error detail ->
               projection, (keeper_name, detail) :: delivery_errors
             | Ok true ->
               ( { projection with
                   observed_owner_names =
                     keeper_name :: projection.observed_owner_names
                 }
               , delivery_errors )
             | Ok false ->
               (match
                  Keeper_registry_event_queue
                  .enqueue_stimulus_durable_result
                    ~base_path:config.base_path
                    keeper_name
                    stimulus
                with
                | Keeper_registry_event_queue.Stimulus_enqueued ->
                  let projection =
                    { projection with
                      enqueued_owner_names =
                        keeper_name :: projection.enqueued_owner_names
                    }
                    |> wake_owner ~base_path:config.base_path keeper_name
                  in
                  projection, delivery_errors
                | Keeper_registry_event_queue.Stimulus_already_present ->
                  let projection =
                    { projection with
                      already_present_owner_names =
                        keeper_name
                        :: projection.already_present_owner_names
                    }
                    |> wake_owner ~base_path:config.base_path keeper_name
                  in
                  projection, delivery_errors
                | Keeper_registry_event_queue.Stimulus_storage_error
                    detail ->
                  projection, (keeper_name, detail) :: delivery_errors))
          (empty_projection owner_names, [])
          owner_names
      in
      let projection = finalize_projection projection in
      let delivery_errors = List.rev delivery_errors in
      (match metadata_errors, delivery_errors with
       | [], [] ->
         Log.Keeper.info
           "Goal completion failure projected goal_id=%s review=%s owners=[%s]"
           goal.id
           review_fingerprint
           (String.concat "," owner_names);
         Projected projection
       | _ :: _, [] ->
         Incomplete
           { projection; failure = Owner_discovery_failed metadata_errors }
       | [], _ :: _ ->
         Incomplete
           { projection; failure = Delivery_failed delivery_errors }
       | _ :: _, _ :: _ ->
         Incomplete
           { projection
           ; failure =
               Owner_discovery_and_delivery_failed
                 { metadata_errors; delivery_errors }
           })
  | _ ->
    Incomplete
      { projection = empty_projection []
      ; failure =
          Invalid_goal_state
            "Goal completion failure wake requires matching durable failure, \
             review timestamp, review note, and Executing phase"
      }
;;

type reconciliation_report =
  { examined : int
  ; projected : int
  ; unowned : string list
  ; incomplete : (string * failure) list
  }

let reconcile_all ~(config : Workspace.config) =
  Goal_store.list_goals config ()
  |> List.filter_map (fun (goal : Goal_store.goal) ->
       Option.map (fun failure -> goal, failure) goal.completion_review_failure)
  |> List.fold_left
       (fun report (goal, failure) ->
          let report = { report with examined = report.examined + 1 } in
          match project ~config ~goal ~failure with
          | Projected _ ->
            { report with projected = report.projected + 1 }
          | Unowned ->
            { report with unowned = goal.id :: report.unowned }
          | Incomplete { failure; _ } ->
            { report with
              incomplete = (goal.id, failure) :: report.incomplete
            })
       { examined = 0; projected = 0; unowned = []; incomplete = [] }
  |> fun report ->
  { report with
    unowned = List.rev report.unowned
  ; incomplete = List.rev report.incomplete
  }
;;
