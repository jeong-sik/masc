type request = Masc_tui_keeper_chat_projection.request

type phase =
  | Prepared
  | Accepted

type pending =
  { request : request
  ; phase : phase
  }

type persistence_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string
  | Durable_write_cancelled of string
  | Accepted_already

exception Durable_commit_cancelled of exn

type staged_writer =
  string -> string -> (unit, Fs_compat.atomic_replace_failure) result

let schema = "masc.tui_keeper_chat_recovery.v2"
let filename = "tui-keeper-chat-recovery.json"
let max_reconciliation_polls = 40

let next_reconciliation_poll ~remaining =
  if remaining > 1 then `Poll (remaining - 1) else `Stop

let recovery_path ~base_path =
  Filename.concat (Filename.concat base_path Common.masc_dirname) filename

let phase_to_string = function
  | Prepared -> "prepared"
  | Accepted -> "accepted"

let phase_of_string = function
  | "prepared" -> Ok Prepared
  | "accepted" -> Ok Accepted
  | value ->
      Error (Printf.sprintf "Keeper chat recovery phase %S is unsupported" value)

let encode ({ request; phase } : pending) =
  `Assoc
    [ "schema", `String schema
    ; "phase", `String (phase_to_string phase)
    ; "request_id", `String request.request_id
    ; "keeper_name", `String request.keeper_name
    ; "message", `String request.message
    ]

