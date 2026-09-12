(* Implementation counterpart to keeper_config_journal.mli — see the
   design note there for why rollback-to-before-image is the
   convergence authority. *)

let journal_filename = "keeper-config-journal.json"

type phase =
  | Prepared
  | Manifest_committed
  | Rolling_back

type manifest_before_image =
  | Manifest_absent
  | Manifest_bytes of string

type rollback_result =
  { manifest_restored : bool
  ; runtime_restored : bool
  }

type runtime_before_image =
  | Runtime_absent
  | Runtime_bytes of string

type record =
  { tx_id : string
  ; keeper_name : string
  ; manifest_before : manifest_before_image
  ; runtime_before : runtime_before_image option
  ; manifest_path : string
  ; runtime_path : string option
  ; started_at_unix : float
  ; phase : phase
  }

type recovery_outcome =
  | No_journal
  | Recovered_rolled_back of
      { manifest_restored : bool
      ; runtime_restored : bool
      ; notes : string list
      }
  | Journal_corrupt of string
  | Recovery_failed of
      { detail : string
      ; notes : string list
      }

type report =
  { outcome : recovery_outcome
  ; journal_path : string
  ; record : record option
  }

let phase_to_string = function
  | Prepared -> "prepared"
  | Manifest_committed -> "manifest_committed"
  | Rolling_back -> "rolling_back"
;;

let phase_of_string = function
  | "prepared" -> Ok Prepared
  | "manifest_committed" -> Ok Manifest_committed
  | "rolling_back" -> Ok Rolling_back
  | other -> Error (Printf.sprintf "unknown journal phase %S" other)
;;

let manifest_snapshot_to_yojson = function
  | Manifest_absent -> `Assoc [ "state", `String "absent" ]
  | Manifest_bytes bytes ->
    `Assoc [ "state", `String "present"; "bytes", `String bytes ]
;;

let manifest_snapshot_of_yojson = function
  | `Assoc [ ("state", `String "absent") ] -> Ok Manifest_absent
  | `Assoc
      ([ ("state", `String "present"); ("bytes", `String bytes) ]
      | [ ("bytes", `String bytes); ("state", `String "present") ]) ->
    Ok (Manifest_bytes bytes)
  | _ -> Error "journal.manifest_before must be {state: absent|present, bytes?}"
;;

let string_option_to_yojson = function
  | None -> `Null
  | Some value -> `String value

let string_option_of_yojson = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error "expected string or null"

let runtime_before_image_to_yojson = function
  | None -> `Null
  | Some Runtime_absent -> manifest_snapshot_to_yojson Manifest_absent
  | Some (Runtime_bytes bytes) -> manifest_snapshot_to_yojson (Manifest_bytes bytes)
;;

let runtime_before_image_option_of_yojson = function
  | `Null -> Ok None
  | json ->
    manifest_snapshot_of_yojson json
    |> Result.map (function
         | Manifest_absent -> Some Runtime_absent
         | Manifest_bytes bytes -> Some (Runtime_bytes bytes))

let record_to_yojson (record : record) =
  `Assoc
    [ "tx_id", `String record.tx_id
    ; "keeper_name", `String record.keeper_name
    ; "manifest_before", manifest_snapshot_to_yojson record.manifest_before
    ; "runtime_before", runtime_before_image_to_yojson record.runtime_before
    ; "manifest_path", `String record.manifest_path
    ; "runtime_path", string_option_to_yojson record.runtime_path
    ; "started_at_unix", `Float record.started_at_unix
    ; "phase", `String (phase_to_string record.phase)
    ]
;;

let record_of_yojson = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let field name =
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "journal.%s is required" name)
    in
    let* tx_id =
      let* value = field "tx_id" in
      match value with `String value -> Ok value | _ -> Error "journal.tx_id must be a string"
    in
    let* keeper_name =
      let* value = field "keeper_name" in
      match value with
      | `String value -> Ok value
      | _ -> Error "journal.keeper_name must be a string"
    in
    let* manifest_before =
      let* value = field "manifest_before" in
      manifest_snapshot_of_yojson value
    in
    let* runtime_before =
      let* value = field "runtime_before" in
      runtime_before_image_option_of_yojson value
    in
    let* manifest_path =
      let* value = field "manifest_path" in
      match value with
      | `String value -> Ok value
      | _ -> Error "journal.manifest_path must be a string"
    in
    let* runtime_path =
      let* value = field "runtime_path" in
      string_option_of_yojson value
    in
    let* started_at_unix =
      let* value = field "started_at_unix" in
      match value with
      | `Float value -> Ok value
      | `Int value -> Ok (float_of_int value)
      | _ -> Error "journal.started_at_unix must be a number"
    in
    let* phase =
      let* value = field "phase" in
      match value with
      | `String value -> phase_of_string value
      | _ -> Error "journal.phase must be a string"
    in
    Ok { tx_id; keeper_name; manifest_before; runtime_before; manifest_path; runtime_path; started_at_unix; phase }
  | _ -> Error "journal record must be an object"
