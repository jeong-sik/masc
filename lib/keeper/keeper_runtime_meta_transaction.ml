open Keeper_meta_contract

module Journal = Keeper_runtime_meta_journal

type preference =
  [ `Rollback
  | `Forward
  ]

type resolution =
  | Rolled_back
  | Forward_committed

type recovery_failure =
  | Journal_failure of Journal.error
  | Runtime_convergence_failed of string
  | Metadata_convergence_failed of string
  | Unrelated_runtime_observed of string option
  | Unrelated_metadata_observed
  | Both_directions_failed of
      { rollback : string
      ; forward : string
      }

type recovery_summary =
  { recovered : int
  ; cleared : int
  ; unresolved : (string * string) list
  }

let recovery_failure_to_string = function
  | Journal_failure error -> Journal.error_to_string error
  | Runtime_convergence_failed detail ->
    "runtime convergence failed: " ^ detail
  | Metadata_convergence_failed detail ->
    "metadata convergence failed: " ^ detail
  | Unrelated_runtime_observed None ->
    "runtime authority is outside both transaction targets: none"
  | Unrelated_runtime_observed (Some runtime_id) ->
    "runtime authority is outside both transaction targets: " ^ runtime_id
  | Unrelated_metadata_observed ->
    "metadata authority is outside both transaction targets"
  | Both_directions_failed { rollback; forward } ->
    Printf.sprintf
      "runtime/meta transaction could not converge: rollback=%s; forward=%s"
      rollback
      forward
;;

let metadata_convergence_failure_key
    : (preference -> string option) Eio.Fiber.key
  =
  Eio.Fiber.create_key ()
;;

module For_testing = struct
  let with_metadata_convergence_failure failure fn =
    Eio.Fiber.with_binding metadata_convergence_failure_key failure fn
  ;;
end

let prepare
      ~operation
      ~config
      ~keeper_name
      ~previous_runtime
      ~candidate_runtime
      ~previous_meta
      ~candidate_meta
  =
  match
    Journal.make_intent
      ~operation
      ~keeper_name
      ~previous_runtime
      ~candidate_runtime
      ~previous_meta
      ~candidate_meta
  with
  | Error error -> Error (Journal_failure error)
  | Ok intent ->
    (match Journal.reserve config intent with
     | Ok () -> Ok intent
     | Error error -> Error (Journal_failure error))
;;

let same_runtime left right =
  Option.equal String.equal left right
;;

let same_meta_payload left right =
  { left with meta_version = 0 } = { right with meta_version = 0 }
;;

let meta_targets_indistinguishable (intent : Journal.intent) =
  match intent.previous_meta with
  | Some previous -> same_meta_payload previous intent.candidate_meta
  | None -> false
;;

type observed_meta =
  | Meta_missing
  | Meta_previous of keeper_meta
  | Meta_candidate of keeper_meta
  | Meta_unrelated

let observe_meta config (intent : Journal.intent) =
  match Keeper_meta_store.read_meta config intent.keeper_name with
  | Error detail -> Error (Metadata_convergence_failed detail)
  | Ok None -> Ok Meta_missing
  | Ok (Some current) ->
    (match intent.previous_meta with
     | Some previous when same_meta_payload current previous ->
       Ok (Meta_previous current)
     | Some _ | None ->
       if same_meta_payload current intent.candidate_meta
       then Ok (Meta_candidate current)
       else Ok Meta_unrelated)
;;

let runtime_is_known (intent : Journal.intent) observed =
  same_runtime observed intent.previous_runtime
  || same_runtime observed intent.candidate_runtime
;;

let meta_is_known (intent : Journal.intent) = function
  | Meta_missing -> Option.is_none intent.previous_meta
  | Meta_previous _ -> Option.is_some intent.previous_meta
  | Meta_candidate _ -> true
  | Meta_unrelated -> false
;;

let target_runtime (intent : Journal.intent) = function
  | `Rollback -> intent.previous_runtime
  | `Forward -> intent.candidate_runtime
;;

let target_meta (intent : Journal.intent) = function
  | `Rollback -> intent.previous_meta
  | `Forward -> Some intent.candidate_meta
;;

let runtime_at_target intent direction =
  same_runtime
    (Runtime.runtime_id_for_keeper intent.Journal.keeper_name)
    (target_runtime intent direction)
;;

let converge_runtime intent direction =
  let target = target_runtime intent direction in
  if runtime_at_target intent direction
  then Ok ()
  else
    let mutation =
      match target with
      | Some runtime_id ->
        Runtime.set_runtime_id_for_keeper
          ~keeper_name:intent.Journal.keeper_name
          ~runtime_id
          ()
      | None ->
        Runtime.clear_runtime_id_for_keeper
          ~keeper_name:intent.Journal.keeper_name
          ()
    in
    match mutation with
    | Ok () when runtime_at_target intent direction -> Ok ()
    | Ok () ->
      Error
        (Runtime_convergence_failed
           "runtime mutation returned success without publishing the target")
    | Error _ when runtime_at_target intent direction -> Ok ()
    | Error detail -> Error (Runtime_convergence_failed detail)