let strict_fields = function
  | `Assoc fields ->
      let expected =
        [ "schema"; "phase"; "request_id"; "keeper_name"; "message" ]
      in
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
  let* phase_raw = string_field fields "phase" in
  let* phase = phase_of_string phase_raw in
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
  let request =
    { Masc_tui_keeper_chat_projection.request_id; keeper_name; message }
  in
  Ok { request; phase }

let load_unlocked path =
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some raw ->
      (try Yojson.Safe.from_string raw |> decode |> Result.map Option.some with
       | Yojson.Json_error detail ->
           Error ("Keeper chat recovery JSON is invalid: " ^ detail))
  | exception (Eio.Cancel.Cancelled _ as exn) ->
      Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exception exn ->
      Error ("Keeper chat recovery read failed: " ^ Printexc.to_string exn)

let with_lock path f =
  try File_lock_eio.with_lock path f with
  | Eio.Cancel.Cancelled _ as exn ->
      Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn -> Error ("Keeper chat recovery lock failed: " ^ Printexc.to_string exn)

let write_pending ~save_file_atomic_strict_staged path pending =
  let content = Yojson.Safe.to_string (encode pending) ^ "\n" in
  match save_file_atomic_strict_staged path content with
  | Ok () -> Ok Fsync_completed
  | Error (failure : Fs_compat.atomic_replace_failure) ->
      let detail = Fs_compat.atomic_replace_failure_to_string failure in
      (match failure.stage with
       | Fs_compat.Before_rename ->
           (match failure.exception_ with
            | Eio.Cancel.Cancelled _ ->
                Printexc.raise_with_backtrace
                  failure.exception_
                  failure.backtrace
            | _ -> Error detail)
       | Fs_compat.After_rename ->
           (match failure.exception_ with
            | Durable_commit_cancelled cancellation ->
                Ok (Durable_write_cancelled (Printexc.to_string cancellation))
            | _ -> Ok (Visible_sync_unconfirmed detail)))

let save_file_durable_staged_with ~save_bytes_durable_atomic_observed ~base_path
    path content =
  let committed = ref false in
  try
    match
      save_bytes_durable_atomic_observed
        ~on_durable_commit:(fun () -> committed := true)
        ~ownership_root:base_path path content
    with
    | Ok Masc.Keeper_fs.Committed -> Ok ()
    | Ok (Masc.Keeper_fs.Committed_but_observer_failed (exn, backtrace)) ->
        Error
          { Fs_compat.path
          ; stage = Fs_compat.After_rename
          ; exception_ = exn
          ; backtrace
          }
    | Error (failure : Masc.Keeper_fs.durable_write_error) ->
        let detail = Masc.Keeper_fs.durable_write_error_to_string failure in
        Error
          { Fs_compat.path
          ; stage =
              (if failure.renamed then Fs_compat.After_rename
               else Fs_compat.Before_rename)
          ; exception_ = Failure detail
          ; backtrace = Printexc.get_callstack 32
          }
  with Eio.Cancel.Cancelled _ as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (* The observer runs only after directory-chain, payload, rename, and
       parent-directory durability are complete. Preserve that phase, but do
       not let a cancelled persistence call authorize its next side effect. *)
    if !committed
    then
      Error
        { Fs_compat.path
        ; stage = Fs_compat.After_rename
        ; exception_ = Durable_commit_cancelled exn
        ; backtrace
        }
    else Printexc.raise_with_backtrace exn backtrace

let save_file_durable_staged =
  save_file_durable_staged_with
    ~save_bytes_durable_atomic_observed:(fun ~on_durable_commit ~ownership_root
                                             path content ->
      Masc.Keeper_fs.save_bytes_durable_atomic_observed ~on_durable_commit
        ~ownership_root path content)

let same_request left right =
  Masc_tui_keeper_chat_projection.same_request_identity
    left.request
    right

let persist_pending_with_writer ~save_file_atomic_strict_staged ~base_path
    request =
  let path = recovery_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    with_lock path (fun () ->
      match load_unlocked path with
      | Error _ as error -> error
      | Ok (Some current) when not (same_request current request) ->
          Error
            (Printf.sprintf
               "another Keeper chat request is still fenced: %s"
               current.request.request_id)
      | Ok (Some { phase = Accepted; _ }) ->
          Ok Accepted_already
      | Ok (Some { phase = Prepared; _ }) | Ok None ->
          (* The atomic helper installs its 0o600 temporary inode. There must be
             no fallible post-rename chmod between visibility and this staged
             outcome; the round-trip test locks the installed mode down. *)
          write_pending ~save_file_atomic_strict_staged path
            { request; phase = Prepared })
  with
  | Eio.Cancel.Cancelled _ as exn ->
      Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn ->
    Error ("Keeper chat recovery write failed: " ^ Printexc.to_string exn)

let persist_pending ~base_path request =
  persist_pending_with_writer
    ~save_file_atomic_strict_staged:(save_file_durable_staged ~base_path)
    ~base_path request

let mark_accepted_with_writer ~save_file_atomic_strict_staged ~base_path
    request =
  let path = recovery_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    with_lock path (fun () ->
      match load_unlocked path with
      | Error _ as error -> error
      | Ok None ->
          write_pending ~save_file_atomic_strict_staged path
            { request; phase = Accepted }
      | Ok (Some current) when not (same_request current request) ->
          Error
            (Printf.sprintf
               "another Keeper chat request is still fenced: %s"
               current.request.request_id)
      | Ok (Some _) ->
          write_pending ~save_file_atomic_strict_staged path
            { request; phase = Accepted })
  with
  | Eio.Cancel.Cancelled _ as exn ->
      Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn ->
      Error
        ("Keeper chat recovery acceptance write failed: "
       ^ Printexc.to_string exn)

let mark_accepted ~base_path request =
  mark_accepted_with_writer
    ~save_file_atomic_strict_staged:(save_file_durable_staged ~base_path)
    ~base_path request

let resume_pending { request; phase } ~retry_prepared ~reconcile_accepted =
  match phase with
  | Prepared -> retry_prepared request
  | Accepted -> reconcile_accepted request

let load_pending ~base_path =
  let path = recovery_path ~base_path in
  try
    if not (Fs_compat.file_exists path)
    then Ok None
    else with_lock path (fun () -> load_unlocked path)
  with
  | Eio.Cancel.Cancelled _ as exn ->
      Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn ->
      Error ("Keeper chat recovery read failed: " ^ Printexc.to_string exn)

let clear_pending_with_remover ~remove_file ~base_path request =
  let path = recovery_path ~base_path in
  try
    with_lock path (fun () ->
      let remove_exact_fence () =
        try
          remove_file path;
          Ok ()
        with Eio.Cancel.Cancelled _ as exn ->
          Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
        | exn ->
            Error
              ("Keeper chat recovery clear failed: " ^ Printexc.to_string exn)
      in
      match load_unlocked path with
      | Error _ as error -> error
      | Ok None ->
          (* The durable remover is intentionally invoked for ENOENT too: a
             prior unlink may have been visible while its parent fsync failed,
             and retry must finish that durability boundary. *)
          remove_exact_fence ()
      | Ok (Some current)
        when Masc_tui_keeper_chat_projection.same_request_identity
               current.request
               request -> remove_exact_fence ()
      | Ok (Some current) ->
          Error
            (Printf.sprintf
               "refusing to clear different Keeper chat request %s"
               current.request.request_id))
  with
  | Eio.Cancel.Cancelled _ as exn ->
      Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn ->
      Error ("Keeper chat recovery clear failed: " ^ Printexc.to_string exn)

let remove_file_durable_with ~remove_file_durable ~base_path path =
  try
    match remove_file_durable ~ownership_root:base_path path with
    | Ok () -> ()
    | Error failure ->
        failwith (Masc.Keeper_fs.durable_remove_error_to_string failure)
  with Eio.Cancel.Cancelled _ as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    if Sys.file_exists path
    then Printexc.raise_with_backtrace exn backtrace
    else
      failwith
        ("durable removal cancelled after the fence became absent: "
       ^ Printexc.to_string exn)

let clear_pending ~base_path request =
  let remove_file_durable =
    remove_file_durable_with
      ~remove_file_durable:(fun ~ownership_root path ->
        Masc.Keeper_fs.remove_file_durable ~ownership_root path)
      ~base_path
  in
  clear_pending_with_remover ~remove_file:remove_file_durable ~base_path request

module For_testing = struct
  type nonrec staged_writer = staged_writer

  type durable_bytes_writer =
    on_durable_commit:(unit -> unit) ->
    ownership_root:string ->
    string ->
    string ->
    ( Masc.Keeper_fs.durable_commit_outcome
    , Masc.Keeper_fs.durable_write_error )
    result

  type durable_file_remover =
    ownership_root:string ->
    string ->
    (unit, Masc.Keeper_fs.durable_remove_error) result

  let persist_pending_with_writer = persist_pending_with_writer
  let mark_accepted_with_writer = mark_accepted_with_writer
  let clear_pending_with_remover = clear_pending_with_remover
  let save_file_durable_staged_with = save_file_durable_staged_with
  let remove_file_durable_with = remove_file_durable_with
end
