type t =
  { runtime_id : string
  ; actual_chars : int
  ; max_chars : int
  }

let ( let* ) = Result.bind

let filename = "librarian-input-capacity.json"

let path ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) filename
;;

let valid { runtime_id; actual_chars; max_chars } =
  String.trim runtime_id <> "" && actual_chars > max_chars && max_chars > 0
;;

let to_json { runtime_id; actual_chars; max_chars } =
  `Assoc
    [ "runtime_id", `String runtime_id
    ; "actual_chars", `Int actual_chars
    ; "max_chars", `Int max_chars
    ]
;;

let of_json = function
  | `Assoc fields ->
    (match
       List.assoc_opt "runtime_id" fields,
       List.assoc_opt "actual_chars" fields,
       List.assoc_opt "max_chars" fields
     with
     | Some (`String runtime_id), Some (`Int actual_chars), Some (`Int max_chars) ->
       let value = { runtime_id; actual_chars; max_chars } in
       if valid value then Ok value else Error "capacity evidence is out of range"
     | _ -> Error "capacity evidence has an invalid shape")
  | _ -> Error "capacity evidence must be an object"
;;

let load ~keepers_dir ~keeper_id =
  let path = path ~keepers_dir ~keeper_id in
  match Fs_compat.exact_path_kind ~follow:false path with
  | Fs_compat.Exact_missing -> Ok None
  | Fs_compat.Exact_kind _ ->
    (try
       let* json =
         try Ok (Yojson.Safe.from_string (Fs_compat.load_file path)) with
         | Yojson.Json_error detail -> Error detail
       in
       Result.map Option.some (of_json json)
     with
     | Sys_error detail -> Error detail
     | Unix.Unix_error (code, fn, arg) ->
       Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
  | Fs_compat.Exact_unknown -> Error "capacity evidence path cannot be inspected"
;;

let save ~keepers_dir ~keeper_id value =
  if not (valid value) then Error "capacity evidence is out of range"
  else
    let path = path ~keepers_dir ~keeper_id in
    try
      match
        Fs_compat.mkdir_p (Filename.dirname path);
        Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string (to_json value))
      with
      | Ok () -> Ok ()
      | Error detail -> Error detail
    with
    | Sys_error detail -> Error detail
    | Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
;;
