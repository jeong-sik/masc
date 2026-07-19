type continuation_binding =
  | Routed of Keeper_continuation_channel.t
  | No_channel

type transfer_owner =
  { from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  ; target_generation : int
  ; source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; settled_at : float
  ; continuation_binding : continuation_binding
  }

type operation =
  | Resume_owner
  | Transfer_owner of transfer_owner

type keeper_lock = { keeper_name : string }

type t =
  { keeper_name : string
  ; expected_trace_id : Keeper_id.Trace_id.t
  ; expected_generation : int
  ; operator_operation_id : string
  ; requested_at : float
  ; operation : operation
  }

type save_result =
  | Created
  | Existing of t


let ( let* ) = Result.bind

let equal left right =
  String.equal left.keeper_name right.keeper_name
  && Keeper_id.Trace_id.equal left.expected_trace_id right.expected_trace_id
  && Int.equal left.expected_generation right.expected_generation
  && String.equal left.operator_operation_id right.operator_operation_id
  && Float.equal left.requested_at right.requested_at
  && left.operation = right.operation
;;

let continuation_binding_of_source source =
  match source.Keeper_event_queue.payload with
  | Keeper_event_queue.Fusion_completed completion -> Routed completion.channel
  | Keeper_event_queue.Connector_attention attention -> Routed attention.channel
  | Keeper_event_queue.Hitl_resolved resolution -> Routed resolution.channel
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Failure_judgment _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _ ->
    No_channel
;;

let validate receipt =
  if String.equal (String.trim receipt.keeper_name) ""
  then Error "paused-work disposition keeper name must not be empty"
  else if receipt.expected_generation < 0
  then Error "paused-work disposition owner generation must not be negative"
  else if String.equal (String.trim receipt.operator_operation_id) ""
  then Error "paused-work disposition operation ID must not be empty"
  else if not (Float.is_finite receipt.requested_at)
  then Error "paused-work disposition request time must be finite"
  else
    match receipt.operation with
    | Resume_owner -> Ok ()
    | Transfer_owner transfer ->
      if not (String.equal transfer.from_keeper receipt.keeper_name)
      then Error "paused-work transfer source Keeper does not match receipt owner"
      else if String.equal (String.trim transfer.to_keeper) ""
      then Error "paused-work transfer target Keeper must not be empty"
      else if String.equal transfer.from_keeper transfer.to_keeper
      then Error "paused-work transfer source and target Keepers must differ"
      else if transfer.target_generation < 0
      then Error "paused-work transfer target generation must not be negative"
      else if Int64.compare transfer.source_revision 0L < 0
      then Error "paused-work transfer source revision must not be negative"
      else if not (Float.is_finite transfer.settled_at)
      then Error "paused-work transfer settlement time must be finite"
      else if String.equal (String.trim transfer.source.post_id) ""
      then Error "paused-work transfer source post id must not be empty"
      else if
        transfer.continuation_binding
        <> continuation_binding_of_source transfer.source
      then Error "paused-work transfer continuation binding does not match source"
      else Ok ()
;;

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

let keeper_dir config keeper_name =
  let root = Workspace.masc_root_dir config in
  Filename.concat
    (Filename.concat root "paused-work-dispositions")
    ("keeper-" ^ sha256 keeper_name)
;;

let receipt_path config ~keeper_name ~operator_operation_id =
  Filename.concat
    (keeper_dir config keeper_name)
    ("operation-" ^ sha256 operator_operation_id ^ ".json")
;;

let continuation_binding_to_yojson = function
  | Routed channel ->
    `Assoc
      [ "kind", `String "routed"
      ; "channel", Keeper_continuation_channel.to_yojson channel
      ]
  | No_channel -> `Assoc [ "kind", `String "no_channel" ]
;;

