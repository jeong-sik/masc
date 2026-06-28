(** Keeper_msg_async — fire-and-forget keeper message execution.

    Manages background fibers for keeper_msg turns.
    MCP tool returns immediately with a request_id;
    clients poll keeper_msg_result for completion.

    Completed entries auto-expire from memory after [max_age_sec] to prevent
    memory leaks. Non-terminal entries remain queryable until they either
    complete or are recovered from disk as lost after a process restart. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type request_status =
  | Queued
  | Running
  | Lost of { reason : string }
  | Cancelled of
      { reason : string
      ; cancelled_by : string
      }
  | Done of
      { ok : bool
      ; body : string
      }

type entry =
  { request_id : string
  ; keeper_name : string
  ; base_path : string
  ; status : request_status
  ; submitted_at : float
  ; completed_at : float option
  }

(** Outcome of looking up a request record. [Absent] means no record exists
    (never submitted, or already GC'd); pollers can stop polling or resubmit.
    [Unreadable] means a record file exists but cannot be decoded — the
    request WAS accepted, but its result cannot be recovered. *)
type load_result =
  | Found of entry
  | Absent
  | Unreadable of string

let mu = Eio.Mutex.create ()
let pending : (string, entry) Hashtbl.t = Hashtbl.create 16
let active_switches : (string, Eio.Switch.t) Hashtbl.t = Hashtbl.create 16
exception CancelledByOperator
exception Worker_timeout of float
let counter = Atomic.make 0
let max_age_sec = Masc_time_constants.hour

let request_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests"
;;

let max_request_id_len = 128

let is_safe_request_id request_id =
  let len = String.length request_id in
  if len = 0
  then false
  else if request_id = "." || request_id = ".."
  then false
  else if len > max_request_id_len
  then false
  else (
    let rec loop i =
      if i = len
      then true
      else (
        match request_id.[i] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> loop (i + 1)
        | _ -> false)
    in
    loop 0)
;;

let record_path ~base_path ~request_id =
  if is_safe_request_id request_id
  then Some (Filename.concat (request_dir ~base_path) (request_id ^ ".json"))
  else None
;;

let status_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Lost _ -> "lost"
  | Cancelled _ -> "cancelled"
  | Done { ok = true; _ } -> "done"
  | Done { ok = false; _ } -> "error"
;;

let entry_record_to_json (e : entry) : Yojson.Safe.t =
  let fields =
    [ "request_id", `String e.request_id
    ; "keeper_name", `String e.keeper_name
    ; "base_path", `String e.base_path
    ; "status", `String (status_to_string e.status)
    ; "submitted_at", `Float e.submitted_at
    ]
  in
  let fields =
    match e.completed_at with
    | Some t -> fields @ [ "completed_at", `Float t ]
    | None -> fields
  in
  let fields =
    match e.status with
    | Done { ok; body } -> fields @ [ "ok", `Bool ok; "body", `String body ]
    | Lost { reason } -> fields @ [ "reason", `String reason ]
    | Cancelled { reason; cancelled_by } ->
      fields @ [ "reason", `String reason; "cancelled_by", `String cancelled_by ]
    | Queued | Running -> fields
  in
  `Assoc fields
;;

let string_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let float_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let bool_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Bool value) -> Some value
  | _ -> None
;;

let entry_of_record_json ~base_path json : (entry, string) result =
  match
    ( string_member "request_id" json
    , string_member "keeper_name" json
    , string_member "status" json
    , float_member "submitted_at" json )
  with
  | Some request_id, Some keeper_name, Some status, Some submitted_at ->
    let completed_at = float_member "completed_at" json in
    let status =
      match status with
      | "queued" -> Ok Queued
      | "running" -> Ok Running
      | "lost" ->
        Ok
          (Lost
             { reason =
                 string_member "reason" json
                 |> Option.value
                      ~default:"keeper_msg request was lost before terminal result"
             })
      | "cancelled" ->
        Ok
          (Cancelled
             { reason =
                 (* DET-OK: persisted cancelled records may predate reason;
                    the explicit "cancelled" status tag already determined
                    control flow, this fallback is display-only. *)
                 string_member "reason" json
                 |> Option.value ~default:"keeper_msg request was cancelled"
             ; cancelled_by =
                 (* DET-OK: display-only audit attribution fallback for
                    legacy/corrupt cancelled records. *)
                 string_member "cancelled_by" json |> Option.value ~default:"unknown"
             })
      | "done" | "error" ->
        let ok =
          bool_member "ok" json |> Option.value ~default:(String.equal status "done")
        in
        let body =
          string_member "body" json
          |> Option.value ~default:{|{"error":"result body missing"}|}
        in
        Ok (Done { ok; body })
      | other -> Error (Printf.sprintf "unknown status %S in record" other)
    in
    Result.map
      (fun status ->
         { request_id; keeper_name; base_path; status; submitted_at; completed_at })
      status
  | _ ->
    Error
      "record is missing required fields (request_id/keeper_name/status/submitted_at)"
;;

let persist_entry (entry : entry) =
  match record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> ()
  | Some path ->
    (match Keeper_fs.save_json_atomic path (entry_record_to_json entry) with
     | Ok () -> ()
     | Error err ->
       Log.Keeper.warn
         "keeper_msg_async: persist failed request_id=%s path=%s error=%s"
         entry.request_id
         path
         err)
;;

let load_record ~base_path ~request_id : load_result =
  match record_path ~base_path ~request_id with
  | None -> Absent
  | Some path ->
    if not (Fs_compat.file_exists path)
    then Absent
    else (
      let decoded =
        try
          Fs_compat.load_file path
          |> Yojson.Safe.from_string
          |> entry_of_record_json ~base_path
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error (Printexc.to_string exn)
      in
      match decoded with
      | Ok entry -> Found entry
      | Error reason ->
        Log.Keeper.warn
          "keeper_msg_async: load failed request_id=%s path=%s error=%s"
          request_id
          path
          reason;
        Unreadable reason)
;;

let has_suffix ~suffix value =
  let value_len = String.length value in
  let suffix_len = String.length suffix in
  value_len >= suffix_len
  && String.equal (String.sub value (value_len - suffix_len) suffix_len) suffix
;;

let request_id_of_record_filename name =
  let suffix = ".json" in
  if has_suffix ~suffix name
  then Some (String.sub name 0 (String.length name - String.length suffix))
  else None
;;

let should_gc_disk_record ~now (entry : entry) =
  match entry.status with
  | Done _ | Lost _ | Cancelled _ -> now -. entry.submitted_at > max_age_sec
  | Queued | Running -> false
;;

let remove_record_file path =
  try
    Sys.remove path;
    true
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper_msg_async: gc remove failed path=%s error=%s"
      path
      (Printexc.to_string exn);
    false
;;

let gc_stale_disk ~base_path =
  let dir = request_dir ~base_path in
  let now = Unix.gettimeofday () in
  try
    if (not (Sys.file_exists dir)) || not (Sys.is_directory dir)
    then 0
    else
      Sys.readdir dir
      |> Array.fold_left
           (fun removed name ->
              match request_id_of_record_filename name with
              | None -> removed
              | Some request_id ->
                let path = Filename.concat dir name in
                if Sys.is_directory path
                then removed
                else (
                  match load_record ~base_path ~request_id with
                  | Found entry when should_gc_disk_record ~now entry ->
                    if remove_record_file path then removed + 1 else removed
                  (* Unreadable records are kept so pollers can still observe
                     that the request was accepted but its result is lost. *)
                  | Found _ | Absent | Unreadable _ -> removed))
           0
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper_msg_async: gc scan failed base_path=%s dir=%s error=%s"
      base_path
      dir
      (Printexc.to_string exn);
    0
;;

let mark_lost_after_recovery (entry : entry) =
  let reason =
    "keeper_msg request was accepted but no live worker owns it; the server may have \
     restarted or evicted the request before terminal result"
  in
  let lost =
    { entry with status = Lost { reason }; completed_at = Some (Unix.gettimeofday ()) }
  in
  persist_entry lost;
  lost
;;

let generate_request_id ~keeper_name =
  let n = Atomic.fetch_and_add counter 1 in
  let safe_keeper_name =
    Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name
  in
  Printf.sprintf
    "kmsg_%s_%d_%d"
    safe_keeper_name
    n
    (int_of_float (Unix.gettimeofday () *. 1000.0))
;;

let with_lock f = Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())

let gc_stale () =
  let now = Unix.gettimeofday () in
  with_lock (fun () ->
    Hashtbl.fold
      (fun id entry acc ->
         match entry.status with
         | (Done _ | Lost _ | Cancelled _) when now -. entry.submitted_at > max_age_sec -> id :: acc
         | Queued | Running | Done _ | Lost _ | Cancelled _ -> acc)
      pending
      []
    |> List.iter (fun id -> Hashtbl.remove pending id))
;;

let is_terminal_status = function
  | Done _ | Lost _ | Cancelled _ -> true
  | Queued | Running -> false
;;

let set_status ?(preserve_terminal = false) request_id status =
  let to_persist =
    with_lock (fun () ->
      match Hashtbl.find_opt pending request_id with
      | Some entry when preserve_terminal && is_terminal_status entry.status -> None
      | Some entry ->
        let completed_at =
          match status with
          | Done _ | Lost _ | Cancelled _ ->
            (* NDT-OK: completed_at is observational wall-clock metadata for
               terminal request records; state transitions are status-derived. *)
            Some (Unix.gettimeofday ())
          | _ -> None
        in
        let updated = { entry with status; completed_at } in
        Hashtbl.replace pending request_id updated;
        Some updated
      | None -> None)
  in
  Option.iter persist_entry to_persist
;;

let set_status_protected ?preserve_terminal request_id status =
  Eio.Cancel.protect (fun () -> set_status ?preserve_terminal request_id status)
;;

let clear_active_switch request_id =
  with_lock (fun () -> Hashtbl.remove active_switches request_id)
;;

let cancelled_status ~cancelled_by reason =
  Cancelled { reason; cancelled_by }
;;

let operator_cancelled_status () =
  cancelled_status
    ~cancelled_by:"operator"
    "keeper_msg request was cancelled by operator"
;;

let runtime_cancelled_status () =
  cancelled_status
    ~cancelled_by:"runtime"
    "keeper_msg worker was cancelled by runtime before terminal result"
;;

let timeout_done_status ~request_id ~keeper_name ~timeout_sec =
  Done
    { ok = false
    ; body =
        Yojson.Safe.to_string
          (`Assoc
              [ "error", `String "keeper_msg_timeout"
              ; "message", `String "keeper_msg request exceeded timeout_sec"
              ; "request_id", `String request_id
              ; "keeper_name", `String keeper_name
              ; "timeout_sec", `Float timeout_sec
              ])
    }
