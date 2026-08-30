type error =
  | Invalid_keeper_name of string
  | Malformed of string
  | Io_error of string

let error_to_string = function
  | Invalid_keeper_name name -> Printf.sprintf "invalid keeper name %S" name
  | Malformed detail -> Printf.sprintf "malformed deferred runtime lane: %s" detail
  | Io_error detail -> Printf.sprintf "deferred runtime lane I/O failed: %s" detail
;;

let schema = "keeper.deferred_runtime_lane.v1"
let filename = "deferred-runtime-lane.json"

let path_for ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          Common.keepers_runtime_dirname)
       keeper_name)
    filename
;;

let exact_fields expected fields =
  let sort = List.sort String.compare in
  sort expected = sort (List.map fst fields)
;;

let ( let* ) = Result.bind

let failure_to_json failure =
  match Keeper_internal_error.classify_masc_internal_error failure with
  | Some internal ->
    `Assoc
      [ "kind", `String "masc_internal"
      ; "value", Keeper_internal_error.masc_internal_error_to_json internal
      ]
  | None ->
    (* The frozen ids are dispatch authority; an opaque upstream error is only
       provenance for the original deferral. Do not persist provider prose or
       reconstruct control flow by matching it after restart. *)
    `Assoc [ "kind", `String "opaque" ]
;;

let failure_of_json = function
  | `Assoc [ "kind", `String "opaque" ] ->
    Ok (Agent_core.Error.Internal "durably restored deferred runtime failure")
  | `Assoc fields
    when exact_fields [ "kind"; "value" ] fields ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "value" fields with
     | Some (`String "masc_internal"), Some value ->
       (match Keeper_internal_error.parse_masc_internal_error_json value with
        | Some internal ->
          Ok (Keeper_internal_error.core_error_of_masc_internal_error internal)
        | None -> Error (Malformed "failure.value is not a current MASC internal error"))
     | _ -> Error (Malformed "failure has an unknown current kind"))
  | `Assoc _ -> Error (Malformed "failure has unexpected fields")
  | _ -> Error (Malformed "failure is not an object")
;;

let to_json (hint : Keeper_turn_driver.deferred_runtime_lane) =
  `Assoc
    [ "schema", `String schema
    ; "assignment_id", `String hint.assignment_id
    ; "failed_runtime_id", `String hint.failed_runtime_id
    ; "next_runtime_id", `String hint.next_runtime_id
    ; "later_runtime_ids", `List (List.map (fun id -> `String id) hint.later_runtime_ids)
    ; "failure", failure_to_json hint.failure
    ]
;;

let nonempty_string field = function
  | `String value when not (String.equal value "") -> Ok value
  | _ -> Error (Malformed (field ^ " must be a non-empty string"))
;;

let string_list field = function
  | `List values ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest when not (String.equal value "") ->
        collect (value :: acc) rest
      | _ -> Error (Malformed (field ^ " must contain only non-empty strings"))
    in
    collect [] values
  | _ -> Error (Malformed (field ^ " must be a list"))
;;

let member field fields =
  Option.value ~default:`Null (List.assoc_opt field fields)
;;

let of_json = function
  | `Assoc fields
    when exact_fields
           [ "schema"
           ; "assignment_id"
           ; "failed_runtime_id"
           ; "next_runtime_id"
           ; "later_runtime_ids"
           ; "failure"
           ]
           fields ->
    let* () =
      match member "schema" fields with
      | `String value when String.equal value schema -> Ok ()
      | `String value -> Error (Malformed (Printf.sprintf "unsupported schema %S" value))
      | _ -> Error (Malformed "schema must be the current schema string")
    in
    let* assignment_id = nonempty_string "assignment_id" (member "assignment_id" fields) in
    let* failed_runtime_id =
      nonempty_string "failed_runtime_id" (member "failed_runtime_id" fields)
    in
    let* next_runtime_id =
      nonempty_string "next_runtime_id" (member "next_runtime_id" fields)
    in
    let* later_runtime_ids =
      string_list "later_runtime_ids" (member "later_runtime_ids" fields)
    in
    let* failure = failure_of_json (member "failure" fields) in
    Ok
      (Keeper_turn_driver.restore_deferred_runtime_lane
         ~assignment_id
         ~failed_runtime_id
         ~next_runtime_id
         ~later_runtime_ids
         ~failure)
  | `Assoc _ -> Error (Malformed "top-level object has unexpected fields")
  | _ -> Error (Malformed "top-level value is not an object")
;;

let validate_keeper_name keeper_name =
  if Keeper_config.validate_name keeper_name
  then Ok ()
  else Error (Invalid_keeper_name keeper_name)
;;

let load ~base_path ~keeper_name =
  match validate_keeper_name keeper_name with
  | Error _ as error -> error
  | Ok () ->
    let path = path_for ~base_path ~keeper_name in
    (try
       match Fs_compat.load_file_opt path with
       | None -> Ok None
       | Some raw ->
         (match Yojson.Safe.from_string raw with
          | json -> Result.map Option.some (of_json json)
          | exception Yojson.Json_error detail -> Error (Malformed detail))
     with
     | Eio.Cancel.Cancelled _ as error -> raise error
     | exn -> Error (Io_error (Printexc.to_string exn)))
;;

let save ~base_path ~keeper_name hint =
  match validate_keeper_name keeper_name with
  | Error _ as error -> error
  | Ok () ->
    let path = path_for ~base_path ~keeper_name in
    ignore (Keeper_fs.ensure_dir (Filename.dirname path));
    (match
       Keeper_fs.save_json_durable_atomic
         ~ownership_root:base_path
         ~pretty:false
         path
         (to_json hint)
     with
     | Ok () -> Ok ()
     | Error error ->
       Error (Io_error (Keeper_fs.durable_write_error_to_string error)))
;;

let clear ~base_path ~keeper_name =
  match validate_keeper_name keeper_name with
  | Error _ as error -> error
  | Ok () ->
    let path = path_for ~base_path ~keeper_name in
    (match Keeper_fs.remove_file_durable ~ownership_root:base_path path with
     | Ok () -> Ok ()
     | Error error ->
       Error (Io_error (Keeper_fs.durable_remove_error_to_string error)))
;;