let transfer_owner_to_yojson transfer =
  `Assoc
    [ "from_keeper", `String transfer.from_keeper
    ; "to_keeper", `String transfer.to_keeper
    ; "target_trace_id", `String (Keeper_id.Trace_id.to_string transfer.target_trace_id)
    ; "target_generation", `Int transfer.target_generation
    ; "source", Keeper_event_queue.stimulus_to_yojson transfer.source
    ; "source_revision", `Intlit (Int64.to_string transfer.source_revision)
    ; "settled_at", `Float transfer.settled_at
    ; "continuation_binding", continuation_binding_to_yojson transfer.continuation_binding
    ]
;;

let to_yojson receipt =
  let common operation schema extra =
    `Assoc
      ([ "schema", `String schema
       ; "operation", `String operation
       ; "keeper_name", `String receipt.keeper_name
       ; ( "expected_trace_id"
         , `String (Keeper_id.Trace_id.to_string receipt.expected_trace_id) )
       ; "expected_generation", `Int receipt.expected_generation
       ; "operator_operation_id", `String receipt.operator_operation_id
       ; "requested_at", `Float receipt.requested_at
       ]
       @ extra)
  in
  match receipt.operation with
  | Resume_owner ->
    common "resume_owner" "masc.keeper.paused-work-disposition.v1" []
  | Transfer_owner transfer ->
    common
      "transfer_owner"
      "masc.keeper.paused-work-disposition.v2"
      [ "transfer", transfer_owner_to_yojson transfer ]
;;

let sorted fields =
  List.sort (fun (left, _) (right, _) -> String.compare left right) fields
;;

let requested_at_of_yojson = function
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | `Intlit value ->
    (match Float.of_string_opt value with
     | Some value -> Ok value
     | None -> Error "paused-work disposition request time is invalid")
  | _ -> Error "paused-work disposition request time must be numeric"
;;

let source_revision_of_yojson = function
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some value -> Ok value
     | None -> Error "paused-work transfer source revision is invalid")
  | _ -> Error "paused-work transfer source revision must be an integer"
;;