;;

let journal_path_for_base_path ~base_path =
  Filename.concat
    (Config_dir_resolver.resolve_for_base_path ~base_path).config_root.path
    journal_filename
;;

let encode record = Yojson.Safe.to_string (record_to_yojson record)

let write_atomic ~path content =
  Fs_compat.write_file_atomic_strict_staged path
    ~write:(fun channel ->
      Unix.fchmod (Unix.descr_of_out_channel channel) 0o600;
      output_string channel content)
  |> Result.map_error Fs_compat.atomic_replace_failure_to_string
;;

let read_before_image ~path =
  Eio_guard.run_in_systhread ~label:"config-journal-read" (fun () ->
    try
      let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
      let channel = Unix.in_channel_of_descr fd in
      Fun.protect ~finally:(fun () -> close_in_noerr channel)
        (fun () -> Ok (Some (In_channel.input_all channel)))
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | Unix.Unix_error (error, action, detail) ->
      Error (Printf.sprintf "%s %s: %s" action detail (Unix.error_message error))
    | Sys_error detail -> Error detail)
;;

let load ~journal_path =
    match read_before_image ~path:journal_path with
    | Error detail -> Error detail
    | Ok None -> Ok None
    | Ok (Some bytes) -> (
      match Yojson.Safe.from_string bytes with
      | exception Yojson.Json_error detail ->
        Error ("journal parse failed: " ^ detail)
      | json -> (
        match record_of_yojson json with
        | Ok record -> Ok (Some record)
        | Error detail -> Error ("journal decode failed: " ^ detail)))
;;

let validate_targets ~base_path record =
  let manifest_path =
    Filename.concat
      (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
      (record.keeper_name ^ ".toml")
  in
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  if not (Safe_identifier.is_portable_name record.keeper_name) then
    Error "journal keeper name is invalid"
  else if not (String.equal manifest_path record.manifest_path) then
    Error "journal manifest path does not belong to this configuration root"
  else
    match record.runtime_path, record.runtime_before with
    | None, None -> Ok ()
    | Some path, Some _ when String.equal path runtime_path -> Ok ()
    | _ -> Error "journal runtime before-image and path do not match this configuration root"
;;

let sync_directory path =
  let directory = Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close directory)
    (fun () -> Unix.fsync directory)
;;