;;

let submit ?clock ?timeout_sec ~sw ~base_path ~(f : unit -> tool_result)
    ~keeper_name () : string =
  gc_stale ();
  ignore (gc_stale_disk ~base_path);
  let request_id = generate_request_id ~keeper_name in
  let entry =
    { request_id
    ; keeper_name
    ; base_path
    ; status = Queued
    ; submitted_at = Unix.gettimeofday ()
    ; completed_at = None
    }
  in
  with_lock (fun () -> Hashtbl.replace pending request_id entry);
  persist_entry entry;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    set_status_protected ~preserve_terminal:true request_id Running;
    let run_worker_with_timeout () =
      match clock, timeout_sec with
      | Some clock, Some timeout_sec ->
        (try Eio.Time.with_timeout_exn clock timeout_sec f with
         | Eio.Time.Timeout ->
           let status = timeout_done_status ~request_id ~keeper_name ~timeout_sec in
           set_status_protected ~preserve_terminal:true request_id status;
           raise (Worker_timeout timeout_sec))
      | None, _ | _, None -> f ()
    in
    let result =
      try
        Eio.Switch.run (fun req_sw ->
          with_lock (fun () -> Hashtbl.replace active_switches request_id req_sw);
          let result = run_worker_with_timeout () in
          Done { ok = tool_result_success result; body = tool_result_body result })
      with
      | Worker_timeout timeout_sec ->
        timeout_done_status ~request_id ~keeper_name ~timeout_sec
      | CancelledByOperator -> operator_cancelled_status ()
      | Eio.Cancel.Cancelled _ as e ->
        set_status_protected ~preserve_terminal:true request_id (runtime_cancelled_status ());
        clear_active_switch request_id;
        raise e
      | exn ->
        Done
          { ok = false
          ; body = Printf.sprintf "keeper_msg failed: %s" (Printexc.to_string exn)
          }
    in
    set_status_protected ~preserve_terminal:true request_id result;
    clear_active_switch request_id;
    `Stop_daemon);
  request_id
;;

(** Poll for the result of an async keeper_msg request. *)
let poll ?base_path request_id : load_result =
  match Eio.Mutex.use_ro mu (fun () -> Hashtbl.find_opt pending request_id) with
  | Some entry -> Found entry
  | None ->
    (match base_path with
     | None -> Absent
     | Some base_path ->
       ignore (gc_stale_disk ~base_path);
       (match load_record ~base_path ~request_id with
        | Found ({ status = Queued | Running; _ } as entry) ->
          Found (mark_lost_after_recovery entry)
        | (Found _ | Absent | Unreadable _) as result -> result))
;;

(** List all pending/running requests for a keeper (or all keepers if omitted). *)
let list_for_keeper ?keeper_name () : entry list =
  Eio.Mutex.use_ro mu (fun () ->
    Hashtbl.fold
      (fun _id entry acc ->
         match keeper_name with
         | Some name when not (String.equal entry.keeper_name name) -> acc
         | _ -> entry :: acc)
      pending
      [])
  |> List.sort (fun a b -> compare b.submitted_at a.submitted_at)
;;

let entry_to_json (e : entry) : Yojson.Safe.t =
  let fields =
    [ "request_id", `String e.request_id
    ; "keeper_name", `String e.keeper_name
    ; "status", `String (status_to_string e.status)
    ; "submitted_at", `Float e.submitted_at
    ]
  in
  let fields =
    match e.completed_at with
    | Some t -> fields @ [ "completed_at", `Float t ]
    | None ->
      let elapsed = Unix.gettimeofday () -. e.submitted_at in
      fields @ [ "elapsed_sec", `Float elapsed ]
  in
  let fields =
    match e.status with
    | Done { ok; body } ->
      fields
      @ [ "ok", `Bool ok
        ; ( "result"
          , try Yojson.Safe.from_string body with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | Yojson.Json_error _ -> `String body )
        ]
    | Lost { reason } ->
      fields
      @ [ "ok", `Bool false
        ; "result", `Assoc [ "error", `String "request_lost"; "reason", `String reason ]
        ]
    | Cancelled { reason; cancelled_by } ->
      fields
      @ [ "ok", `Bool false
        ; ( "result"
          , `Assoc
              [ "cancelled", `Bool true
              ; "reason", `String reason
              ; "cancelled_by", `String cancelled_by
              ] )
        ]
    | _ -> fields
  in
  `Assoc fields
;;

let cancel ?base_path request_id : bool =
  let sw_opt =
    with_lock (fun () ->
      match Hashtbl.find_opt pending request_id, Hashtbl.find_opt active_switches request_id with
      | Some entry, Some sw when not (is_terminal_status entry.status) -> Some sw
      | _ -> None)
  in
  match sw_opt with
  | Some sw ->
    set_status_protected ~preserve_terminal:true request_id (operator_cancelled_status ());
    Eio.Switch.fail sw CancelledByOperator;
    with_lock (fun () -> Hashtbl.remove active_switches request_id);
    true
  | None ->
    match base_path with
    | None -> false
    | Some base_path ->
      match load_record ~base_path ~request_id with
      | Found ({ status = Queued | Running; _ } as entry) ->
        let cancelled_entry =
          (* NDT-OK: gettimeofday is acceptable for timestamping operator cancelled state *)
          { entry with
            status = operator_cancelled_status ()
          ; completed_at =
              (* NDT-OK: completed_at is audit metadata for a disk-only
                 operator cancellation fallback. *)
              Some (Unix.gettimeofday ())
          }
        in
        persist_entry cancelled_entry;
        true
      | Found _ | Absent | Unreadable _ -> false
;;

module For_testing = struct
  let is_safe_request_id = is_safe_request_id
  let forget request_id = with_lock (fun () -> Hashtbl.remove pending request_id)
  let clear () = with_lock (fun () -> Hashtbl.clear pending)
  let record_path = record_path
  let load_record = load_record
  let gc_stale_disk = gc_stale_disk
  let active_switch_count () =
    Eio.Mutex.use_ro mu (fun () -> Hashtbl.length active_switches)
  ;;
end