let continuation_binding_of_yojson = function
  | `Assoc fields ->
    (match sorted fields with
     | [ "kind", `String "no_channel" ] -> Ok No_channel
     | [ "channel", channel_json; "kind", `String "routed" ] ->
       let* channel = Keeper_continuation_channel.of_yojson channel_json in
       Ok (Routed channel)
     | _ -> Error "paused-work transfer continuation binding fields are not exact")
  | _ -> Error "paused-work transfer continuation binding must be an object"
;;

let transfer_owner_of_yojson = function
  | `Assoc fields ->
    (match sorted fields with
     | [ ("continuation_binding", continuation_binding_json)
       ; ("from_keeper", `String from_keeper)
       ; ("settled_at", settled_at_json)
       ; ("source", source_json)
       ; ("source_revision", source_revision_json)
       ; ("target_generation", `Int target_generation)
       ; ("target_trace_id", `String target_trace_id)
       ; ("to_keeper", `String to_keeper)
       ] ->
       let* target_trace_id = Keeper_id.Trace_id.of_string target_trace_id in
       let* source = Keeper_event_queue.stimulus_of_yojson source_json in
       let* source_revision = source_revision_of_yojson source_revision_json in
       let* settled_at = requested_at_of_yojson settled_at_json in
       let* continuation_binding =
         continuation_binding_of_yojson continuation_binding_json
       in
       Ok
         { from_keeper
         ; to_keeper
         ; target_trace_id
         ; target_generation
         ; source
         ; source_revision
         ; settled_at
         ; continuation_binding
         }
     | _ -> Error "paused-work transfer fields are not exact")
  | _ -> Error "paused-work transfer must be an object"
;;

let receipt_of_common
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~operator_operation_id
      ~requested_at_json
      ~operation
  =
  let* requested_at = requested_at_of_yojson requested_at_json in
  let* expected_trace_id = Keeper_id.Trace_id.of_string expected_trace_id in
  let receipt =
    { keeper_name
    ; expected_trace_id
    ; expected_generation
    ; operator_operation_id
    ; requested_at
    ; operation
    }
  in
  let* () = validate receipt in
  Ok receipt
;;

let of_yojson = function
  | `Assoc fields ->
    (match sorted fields with
     | [ ("expected_generation", `Int expected_generation)
       ; ("expected_trace_id", `String expected_trace_id)
       ; ("keeper_name", `String keeper_name)
       ; ("operation", `String "resume_owner")
       ; ("operator_operation_id", `String operator_operation_id)
       ; ("requested_at", requested_at_json)
       ; ("schema", `String "masc.keeper.paused-work-disposition.v1")
       ] ->
       receipt_of_common
         ~keeper_name
         ~expected_trace_id
         ~expected_generation
         ~operator_operation_id
         ~requested_at_json
         ~operation:Resume_owner
     | [ ("expected_generation", `Int expected_generation)
       ; ("expected_trace_id", `String expected_trace_id)
       ; ("keeper_name", `String keeper_name)
       ; ("operation", `String "transfer_owner")
       ; ("operator_operation_id", `String operator_operation_id)
       ; ("requested_at", requested_at_json)
       ; ("schema", `String "masc.keeper.paused-work-disposition.v2")
       ; ("transfer", transfer_json)
       ] ->
       let* transfer = transfer_owner_of_yojson transfer_json in
       receipt_of_common
         ~keeper_name
         ~expected_trace_id
         ~expected_generation
         ~operator_operation_id
         ~requested_at_json
         ~operation:(Transfer_owner transfer)
     | _ -> Error "paused-work disposition receipt fields are not exact")
  | _ -> Error "paused-work disposition receipt must be a JSON object"
;;

let load config ~keeper_name ~operator_operation_id =
  if String.equal (String.trim keeper_name) ""
  then Error "paused-work disposition keeper name must not be empty"
  else if String.equal (String.trim operator_operation_id) ""
  then Error "paused-work disposition operation ID must not be empty"
  else
    let path = receipt_path config ~keeper_name ~operator_operation_id in
    if not (Fs_compat.file_exists path)
    then Ok None
    else
      let* json = Safe_ops.read_json_file_safe path in
      let* receipt = of_yojson json in
      if
        String.equal receipt.keeper_name keeper_name
        && String.equal receipt.operator_operation_id operator_operation_id
      then Ok (Some receipt)
      else Error "paused-work disposition receipt path identity does not match payload"
;;

let with_keeper_lock config ~keeper_name f =
  if String.equal (String.trim keeper_name) ""
  then Error "paused-work disposition keeper name must not be empty"
  else
    let dir = keeper_dir config keeper_name in
    let prepared =
      try
        (* fire-and-forget: only [ensure_dir]'s side effect matters; a failure is caught below and surfaced as [Error]. *)
        ignore (Keeper_fs.ensure_dir dir : string);
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    let* () = prepared in
    (match
       File_lock_eio.with_durable_lock
         ~lock_path:(Filename.concat dir "keeper-disposition.lock")
         (fun () -> f ({ keeper_name } : keeper_lock))
     with
     | Error error -> Error (File_lock_eio.durable_lock_error_to_string error)
     | Ok result -> Ok result)
;;

let save_if_absent (lock : keeper_lock) config receipt =
  let* () = validate receipt in
  let* () =
    if String.equal lock.keeper_name receipt.keeper_name
    then Ok ()
    else Error "paused-work disposition lock owner does not match receipt"
  in
  let root = Workspace.masc_root_dir config in
  let path =
    receipt_path
      config
      ~keeper_name:receipt.keeper_name
      ~operator_operation_id:receipt.operator_operation_id
  in
  let* existing =
    load
      config
      ~keeper_name:receipt.keeper_name
      ~operator_operation_id:receipt.operator_operation_id
  in
  match existing with
  | Some existing -> Ok (Existing existing)
  | None ->
    (match
       Keeper_fs.save_json_durable_atomic
         ~ownership_root:root
         ~pretty:false
         path
         (to_yojson receipt)
     with
     | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
     | Ok () ->
       let* persisted =
         load
           config
           ~keeper_name:receipt.keeper_name
           ~operator_operation_id:receipt.operator_operation_id
       in
       (match persisted with
        | Some persisted when equal persisted receipt -> Ok Created
        | Some _ -> Error "paused-work disposition receipt changed after durable write"
        | None -> Error "paused-work disposition receipt missing after durable write"))
;;