;;

let write_existing_meta ?lifecycle_token permit config current target =
  let target = { target with meta_version = current.meta_version } in
  match lifecycle_token with
  | Some token ->
    Keeper_meta_store.write_meta_for_lifecycle permit token config target
  | None -> Keeper_meta_store.write_meta config target
;;

let recover_created_meta permit config (intent : Journal.intent) target =
  let ( let* ) = Result.bind in
  let* target_identity =
    Keeper_lifecycle_nonce.identity
      ~owner_id:
        (Keeper_id.Trace_id.to_string target.runtime.trace_id)
      ~nonce:(Int64.of_int target.runtime.nonce)
    |> Result.map_error (fun error ->
      Metadata_convergence_failed
        (Keeper_lifecycle_nonce.error_to_string error))
  in
  let* witness =
    Keeper_lifecycle_nonce.recover_exact
      permit
      ~base_path:config.Workspace.base_path
      ~keeper_id:intent.keeper_name
      ~source:None
      ~target:target_identity
      ()
    |> Result.map_error (fun error ->
      Metadata_convergence_failed
        (Keeper_lifecycle_nonce.error_to_string error))
  in
  Keeper_meta_store.recover_meta_exact permit witness config target
  |> Result.map_error (fun detail -> Metadata_convergence_failed detail)
;;

let remove_created_meta config current =
  Keeper_meta_store.remove_meta_if_identity
    config
    ~name:current.name
    ~trace_id:current.runtime.trace_id
    ~generation:current.runtime.nonce
  |> Result.map_error (fun error ->
    Metadata_convergence_failed
      (Keeper_meta_store.identity_remove_error_to_string error))
;;

