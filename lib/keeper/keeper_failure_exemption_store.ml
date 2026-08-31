type state =
  { invalid_request_count : int
  ; empty_completion_count : int
  }

type error =
  | Invalid_keeper_name of string
  | Invalid_state of state
  | Malformed of string
  | Io_error of string

let zero = { invalid_request_count = 0; empty_completion_count = 0 }

let error_to_string = function
  | Invalid_keeper_name name -> Printf.sprintf "invalid keeper name %S" name
  | Invalid_state state ->
    Printf.sprintf
      "failure exemption counts must be non-negative with at least one positive, got invalid_request=%d empty_completion=%d"
      state.invalid_request_count
      state.empty_completion_count
  | Malformed detail -> Printf.sprintf "malformed failure exemption state: %s" detail
  | Io_error detail -> Printf.sprintf "failure exemption state I/O failed: %s" detail
;;

let schema = "keeper.failure_exemptions.v1"
let filename = "failure-exemptions.json"

let path_for ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          Common.keepers_runtime_dirname)
       keeper_name)
    filename
;;

let validate_keeper_name keeper_name =
  if Keeper_config.validate_name keeper_name
  then Ok ()
  else Error (Invalid_keeper_name keeper_name)
;;

let validate_state state =
  if
    state.invalid_request_count < 0
    || state.empty_completion_count < 0
    || state.invalid_request_count + state.empty_completion_count <= 0
  then Error (Invalid_state state)
  else Ok state
;;

let to_json state =
  `Assoc
    [ "schema", `String schema
    ; "invalid_request_count", `Int state.invalid_request_count
    ; "empty_completion_count", `Int state.empty_completion_count
    ]
;;

let of_json = function
  | `Assoc fields when List.length fields = 3 ->
    (match
       ( List.assoc_opt "schema" fields
       , List.assoc_opt "invalid_request_count" fields
       , List.assoc_opt "empty_completion_count" fields )
     with
     | ( Some (`String actual)
       , Some (`Int invalid_request_count)
       , Some (`Int empty_completion_count) ) ->
       if not (String.equal actual schema)
       then Error (Malformed (Printf.sprintf "unsupported schema %S" actual))
       else validate_state { invalid_request_count; empty_completion_count }
     | _ -> Error (Malformed "expected current schema and two integer counts"))
  | `Assoc _ -> Error (Malformed "expected exactly three fields")
  | _ -> Error (Malformed "top-level value is not an object")
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

let save ~base_path ~keeper_name state =
  match validate_keeper_name keeper_name, validate_state state with
  | (Error _ as error), _ -> error
  | _, (Error _ as error) -> error
  | Ok (), Ok state ->
    let path = path_for ~base_path ~keeper_name in
    ignore (Keeper_fs.ensure_dir (Filename.dirname path));
    (match
       Keeper_fs.save_json_durable_atomic
         ~ownership_root:base_path
         ~pretty:false
         path
         (to_json state)
     with
     | Ok () -> Ok ()
     | Error error -> Error (Io_error (Keeper_fs.durable_write_error_to_string error)))
;;

let clear ~base_path ~keeper_name =
  match validate_keeper_name keeper_name with
  | Error _ as error -> error
  | Ok () ->
    let path = path_for ~base_path ~keeper_name in
    (match Keeper_fs.remove_file_durable ~ownership_root:base_path path with
     | Ok () -> Ok ()
     | Error error -> Error (Io_error (Keeper_fs.durable_remove_error_to_string error)))
;;
