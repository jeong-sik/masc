module Operation = Keeper_compaction_operation
module Store = Keeper_compaction_operation_store
module Object_store = Keeper_compaction_object_store
type request_status =
  | Created
  | Existing

type confirmation =
  { operation_id : Operation.Operation_id.t
  ; status : request_status
  ; source_checkpoint : Keeper_checkpoint_ref.t
  }
type error =
  | Keeper_meta_unavailable of string
  | Keeper_meta_identity_mismatch of
      { requested : Keeper_id.Keeper_name.t
      ; persisted : string
      }
  | Source_checkpoint_unavailable of
      Keeper_checkpoint_store.checkpoint_ref_load_error
  | Source_object_persist_failed of Object_store.put_error
  | Durable_source_unavailable of
      { operation_id : Operation.Operation_id.t
      ; error : Object_store.load_error
      }
  | Journal_read_failed of Store.read_error
  | Journal_append_failed of
      { attempted_operation_id : Operation.Operation_id.t
      ; error : Store.append_error
      }
  | Existing_operation_missing of
      { attempted_operation_id : Operation.Operation_id.t
      ; existing_operation_id : Operation.Operation_id.t
      }
  | Transaction_outcome_unresolved of
      { attempted_operation_id : Operation.Operation_id.t
      ; error : Store.transaction_error
      ; replay_error : Store.read_error option
      }
let ( let* ) = Result.bind
let find_operation operation_id (replay : Store.replay) =
  List.find_opt
    (fun (entry : Store.operation_entry) ->
       Operation.Operation_id.equal entry.snapshot.operation_id operation_id)
    replay.operations
;;
let find_producer producer (replay : Store.replay) =
  List.find_opt
    (fun (entry : Store.operation_entry) ->
       Option.exists
         (Operation.producer_ref_equal producer)
         entry.snapshot.producer)
    replay.operations
;;
let confirm_entry ~base_path ~keeper_name ~status
    (entry : Store.operation_entry) =
  let operation_id = entry.snapshot.operation_id in
  let source_checkpoint = entry.snapshot.source_checkpoint in
  match Object_store.load ~base_path ~keeper_name ~reference:source_checkpoint with
  | Ok _ -> Ok { operation_id; status; source_checkpoint }
  | Error error ->
    Error (Durable_source_unavailable { operation_id; error })
;;

let replay ~base_path ~keeper_name =
  Store.replay ~base_path ~keeper_name
  |> Result.map_error (fun error -> Journal_read_failed error)
;;

let existing_for_producer ~base_path ~keeper_name = function
  | None -> Ok None
  | Some producer ->
    replay ~base_path ~keeper_name
    |> Result.map (fun history -> find_producer producer history)
;;

let existing_confirmation ~base_path ~keeper_name ~attempted_operation_id
    existing_operation_id =
  let* history = replay ~base_path ~keeper_name in
  match find_operation existing_operation_id history with
  | Some entry -> confirm_entry ~base_path ~keeper_name ~status:Existing entry
  | None ->
    Error
      (Existing_operation_missing
         { attempted_operation_id; existing_operation_id })
;;

let reconcile_unknown ~base_path ~keeper_name ~producer
    ~attempted_operation_id transaction_error =
  match Store.replay ~base_path ~keeper_name with
  | Error replay_error ->
    Error
      (Transaction_outcome_unresolved
         { attempted_operation_id
         ; error = transaction_error
         ; replay_error = Some replay_error
         })
  | Ok history ->
    (match find_operation attempted_operation_id history with
     | Some entry -> confirm_entry ~base_path ~keeper_name ~status:Created entry
     | None ->
       (match
          Option.bind producer (fun producer ->
            find_producer producer history)
        with
        | Some entry ->
          confirm_entry ~base_path ~keeper_name ~status:Existing entry
        | None ->
          Error
            (Transaction_outcome_unresolved
               { attempted_operation_id
               ; error = transaction_error
               ; replay_error = None
               })))
;;

let load_meta config keeper_name =
  let requested = Keeper_id.Keeper_name.to_string keeper_name in
  match Keeper_meta_store.read_meta config requested with
  | Error detail -> Error (Keeper_meta_unavailable detail)
  | Ok None ->
    Error
      (Keeper_meta_unavailable
         (Printf.sprintf "keeper not found: %s" requested))
  | Ok (Some meta) when String.equal meta.name requested -> Ok meta
  | Ok (Some meta) ->
    Error
      (Keeper_meta_identity_mismatch
         { requested = keeper_name; persisted = meta.name })
;;

let load_source config meta =
  let session_id = Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id in
  let session =
    Keeper_context_runtime.create_session
      ~session_id
      ~base_dir:(Keeper_types_profile.session_base_dir config)
  in
  Keeper_checkpoint_store.load_oas_exact_snapshot
    ~session_dir:session.session_dir
    ~session_id
  |> Result.map_error (fun error -> Source_checkpoint_unavailable error)
;;

let request ~config ~keeper_name ~cause ~producer =
  let base_path = config.Workspace.base_path in
  let* existing =
    existing_for_producer ~base_path ~keeper_name producer
  in
  match existing with
  | Some entry -> confirm_entry ~base_path ~keeper_name ~status:Existing entry
  | None ->
    let* meta = load_meta config keeper_name in
    let* source = load_source config meta in
    let* _ =
      Object_store.put ~base_path ~keeper_name source
      |> Result.map_error (fun error -> Source_object_persist_failed error)
    in
    let source_checkpoint =
      Keeper_checkpoint_store.exact_snapshot_reference source
    in
    let operation_id = Operation.Operation_id.generate () in
    let event =
      Operation.requested
        ~operation_id
        ~keeper_name
        ~source_checkpoint
        ~trigger:Compaction_trigger.Manual
        ~cause
        ~producer
    in
    match
      Store.append
        ~base_path
        ~keeper_name
        ~recorded_at:(Time_compat.now ())
        event
    with
    | Ok _ -> Ok { operation_id; status = Created; source_checkpoint }
    | Error
        (Store.Event_rejected
           (Store.Producer_already_bound { existing_operation_id; _ })) ->
      existing_confirmation
        ~base_path
        ~keeper_name
        ~attempted_operation_id:operation_id
        existing_operation_id
    | Error (Store.Transaction_error (Store.Outcome_unknown _ as error)) ->
      reconcile_unknown
        ~base_path
        ~keeper_name
        ~producer
        ~attempted_operation_id:operation_id
        error
    | Error error ->
      Error (Journal_append_failed { attempted_operation_id = operation_id; error })
;;