let metadata_at_target config intent direction =
  match observe_meta config intent, direction with
  | Error error, _ -> Error error
  | Ok Meta_missing, `Rollback when Option.is_none intent.Journal.previous_meta ->
    Ok true
  | Ok (Meta_previous _), `Rollback -> Ok true
  | Ok (Meta_candidate _), `Forward -> Ok true
  | Ok (Meta_previous _), `Forward
    when meta_targets_indistinguishable intent ->
    Ok true
  | Ok (Meta_candidate _), `Rollback
    when meta_targets_indistinguishable intent ->
    Ok true
  | Ok _, _ -> Ok false
;;

let converge_metadata ?lifecycle_token permit config intent direction =
  match
    Option.bind
      (Eio.Fiber.get metadata_convergence_failure_key)
      (fun failure -> failure direction)
  with
  | Some detail -> Error (Metadata_convergence_failed detail)
  | None ->
    let target = target_meta intent direction in
    let observed = observe_meta config intent in
    let mutation =
      match observed, target with
      | Error error, _ -> Error error
      | Ok Meta_unrelated, _ -> Error Unrelated_metadata_observed
      | Ok Meta_missing, None -> Ok ()
      | Ok (Meta_previous _), Some target
      | Ok (Meta_candidate _), Some target
        when Result.value ~default:false
               (metadata_at_target config intent direction) ->
        Ok ()
      | Ok (Meta_previous current), Some target
      | Ok (Meta_candidate current), Some target ->
        write_existing_meta
          ?lifecycle_token
          permit
          config
          current
          target
        |> Result.map_error (fun detail ->
          Metadata_convergence_failed detail)
      | Ok Meta_missing, Some target
        when Option.is_none intent.Journal.previous_meta ->
        recover_created_meta permit config intent target
      | Ok Meta_missing, Some _ ->
        Error
          (Metadata_convergence_failed
             "update metadata disappeared during recovery")
      | Ok (Meta_candidate current), None ->
        remove_created_meta config current
      | Ok (Meta_previous _), None ->
        Error
          (Metadata_convergence_failed
             "create rollback observed impossible previous metadata")
    in
    match mutation with
    | Ok () ->
      (match metadata_at_target config intent direction with
       | Ok true -> Ok ()
       | Ok false ->
         Error
           (Metadata_convergence_failed
              "metadata mutation did not publish the exact target")
       | Error error -> Error error)
    | Error _ as mutation_error ->
      (match metadata_at_target config intent direction with
       | Ok true -> Ok ()
       | Ok false | Error _ -> mutation_error)
;;

let exact_pair config intent direction =
  if not (runtime_at_target intent direction)
  then Ok false
  else metadata_at_target config intent direction
;;

let converge_direction ?lifecycle_token permit config intent direction =
  let ( let* ) = Result.bind in
  let* () = converge_runtime intent direction in
  let* () =
    converge_metadata
      ?lifecycle_token
      permit
      config
      intent
      direction
  in
  match exact_pair config intent direction with
  | Ok true -> Ok ()
  | Ok false ->
    Error
      (Metadata_convergence_failed
         "runtime and metadata did not settle to one exact direction")
  | Error error -> Error error
;;

let clear_exact config intent direction =
  match exact_pair config intent direction with
  | Error error -> Error error
  | Ok false ->
    Error
      (Metadata_convergence_failed
         "refusing to clear a transaction without an exact paired state")
  | Ok true ->
    Journal.clear config intent
    |> Result.map_error (fun error -> Journal_failure error)
;;

let recover ?lifecycle_token permit config intent ~prefer =
  let runtime_observed =
    Runtime.runtime_id_for_keeper intent.Journal.keeper_name
  in
  match observe_meta config intent with
  | Error error -> Error error
  | Ok meta_observed
    when not (runtime_is_known intent runtime_observed) ->
    Error (Unrelated_runtime_observed runtime_observed)
  | Ok meta_observed when not (meta_is_known intent meta_observed) ->
    Error Unrelated_metadata_observed
  | Ok _ ->
    let rollback_pair = exact_pair config intent `Rollback in
    let forward_pair = exact_pair config intent `Forward in
    (match rollback_pair, forward_pair with
     | Ok true, Ok true ->
       let direction, resolution =
         match prefer with
         | `Rollback -> `Rollback, Rolled_back
         | `Forward -> `Forward, Forward_committed
       in
       Result.map
         (fun () -> resolution)
         (clear_exact config intent direction)
     | Ok true, _ ->
       Result.map
         (fun () -> Rolled_back)
         (clear_exact config intent `Rollback)
     | _, Ok true ->
       Result.map
         (fun () -> Forward_committed)
         (clear_exact config intent `Forward)
     | _ ->
       let first, second =
         match prefer with
         | `Rollback -> `Rollback, `Forward
         | `Forward -> `Forward, `Rollback
       in
       let resolution = function
         | `Rollback -> Rolled_back
         | `Forward -> Forward_committed
       in
       (match
          converge_direction
            ?lifecycle_token
            permit
            config
            intent
            first
        with
        | Ok () ->
          Result.map
            (fun () -> resolution first)
            (clear_exact config intent first)
        | Error first_error ->
          (match
             converge_direction
               ?lifecycle_token
               permit
               config
               intent
               second
           with
           | Ok () ->
             Result.map
               (fun () -> resolution second)
               (clear_exact config intent second)
           | Error second_error ->
             let rollback, forward =
               match first with
               | `Rollback ->
                 recovery_failure_to_string first_error,
                 recovery_failure_to_string second_error
               | `Forward ->
                 recovery_failure_to_string second_error,
                 recovery_failure_to_string first_error
             in
             Error (Both_directions_failed { rollback; forward }))))
;;

let complete_forward ?lifecycle_token permit config intent =
  recover
    ?lifecycle_token
    permit
    config
    intent
    ~prefer:`Forward
  |> Result.bind (function
    | Forward_committed -> Ok ()
    | Rolled_back ->
      Error
        (Metadata_convergence_failed
           "committed transaction unexpectedly recovered by rollback"))
;;

let recover_leaf config leaf =
  match Journal.read_leaf config leaf with
  | Error error -> Error (Journal.error_to_string error)
  | Ok None -> Error "runtime/meta authority disappeared during discovery"
  | Ok (Some (Journal.Cleared _)) -> Ok `Cleared
  | Ok (Some (Journal.Active intent)) ->
    (match
       Keeper_lifecycle_admission.Durable_transaction
       .with_recovery_lifecycle_admission
         config
         ~keeper_name:intent.keeper_name
         ~transaction_id:intent.transaction_id
         (fun permit ->
            recover permit config intent ~prefer:`Rollback)
     with
     | Admission_completed result -> Result.map (fun value -> `Recovered value) result
     | Admission_completed_with_attention (result, failure) ->
       (match result with
        | Ok value -> Ok (`Recovered value)
        | Error error ->
          Error
            (recovery_failure_to_string error
             ^ "; durable admission release failed: "
             ^ Keeper_lifecycle_admission.Durable_transaction
               .authority_failure_to_wire
                 failure))
     | Admission_blocked reason ->
       Error
         ("runtime/meta recovery admission blocked: "
          ^ Keeper_lifecycle_admission.Durable_transaction
            .blocked_reason_to_wire
              reason))
;;

let recover_pending config =
  let dir = Journal.journal_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ when not (Fs_compat.file_exists dir) ->
    { recovered = 0; cleared = 0; unresolved = [] }
  | Error detail ->
    { recovered = 0; cleared = 0; unresolved = [ dir, detail ] }
  | Ok leaves ->
    List.fold_left
      (fun summary leaf ->
         if not (Journal.is_journal_leaf leaf)
         then summary
         else
           let path = Filename.concat dir leaf in
           match recover_leaf config leaf with
           | Ok (`Recovered Rolled_back) ->
             { summary with recovered = summary.recovered + 1 }
           | Ok (`Recovered Forward_committed)
           | Ok `Cleared ->
             { summary with cleared = summary.cleared + 1 }
           | Error detail ->
             { summary with
               unresolved = (path, detail) :: summary.unresolved
             })
      { recovered = 0; cleared = 0; unresolved = [] }
      leaves
;;
