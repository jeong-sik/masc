type error =
  | Invalid_keeper_name of string
  | Invalid_count of int
  | Malformed of string
  | Io_error of string

let error_to_string = function
  | Invalid_keeper_name name -> Printf.sprintf "invalid keeper name %S" name
  | Invalid_count count -> Printf.sprintf "transient exemption count must be positive, got %d" count
  | Malformed detail -> Printf.sprintf "malformed transient exemption state: %s" detail
  | Io_error detail -> Printf.sprintf "transient exemption state I/O failed: %s" detail
;;

let schema = "keeper.transient_transport_exemption.v1"
let filename = "transient-transport-exemption.json"

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
         (`Assoc [ "schema", `String schema; "count", `Int count ])
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