let remove_durable ~path =
  Eio_guard.run_in_systhread ~label:"config-journal-remove" (fun () ->
    try
      (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      sync_directory (Filename.dirname path);
      Ok ()
    with
    | Sys_error message -> Error message
    | Unix.Unix_error (error, action, detail) ->
      Error
        (Printf.sprintf "%s %s (%s)" action detail (Unix.error_message error)))
;;

let clear ~journal_path = remove_durable ~path:journal_path

let require_resolved_with_sync_parent ~sync_parent ~runtime_config_path =
  let journal_path = Filename.concat (Filename.dirname runtime_config_path) journal_filename in
  match load ~journal_path with
  | Ok None ->
    (* A previous clear may have unlinked the marker but failed its parent
       sync. Confirm its retirement before another write can invalidate the
       before-images that a crash could otherwise resurrect. *)
    Eio_guard.run_in_systhread ~label:"config-journal-retirement" (fun () ->
      try sync_parent (Filename.dirname journal_path); Ok () with
      | Sys_error detail -> Error ("configuration journal retirement unconfirmed: " ^ detail)
      | Unix.Unix_error (error, action, path) ->
        Error (Printf.sprintf "configuration journal retirement unconfirmed: %s %s: %s"
          action path (Unix.error_message error)))
  | Ok (Some record) ->
    Error (Printf.sprintf
      "configuration recovery required before writing %s: journal %s retains tx=%s keeper=%s; restart the owner to recover"
      runtime_config_path journal_path record.tx_id record.keeper_name)
  | Error detail ->
    Error (Printf.sprintf
      "configuration recovery required before writing %s: cannot read journal %s: %s"
      runtime_config_path journal_path detail)
;;

let require_resolved = require_resolved_with_sync_parent ~sync_parent:sync_directory

module For_testing = struct
  let require_resolved_with_sync_parent = require_resolved_with_sync_parent
end

let stage ~base_path record =
  let ( let* ) = Result.bind in
  let* () = validate_targets ~base_path record in
  let path = journal_path_for_base_path ~base_path in
  let* existing = load ~journal_path:path in
  match existing with
  | Some _ -> Error "unresolved keeper configuration journal already exists"
  | None ->
    (match write_atomic ~path (encode record) with
     | Ok () -> Ok ()
     | Error detail ->
       (* No protected file has changed yet. If the marker rename happened,
          retire it durably instead of leaving a resolved abort to replay. *)
       match remove_durable ~path with
       | Ok () -> Error detail
       | Error cleanup -> Error (detail ^ "; journal cleanup failed: " ^ cleanup))
;;

let apply_rollback record ~manifest_restore ~runtime_restore =
  let manifest_failures = ref [] in
  let manifest_restored =
    match record.manifest_before with
    | Manifest_absent ->
      (match manifest_restore record.manifest_path Manifest_absent with
       | Ok () -> true
       | Error detail ->
         manifest_failures := detail :: !manifest_failures;
         false)
    | Manifest_bytes bytes ->
      (match manifest_restore record.manifest_path (Manifest_bytes bytes) with
       | Ok () -> true
       | Error detail ->
         manifest_failures := detail :: !manifest_failures;
         false)
  in
  let runtime_failures = ref [] in
  let runtime_restored =
    match record.runtime_before, record.runtime_path with
    | Some (Runtime_bytes source_text), Some path ->
      (match runtime_restore path (Runtime_bytes source_text) with
       | Ok () -> true
       | Error detail ->
         runtime_failures := detail :: !runtime_failures;
         false)
    | Some Runtime_absent, Some path ->
      (match runtime_restore path Runtime_absent with
       | Ok () -> true
       | Error detail ->
         runtime_failures := detail :: !runtime_failures;
         false)
    | None, None -> true
    | None, Some _ | Some _, None ->
      runtime_failures := ["runtime before-image and target path disagree"];
      false
  in
  let failures = !manifest_failures @ !runtime_failures in
  if not manifest_restored || not runtime_restored
  then Error ("recovery left files unrestored", failures)
  else Ok { manifest_restored; runtime_restored }
;;

let recover_interrupted ~base_path ~manifest_restore ~runtime_restore =
  let journal_path = journal_path_for_base_path ~base_path in
  match load ~journal_path with
  | Error detail ->
    { outcome = Journal_corrupt detail
    ; journal_path
    ; record = None
    }
  | Ok None -> { outcome = No_journal; journal_path; record = None }
  | Ok (Some record) ->
    (match validate_targets ~base_path record with
     | Error detail -> { outcome = Journal_corrupt detail; journal_path; record = Some record }
     | Ok () ->
    match apply_rollback record ~manifest_restore ~runtime_restore with
     | Ok { manifest_restored; runtime_restored } ->
       (match clear ~journal_path with
        | Ok () ->
          { outcome =
              Recovered_rolled_back
                { manifest_restored; runtime_restored; notes = [] }
          ; journal_path
          ; record = Some record
          }
        | Error detail ->
          { outcome =
              Recovery_failed
                { detail =
                    Printf.sprintf "journal clear failed after rollback: %s" detail
                ; notes =
                    [
                      Printf.sprintf
                        "journal_path=%s manifest_restored=%b runtime_restored=%b"
                        journal_path
                        manifest_restored
                        runtime_restored
                    ]
                }
          ; journal_path
          ; record = Some record
          })
     | Error (detail, notes) ->
       { outcome = Recovery_failed { detail; notes }
       ; journal_path
       ; record = Some record
       })
;;
