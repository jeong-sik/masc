type error =
  | Invalid_keeper_name of string
  | Invalid_count of int
  | Malformed of string
  | Io_error of string

let error_to_string = function
  | Invalid_keeper_name name -> Printf.sprintf "invalid keeper name %S" name
  | Invalid_count count -> Printf.sprintf "turn failure streak must be positive, got %d" count
  | Malformed detail -> Printf.sprintf "malformed turn failure streak: %s" detail
  | Io_error detail -> Printf.sprintf "turn failure streak I/O failed: %s" detail
;;

let schema = "keeper.turn_failure_streak.v1"
let filename = "turn-failure-streak.json"

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

let to_json count =
  `Assoc [ "schema", `String schema; "count", `Int count ]
;;

let of_json = function
  | `Assoc [ ("schema", `String actual); ("count", `Int count) ]
  | `Assoc [ ("count", `Int count); ("schema", `String actual) ] ->
    if not (String.equal actual schema)
    then Error (Malformed (Printf.sprintf "unsupported schema %S" actual))
    else if count <= 0
    then Error (Invalid_count count)
    else Ok count
  | `Assoc _ -> Error (Malformed "expected exactly schema and positive integer count")
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

let save ~base_path ~keeper_name count =
  match validate_keeper_name keeper_name with
  | Error _ as error -> error
  | Ok () when count <= 0 -> Error (Invalid_count count)
  | Ok () ->
    let path = path_for ~base_path ~keeper_name in
    ignore (Keeper_fs.ensure_dir (Filename.dirname path));
    (match
       Keeper_fs.save_json_durable_atomic
         ~ownership_root:base_path
         ~pretty:false
         path
         (to_json count)
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
