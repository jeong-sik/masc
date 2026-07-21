type operation = Resume_owner

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

type keeper_lock = { keeper_name : string }

let ( let* ) = Result.bind

let equal left right =
  String.equal left.keeper_name right.keeper_name
  && Keeper_id.Trace_id.equal left.expected_trace_id right.expected_trace_id
  && Int.equal left.expected_generation right.expected_generation
  && String.equal left.operator_operation_id right.operator_operation_id
  && Float.equal left.requested_at right.requested_at
  && left.operation = right.operation
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

let to_yojson receipt =
  `Assoc
    [ "schema", `String "masc.keeper.paused-work-disposition.v1"
    ; "operation", `String "resume_owner"
    ; "keeper_name", `String receipt.keeper_name
    ; ( "expected_trace_id"
      , `String (Keeper_id.Trace_id.to_string receipt.expected_trace_id) )
    ; "expected_generation", `Int receipt.expected_generation
    ; "operator_operation_id", `String receipt.operator_operation_id
    ; "requested_at", `Float receipt.requested_at
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    let fields =
      List.sort (fun (left, _) (right, _) -> String.compare left right) fields
    in
    (match fields with
     | [ ("expected_generation", `Int expected_generation)
       ; ("expected_trace_id", `String expected_trace_id)
       ; ("keeper_name", `String keeper_name)
       ; ("operation", `String "resume_owner")
       ; ("operator_operation_id", `String operator_operation_id)
       ; ("requested_at", requested_at_json)
       ; ("schema", `String "masc.keeper.paused-work-disposition.v1")
       ] ->
       let* requested_at =
         match requested_at_json with
         | `Float value -> Ok value
         | `Int value -> Ok (Float.of_int value)
         | `Intlit value ->
           (match Float.of_string_opt value with
            | Some value -> Ok value
            | None -> Error "paused-work disposition request time is invalid")
         | _ -> Error "paused-work disposition request time must be numeric"
       in
       let* expected_trace_id = Keeper_id.Trace_id.of_string expected_trace_id in
       let receipt =
         { keeper_name
         ; expected_trace_id
         ; expected_generation
         ; operator_operation_id
         ; requested_at
         ; operation = Resume_owner
         }
       in
       let* () = validate receipt in
       Ok receipt
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
         (fun () -> f { keeper_name })
     with
     | Error error -> Error (File_lock_eio.durable_lock_error_to_string error)
     | Ok result -> Ok result)
;;

let save_if_absent lock config receipt =
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
