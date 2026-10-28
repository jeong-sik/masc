type error = Unknown_keeper | History_unavailable of string

let error_to_string = function
  | Unknown_keeper -> "No registered Keeper or retained history exists for this name."
  | History_unavailable _ -> "Keeper history is temporarily unavailable; retry the request."

module Physical = Keeper_chat_history_page
module Autonomous = Keeper_autonomous_turn_source

type source =
  { fingerprint : string
  ; autonomous : Autonomous.snapshot
  }

type metadata = Metadata_absent | Metadata_current | Metadata_unavailable of string

let metadata_evidence ~config path =
  match Keeper_meta_store.read_meta_file_path_read_only
      ~ownership_root:config.Workspace.base_path path with
  | Ok None -> Metadata_absent
  | Ok (Some _) -> Metadata_current
  | Error (Keeper_meta_store.Unreadable detail | Keeper_meta_store.Invalid_json detail | Keeper_meta_store.Not_current detail) ->
    Metadata_unavailable detail

let metadata_stamp = function
  | Metadata_absent -> "absent"
  | Metadata_current -> "current"
  | Metadata_unavailable _ -> "unavailable"

let directory_stamp path =
  try
    match Unix.stat path with
    | { Unix.st_kind = Unix.S_DIR; st_dev; st_ino; st_mtime; st_ctime; _ } ->
      Ok (Printf.sprintf "%d:%d:%h:%h" st_dev st_ino st_mtime st_ctime)
    | { Unix.st_kind = Unix.(S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK); _ } ->
      Error (History_unavailable ("trace root is not a directory: " ^ path))
  with Unix.Unix_error (cause, operation, argument) ->
    if cause = Unix.ENOENT then Ok "absent"
    else Error (History_unavailable
        (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message cause)))

let inspect ~config ~keeper_name =
  let open Result.Syntax in
  let physical path = Physical.inspect_source ~path
      |> Result.map_error (fun error -> History_unavailable (Physical.error_to_string error)) in
  let* chat = physical
      (Keeper_chat_store.chat_path ~base_dir:config.Workspace.base_path ~keeper_name) in
  (* Path derivation only: Keeper_types_profile.keeper_meta_path would create
     the root on an unknown-name read. Historical metadata is evidence of the
     owner even when that Keeper is offline or its declaration was removed. *)
  let meta_path = Filename.concat (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name Keeper_runtime_root_entry.Metadata) in
  let meta = metadata_evidence ~config meta_path in
  let* autonomous = Autonomous.read_snapshot_result ~config ~keeper_name ()
      |> Result.map_error (fun detail -> History_unavailable detail) in
  let retained_elsewhere =
    Keeper_registry.is_registered ~base_path:config.Workspace.base_path keeper_name
    || Physical.source_is_present chat || Autonomous.snapshot_has_records autonomous in
  let* () = match retained_elsewhere, meta with
    | true, (Metadata_absent | Metadata_current | Metadata_unavailable _)
    | false, Metadata_current -> Ok ()
    | false, Metadata_absent -> Error Unknown_keeper
    | false, Metadata_unavailable detail -> Error (History_unavailable detail) in
    let* trace = directory_stamp (Keeper_types_support.keeper_raw_trace_dir config keeper_name) in
    let fingerprint = String.concat "\000"
        [ Physical.source_fingerprint chat
        (* Metadata supplies read authority and optional trace-id enrichment.
           Counter-only writes do not change transcript membership; enrichment
           retains its existing TTL rather than invalidating on each heartbeat. *)
        ; metadata_stamp meta
        ; Autonomous.snapshot_fingerprint autonomous
        ; trace
        ; string_of_int (Keeper_tool_call_log.committed_revision ~keeper_name)
        ] in
    Ok { fingerprint; autonomous }

let after_read_hook : (unit -> unit) option Atomic.t = Atomic.make None

let read_source_json ~config ~keeper_name ~render source =
  let open Result.Syntax in
  let* messages = Keeper_chat_store.load_result ~base_dir:config.Workspace.base_path ~keeper_name
      |> Result.map_error (fun error -> History_unavailable (Physical.error_to_string error)) in
  let* turns = Autonomous.project_snapshot_result ~config ~keeper_name source.autonomous
      |> Result.map_error (fun detail -> History_unavailable detail) in
  Option.iter (fun hook -> hook ()) (Atomic.get after_read_hook);
  Ok (render messages turns)

let read_json ~config ~keeper_name ~render =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let open Result.Syntax in
    let* source = inspect ~config ~keeper_name in
    read_source_json ~config ~keeper_name ~render source)

(* Dashboard_cache publishes JSON values and uses exceptions to reject a
   failed compute. This local adapter keeps read failures out of that JSON
   channel, and its handler returns the public closed Result. *)
exception Read_failed of error

let cached_json ~config ~keeper_name ~ttl ~render =
  let key = Printf.sprintf "keeper:chat-history:%s:%s" (Workspace.masc_dir config) keeper_name in
  let refuse error = Dashboard_cache.invalidate key; Error error in
  (* A body that was strictly read remains a valid observation when a writer
     commits afterwards. Retire its cache ownership before publication, then
     let the next request read that newer source instead of rejecting this one.
     A failed later inspection also prevents retention; it cannot retroactively
     make the already-read body an unreadable or empty successful transcript. *)
  let retire_if_changed fingerprint =
    match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> inspect ~config ~keeper_name) with
    | Ok after when String.equal fingerprint after.fingerprint -> ()
    | Ok _ | Error (Unknown_keeper | History_unavailable _) -> Dashboard_cache.invalidate key
  in
  match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> inspect ~config ~keeper_name) with
  | Error error -> refuse error
  | Ok source ->
    (match Dashboard_cache.peek key with
     | Some (`Assoc fields) ->
       (match List.assoc_opt "freshness" fields with
        | Some (`String stamp) when String.equal stamp source.fingerprint -> ()
        | Some _ | None -> Dashboard_cache.invalidate key)
     | Some _ -> Dashboard_cache.invalidate key
     | None -> ());
    (try
       let cached = Dashboard_cache.get_or_compute key ~ttl @@ Pool_work.cpu ~name:__FUNCTION__ (fun () ->
         match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
             read_source_json ~config ~keeper_name ~render source) with
         | Ok body ->
           retire_if_changed source.fingerprint;
           `Assoc [ "freshness", `String source.fingerprint; "body", body ]
         | Error error ->
           (* Also retire a stale slot before the cache's background-refresh
              exception handler can restore it as an apparent success. *)
           Dashboard_cache.invalidate key;
           raise (Read_failed error)) in
       if Dashboard_cache.is_timeout_envelope cached then Ok cached
       else
         match cached with
         | `Assoc fields ->
           (match List.assoc_opt "freshness" fields, List.assoc_opt "body" fields with
            | Some (`String stamp), Some body ->
              retire_if_changed stamp;
              Ok body
            | Some _, Some _ | Some _, None | None, _ ->
              refuse (History_unavailable "invalid cached history response"))
         | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
           refuse (History_unavailable "invalid cached history response")
     with Read_failed error -> refuse error)

module For_testing = struct
  let with_after_read_hook hook f =
    let previous = Atomic.exchange after_read_hook (Some hook) in
    Fun.protect ~finally:(fun () -> Atomic.set after_read_hook previous) f
end
