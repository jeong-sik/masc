type t = { name : string; contents : string }

let decode ~task_id ~verification_id ~index json =
  let ( let* ) = Result.bind in
  let object_fields = function
    | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
    | _ -> Error "The evidence file response is not a unique object" in
  let* envelope = object_fields json in
  let* fields = match List.assoc_opt "ok" envelope, List.assoc_opt "result" envelope with
    | Some (`Bool true), Some result -> object_fields result
    | _ -> Error "The server did not return an evidence file" in
  let expected=["task_id";"verification_id";"item_index";"name";"body_base64";"bytes";"sha256"] in
  let* () = if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
    then Ok () else Error "The evidence file response has missing or unknown fields" in
  let string key = match List.assoc_opt key fields with
    | Some (`String value) -> Ok value
    | _ -> Error ("Missing evidence file field: " ^ key) in
  let* actual_task = string "task_id" in
  let* actual_request = string "verification_id" in
  let* () =
    if actual_task = task_id && actual_request = verification_id
       && List.assoc_opt "item_index" fields = Some (`Int index) && index >= 0
    then Ok () else Error "The file belongs to a different Task, submission or evidence item" in
  let* name = string "name" in
  let* () = if name <> "" && name <> "." && name <> ".."
      && Filename.basename name = name && String.is_valid_utf_8 name
      && not (String.exists (function '\000'..'\031' | '\127' | '\\' -> true | _ -> false) name)
    then Ok () else Error "The evidence filename is invalid" in
  let* encoded = string "body_base64" in
  let* contents = Base64.decode encoded |> Result.map_error (fun (`Msg detail) -> detail) in
  let* sha256 = string "sha256" in
  if List.assoc_opt "bytes" fields <> Some (`Int (String.length contents))
     || not (String.equal sha256 Digestif.SHA256.(to_hex (digest_string contents)))
  then Error "The downloaded evidence does not match its recorded size or SHA-256"
  else Ok {name; contents}

type progress = Not_started | Writing of string | Saved of string

let save ~fs ~directory ~directory_name ~path t =
  let ( let* ) = Result.bind in
  try
    Eio.Path.with_open_dir Eio.Path.(fs / directory) (fun registry_root ->
      let destination = Eio.Path.(registry_root / directory_name) in
      Eio.Path.mkdir ~perm:0o700 destination;
      Eio.Path.with_open_dir destination (fun parent ->
        let root = Eio.Path.stat ~follow:true parent in
        let* target =
          Fs_compat.capability_publication_target
            ~allowed_root_path:(Filename.dirname path)
            ~allowed_root_device:root.dev ~allowed_root_inode:root.ino
            ~parent_components:[] ~target_leaf:t.name ~permissions:0o600
          |> Result.map_error Fs_compat.capability_publication_target_error_to_string
        in
        Eio.Switch.run @@ fun sw ->
        let* registry =
          Fs_compat.Publication_recovery.open_registry ~sw ~fs ~registry_root
          |> Result.map_error Fs_compat.Publication_recovery.registry_error_to_string
        in
        match Fs_compat.Publication_recovery.with_lane
          ~registry ~owner:"tui-evidence-export" (fun recovery ->
            Fs_compat.create_capability_file_exclusive ~recovery ~parent ~target t.contents
            |> Result.map_error Fs_compat.capability_write_error_to_string)
        with
        | Error error -> Error (Fs_compat.Publication_recovery.lane_open_error_to_string error)
        | Ok (Fs_compat.Publication_recovery.Lane_released result) -> result
        | Ok (Fs_compat.Publication_recovery.Lane_release_failed { value; release_failure }) ->
          let detail = Fs_compat.Publication_recovery.lane_release_failure_to_string release_failure in
          Error (match value with Ok () -> detail | Error primary -> primary ^ "; " ^ detail)))
    |> Result.map_error (fun error -> path ^ ": " ^ error)
  with
  | Eio.Io _ as ex -> Error (path ^ ": " ^ Format.asprintf "%a" Eio.Exn.pp ex)
  | Sys_error detail -> Error (path ^ ": " ^ detail)
  | Unix.Unix_error (code, _, _) -> Error (path ^ ": " ^ Unix.error_message code)

let export ~fs ~directory ~progress ~admitted ~open_file t =
  let ( let* ) = Result.bind in
  let* () = admitted () in
  let directory = if Filename.is_relative directory then Filename.concat (Sys.getcwd ()) directory else directory in
  let directory_name = "masc-evidence-" ^ Random_id.uuid_v7 () in
  let path = Filename.concat (Filename.concat directory directory_name) t.name in
  Atomic.set progress (Writing path);
  let* () = save ~fs ~directory ~directory_name ~path t in
  Atomic.set progress (Saved path);
  match open_file with
  | None -> Ok path
  | Some open_file ->
    let* () = admitted () in
    let* () = open_file path in
    Ok path
