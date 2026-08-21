type request = Masc_tui_keeper_chat_projection.request

let schema = "masc.tui_keeper_chat_recovery.v1"
let filename = "tui-keeper-chat-recovery.json"
let max_reconciliation_polls = 40

let next_reconciliation_poll ~remaining =
  if remaining > 1 then `Poll (remaining - 1) else `Stop

let recovery_path ~base_path =
  Filename.concat (Filename.concat base_path Common.masc_dirname) filename

let encode (request : request) =
  `Assoc
    [ "schema", `String schema
    ; "request_id", `String request.request_id
    ; "keeper_name", `String request.keeper_name
    ; "message", `String request.message
    ]

let strict_fields = function
  | `Assoc fields ->
      let expected = [ "schema"; "request_id"; "keeper_name"; "message" ] in
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then Error "Keeper chat recovery record must contain unique fields"
      else
        (match List.find_opt (fun name -> not (List.mem name expected)) names with
         | Some name ->
             Error
               (Printf.sprintf
                  "Keeper chat recovery record has unknown field %S" name)
         | None ->
             (match
                List.find_opt
                  (fun name -> not (List.mem_assoc name fields))
                  expected
              with
              | Some name ->
                  Error
                    (Printf.sprintf
                       "Keeper chat recovery record is missing field %S" name)
              | None -> Ok fields))
  | _ -> Error "Keeper chat recovery record must be a JSON object"

let string_field fields name =
  match List.assoc name fields with
  | `String value -> Ok value
  | _ ->
      Error
        (Printf.sprintf "Keeper chat recovery field %S must be a string" name)

let decode json =
  let ( let* ) = Result.bind in
  let* fields = strict_fields json in
  let* observed_schema = string_field fields "schema" in
  let* () =
    if String.equal observed_schema schema
    then Ok ()
    else Error "Keeper chat recovery schema is unsupported"
  in
  let* request_id = string_field fields "request_id" in
  let* () =
    if String.starts_with ~prefix:"tui-" request_id
    then
      let raw_uuid = String.sub request_id 4 (String.length request_id - 4) in
      Random_id.parse_uuid_v7 raw_uuid |> Result.map (fun _ -> ())
    else Error "Keeper chat recovery request_id is not a TUI request"
  in
  let* keeper_name = string_field fields "keeper_name" in
  let* message = string_field fields "message" in
  let* () =
    if String.trim keeper_name = ""
    then Error "Keeper chat recovery keeper_name must not be blank"
    else Ok ()
  in
  let* () =
    if String.trim message = ""
    then Error "Keeper chat recovery message must not be blank"
    else Ok ()
  in
  Ok { Masc_tui_keeper_chat_projection.request_id; keeper_name; message }

let load_unlocked path =
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some raw ->
      (try Yojson.Safe.from_string raw |> decode |> Result.map Option.some with
       | Yojson.Json_error detail ->
           Error ("Keeper chat recovery JSON is invalid: " ^ detail))
  | exception exn ->
      Error ("Keeper chat recovery read failed: " ^ Printexc.to_string exn)

let with_lock path f =
  try File_lock_eio.with_lock path f with
  | exn -> Error ("Keeper chat recovery lock failed: " ^ Printexc.to_string exn)

let persist_pending ~base_path request =
  let path = recovery_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    with_lock path (fun () ->
      match load_unlocked path with
      | Error _ as error -> error
      | Ok (Some current)
        when not
               (Masc_tui_keeper_chat_projection.same_request_identity current
                  request) ->
          Error
            (Printf.sprintf
               "another Keeper chat request is still fenced: %s"
               current.request_id)
      | Ok (Some _) -> Ok ()
      | Ok None ->
          let content = Yojson.Safe.to_string (encode request) ^ "\n" in
          (match Fs_compat.save_file_atomic_strict path content with
           | Error detail -> Error detail
           | Ok () ->
               (try
                  Unix.chmod path 0o600;
                  Ok ()
                with exn ->
                  Error
                    ("Keeper chat recovery chmod failed: "
                   ^ Printexc.to_string exn))))
  with exn ->
    Error ("Keeper chat recovery write failed: " ^ Printexc.to_string exn)

let load_pending ~base_path =
  let path = recovery_path ~base_path in
  if not (Fs_compat.file_exists path)
  then Ok None
  else with_lock path (fun () -> load_unlocked path)

let clear_pending ~base_path request =
  let path = recovery_path ~base_path in
  if not (Fs_compat.file_exists path)
  then Ok ()
  else
    with_lock path (fun () ->
      match load_unlocked path with
      | Error _ as error -> error
      | Ok None -> Ok ()
      | Ok (Some current)
        when Masc_tui_keeper_chat_projection.same_request_identity current
               request ->
          (try
             Fs_compat.remove_tree path;
             Ok ()
           with exn ->
             Error
               ("Keeper chat recovery clear failed: " ^ Printexc.to_string exn))
      | Ok (Some current) ->
          Error
            (Printf.sprintf
               "refusing to clear different Keeper chat request %s"
               current.request_id))
