(** Keeper_catchup_digest — see the .mli for the contract and design SSOT. *)

(* ── Named constants ─────────────────────────────────────────────── *)

let digest_items_cap = 20

(* Upper bound on the [read_errors] list so a corrupt store cannot fan the
   payload out without limit; the digest reports at most this many failures. *)
let read_errors_cap = 50

let jsonl_retention_env = "MASC_JSONL_RETENTION_DAYS"
let default_jsonl_retention_days = 30

(* Retention SSOT is MASC_JSONL_RETENTION_DAYS, read the same way as startup
   and periodic pruning. The digest still uses the default when pruning is
   disabled with a non-positive value; otherwise an old cursor could trigger
   an unbounded synchronous scan from a dashboard read. *)
let jsonl_retention_scan_days () =
  let days =
    Safe_ops.get_env_int_logged
      jsonl_retention_env
      ~default:default_jsonl_retention_days
  in
  if days > 0 then days else default_jsonl_retention_days
;;

(* Termination guard for the backward chat paging loop: each page walks at
   most one [Keeper_chat_store] window older, so this bounds the walk. *)
let chat_page_cap = 200

(* Newest crash events scanned before the [ts > since] filter; crashes are
   rare, so this is a generous ceiling rather than a since-scan. *)
let crash_scan_max = 500

(* Workspace-level dated-JSONL store directory names. Each store is owned by
   another module that spells this same literal internally but exposes no
   constant; naming them here keeps the digest's reads off bare literals and
   records the owner so a rename is a grep away. *)
let audit_dirname = "audit" (* Audit_log store *)
let activity_events_dirname = "activity-events" (* Activity_graph store *)
let transition_audit_dirname = "transition-audit" (* Keeper_transition_audit durable store *)
let tasks_dirname = "tasks" (* Workspace_utils_paths_backend.tasks_dir *)
let backlog_filename = "backlog.json" (* Workspace_utils_paths_backend.backlog_path basename *)

(* keeper.* activity-event kinds are still raw strings pending the #8455
   Event_kind migration; the board.* kinds below come from the typed
   Event_kind.Board SSOT. *)
let keeper_turn_failed_kind = "keeper.turn_failed"

(* Operator pause/resume [event_type] labels as serialised by
   Keeper_state_machine_json.event_to_json ([obj "operator_pause"] /
   [obj "operator_resume"]) and surfaced flat as a transition record's
   ["event_type"] field. *)
let operator_pause_event = "operator_pause"
let operator_resume_event = "operator_resume"

(* ── Types (mirror the .mli) ─────────────────────────────────────── *)

type task_snapshot =
  { title : string
  ; status : string
  ; assignee : string option
  ; phase : string option
  ; verifier : string option
  ; submitted_at : string option
  ; verification_id : string option
  ; handoff_summary : string option
  ; handoff_next_step : string option
  ; handoff_evidence_refs : string list
  }

type task_item =
  { task_id : string
  ; transition : string
  ; ts : float
  ; current_task : task_snapshot option
  }

type lifecycle_item =
  { kind : string
  ; ts : float
  }

type chat =
  { new_messages : int
  ; first_new_ts : float option
  ; transport_failures : int
  }

type turns =
  { completed : int
  ; failed : int
  ; crashes : int
  }

type tasks =
  { claimed : int
  ; done_ : int
  ; released : int
  ; cancelled : int
  ; items : task_item list
  }

type board =
  { posted : int
  ; commented : int
  ; voted : int
  }

type lifecycle =
  { paused_now : bool
  ; pause_events : int
  ; resume_events : int
  ; items : lifecycle_item list
  }

type truncation_cause =
  | Chat_page_cap
  | Chat_retention_window
  | Jsonl_retention_window
  | Crash_scan_cap

type source_coverage =
  { lower_bound : bool
  ; causes : truncation_cause list
  }

type coverage =
  { chat : source_coverage
  ; turns : source_coverage
  ; tasks : source_coverage
  ; board : source_coverage
  ; lifecycle : source_coverage
  }

type t =
  { keeper : string
  ; since_unix : float
  ; generated_at_unix : float
  ; chat : chat
  ; turns : turns
  ; tasks : tasks
  ; board : board
  ; lifecycle : lifecycle
  ; coverage : coverage
  ; read_errors : string list
  }

(* ── Small helpers ───────────────────────────────────────────────── *)

let take n xs =
  let rec go i = function
    | [] -> []
    | x :: tl -> if i >= n then [] else x :: go (i + 1) tl
  in
  go 0 xs
;;

(* [ts]-carrying items, newest first, capped at {!digest_items_cap}. *)
let cap_task_items items =
  items
  |> List.sort (fun (a : task_item) (b : task_item) -> Float.compare b.ts a.ts)
  |> take digest_items_cap
;;

let cap_lifecycle_items items =
  items
  |> List.sort (fun (a : lifecycle_item) (b : lifecycle_item) ->
    Float.compare b.ts a.ts)
  |> take digest_items_cap
;;

(* A JSON number field read as a float, accepting both [`Int] and [`Float]
   so mixed ISO/unix stores whose stamps are integral still resolve. *)
let json_num_field name json =
  match Safe_ops.json_member_opt name json with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None
;;

let string_opt_to_json = function
  | Some s -> `String s
  | None -> `Null
;;

(* ── Fail-visible day-partitioned reader ─────────────────────────── *)

(* A parse or IO failure is appended to [errs] (fail-visible), never
   silently dropped. The list is bounded by {!read_errors_cap}. *)
let bounded_add errs msg = if List.length !errs < read_errors_cap then errs := msg :: !errs

let non_empty_string_opt value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let non_empty_opt = function
  | Some value -> non_empty_string_opt value
  | None -> None
;;

let task_status_snapshot_fields (status : Masc_domain.task_status) =
  match status with
  | Masc_domain.Todo -> None, None, None, None, None
  | Masc_domain.Claimed { assignee; _ }
  | Masc_domain.InProgress { assignee; _ } ->
    Some assignee, None, None, None, None
  | Masc_domain.AwaitingVerification { assignee; submitted_at; verification_id; phase } ->
    let phase, verifier =
      match phase with
      | Masc_domain.Awaiting_verifier -> Some "awaiting_verifier", None
      | Masc_domain.Verifier_assigned { verifier } -> Some "verifier_assigned", Some verifier
    in
    Some assignee, phase, verifier, Some submitted_at, Some verification_id
  | Masc_domain.Done { assignee; _ } -> Some assignee, None, None, None, None
  | Masc_domain.Cancelled { cancelled_by; _ } -> Some cancelled_by, None, None, None, None
;;

let task_snapshot_of_task (task : Masc_domain.task) =
  let assignee, phase, verifier, submitted_at, verification_id =
    task_status_snapshot_fields task.task_status
  in
  let handoff_summary, handoff_next_step, handoff_evidence_refs =
    match task.handoff_context with
    | None -> None, None, []
    | Some ({ summary; next_step; evidence_refs; _ } : Masc_domain.task_handoff_context) ->
      non_empty_string_opt summary, non_empty_opt next_step, evidence_refs
  in
  { title = task.title
  ; status = Masc_domain.task_status_to_string task.task_status
  ; assignee
  ; phase
  ; verifier
  ; submitted_at
  ; verification_id
  ; handoff_summary
  ; handoff_next_step
  ; handoff_evidence_refs
  }
;;

let read_task_snapshot_index ~errs ~masc_dir =
  let table : (string, task_snapshot) Hashtbl.t = Hashtbl.create 64 in
  let backlog_path =
    Filename.concat (Filename.concat masc_dir tasks_dirname) backlog_filename
  in
  if Sys.file_exists backlog_path
  then (
    match Safe_ops.read_json_file_safe backlog_path with
    | Error msg ->
      bounded_add errs (Printf.sprintf "backlog: %s: %s" backlog_path msg)
    | Ok json ->
      (match Masc_domain.backlog_of_yojson json with
       | Error msg ->
         bounded_add errs (Printf.sprintf "backlog: %s: %s" backlog_path msg)
       | Ok backlog ->
         List.iter
           (fun (task : Masc_domain.task) ->
             Hashtbl.replace table task.id (task_snapshot_of_task task))
           backlog.tasks));
  table
;;

let attach_current_task task_snapshot_by_id (item : task_item) =
  { item with current_task = Hashtbl.find_opt task_snapshot_by_id item.task_id }
;;

let task_id_of_audit_details ~errs details =
  match Safe_ops.json_string_opt "task_id" details with
  | None ->
    bounded_add errs "audit: task transition missing task_id";
    None
  | Some raw ->
    (match Validation.Task_id.validate raw with
     | Ok task_id -> Some (Validation.Task_id.to_string task_id)
     | Error reason ->
       bounded_add errs (Printf.sprintf "audit: invalid task_id: %s" reason);
       None)
;;

let read_jsonl_file ~errs ~label ~path ~f =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error detail ->
    bounded_add errs (Printf.sprintf "%s: %s: %s" label path detail)
  | contents ->
    let lineno = ref 0 in
    String.split_on_char '\n' contents
    |> List.iter (fun line ->
      incr lineno;
      let trimmed = String.trim line in
      if trimmed <> ""
      then (
        (* Parse under its own guard so a bad line is a visible read error,
           while an exception raised by [f] itself is not misattributed. *)
        let parsed =
          try Some (Yojson.Safe.from_string trimmed) with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> None
        in
        match parsed with
        | Some json -> f json
        | None ->
          bounded_add
            errs
            (Printf.sprintf "%s: %s:%d unparseable JSON line" label path !lineno)))
;;

(* Iterate day-partitioned files [dir/YYYY-MM/DD.jsonl] whose UTC day is in
   [[since_unix, now_unix]] (look-back clamped to [scan_days]). A missing
   day-file is zero activity, not an error. Day indexing off [ts /. 86400] is
   month/year-boundary safe because 86400 divides UTC days exactly and the
   epoch is UTC midnight. *)
let fold_day_partitioned ~errs ~label ~dir ~since_unix ~now_unix ~scan_days ~f =
  let day_seconds = 86400. in
  let clamped_since =
    Float.max since_unix (now_unix -. (float_of_int scan_days *. day_seconds))
  in
  let day_index ts = int_of_float (Float.floor (ts /. day_seconds)) in
  let path_of_day d =
    let ts = (float_of_int d *. day_seconds) +. 1. in
    let tm = Unix.gmtime ts in
    Filename.concat
      dir
      (Printf.sprintf
         "%04d-%02d/%02d.jsonl"
         (tm.Unix.tm_year + 1900)
         (tm.Unix.tm_mon + 1)
         tm.Unix.tm_mday)
  in
  let start_day = day_index clamped_since in
  let end_day = day_index now_unix in
  for d = start_day to end_day do
    let path = path_of_day d in
    if Sys.file_exists path then read_jsonl_file ~errs ~label ~path ~f
  done;
  clamped_since > since_unix
;;

(* ── Chat (single per-keeper append-ordered file) ────────────────── *)

let payload_identity_match ~identity_of payload =
  List.exists
    (fun key ->
      match Safe_ops.json_string_opt key payload with
      | Some s -> identity_of s
      | None -> false)
    [ "keeper_name"; "agent_name"; "name" ]
;;

(* Page [Keeper_chat_store] backward from the tail, counting rows strictly
   after [since]. Utterances (user/assistant) are [new_messages];
   [Transport_failure] rows are counted separately; tool rows are ignored.
   The store's own parser owns chat read-drop accounting, so chat parse
   failures do not enter [read_errors]. Rows are de-duped by their stable
   [id] across page overlaps. *)
let read_chat ~base_dir ~keeper_name ~since ~errs =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let new_messages = ref 0 in
  let transport = ref 0 in
  let first_new = ref None in
  let truncated = ref false in
  let note_first ts =
    first_new
      := Some (match !first_new with Some f -> Float.min f ts | None -> ts)
  in
  let process ({ ts; id; kind; role; _ } : Keeper_chat_store.chat_message) =
    match ts with
    | Some ts when ts > since && not (Hashtbl.mem seen id) ->
      Hashtbl.add seen id ();
      (match kind with
       | Keeper_chat_store.Row_kind.Transport_failure -> incr transport
       | Keeper_chat_store.Row_kind.Utterance ->
         (match role with
          | Keeper_chat_store.Role.User | Keeper_chat_store.Role.Assistant ->
            incr new_messages;
            note_first ts
          | Keeper_chat_store.Role.Tool -> ()))
    | Some _ | None -> ()
  in
  let mark_truncated () =
    if not !truncated
    then (
      truncated := true;
      bounded_add
        errs
        "keeper-chat: page cap reached before since_unix; chat counts are lower bounds")
  in
  let rec loop before iters =
    if iters >= chat_page_cap
    then mark_truncated ()
    else (
      let { Keeper_chat_store.messages; has_more } =
        Keeper_chat_store.load_page ~base_dir ~keeper_name ?before ()
      in
      List.iter process messages;
      let oldest =
        List.fold_left
          (fun acc ({ ts; _ } : Keeper_chat_store.chat_message) ->
            match ts with
            | Some t -> Some (match acc with Some a -> Float.min a t | None -> t)
            | None -> acc)
          None
          messages
      in
      match oldest with
      | Some o when o > since && iters + 1 >= chat_page_cap -> mark_truncated ()
      | Some o when o > since && has_more -> loop (Some o) (iters + 1)
      | Some _ | None -> ())
  in
  loop None 0;
  ( { new_messages = !new_messages
    ; first_new_ts = !first_new
    ; transport_failures = !transport
    }
  , !truncated )
;;

(* ── Aggregation ─────────────────────────────────────────────────── *)

let build ~base_path ~keeper_name ~since_unix ~now_unix =
  let errs = ref [] in
  let scan_days = jsonl_retention_scan_days () in
  let retention_start = now_unix -. (float_of_int scan_days *. Masc_time_constants.day) in
  let identity_of candidate =
    Tool_agent_timeline.identity_matches ~agent_name:keeper_name candidate
  in
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  let keeper_local store =
    Filename.concat
      (Filename.concat keepers_dir keeper_name)
      (Common.keeper_runtime_store_dirname store)
  in
  (* chat *)
  let chat, chat_truncated =
    read_chat ~base_dir:base_path ~keeper_name ~since:since_unix ~errs
  in
  let chat_retention_truncated = since_unix < retention_start in
  (* turns.completed — keeper-local turn-records *)
  let completed = ref 0 in
  let turns_day_truncated =
    fold_day_partitioned
      ~errs
      ~label:"turn-records"
      ~dir:(keeper_local Common.Keeper_turn_records)
      ~since_unix
      ~now_unix
      ~scan_days
      ~f:(fun json ->
        match json_num_field "ts" json with
        | Some ts when ts > since_unix -> incr completed
        | _ -> ())
  in
  (* turns.crashes — Keeper_crash_persistence exposes the crash-events reader,
     so use it rather than re-spelling that store's path. *)
  let crashes = ref 0 in
  let crash_entries =
    Keeper_crash_persistence.recent_crashes
      ~keepers_dir
      ~name:keeper_name
      ~max_entries:crash_scan_max
  in
  let crash_truncated = List.length crash_entries >= crash_scan_max in
  List.iter
    (fun json ->
      match json_num_field "ts" json with
      | Some ts when ts > since_unix -> incr crashes
      | _ -> ())
    crash_entries;
  (* turns.failed + board — one pass over activity-events *)
  let failed = ref 0 in
  let posted = ref 0 in
  let commented = ref 0 in
  let voted = ref 0 in
  let since_ms = since_unix *. 1000. in
  let activity_truncated =
    fold_day_partitioned
      ~errs
      ~label:"activity-events"
      ~dir:(Filename.concat masc_dir activity_events_dirname)
      ~since_unix
      ~now_unix
      ~scan_days
      ~f:(fun json ->
        match Activity_graph.event_of_yojson json with
        | None -> ()
        | Some ({ kind; ts_ms; actor; payload; _ } : Activity_graph.event) ->
          let actor_match =
            match actor with
            | Some ({ id; _ } : Activity_graph.entity_ref) -> identity_of id
            | None -> false
          in
          if float_of_int ts_ms > since_ms
             && (actor_match || payload_identity_match ~identity_of payload)
          then
            if String.equal kind keeper_turn_failed_kind
            then incr failed
            else if String.equal kind Event_kind.Board.(to_string Posted)
            then incr posted
            else if String.equal kind Event_kind.Board.(to_string Commented)
            then incr commented
            else if String.equal kind Event_kind.Board.(to_string Voted)
            then incr voted)
  in
  (* tasks — Audit_log owns the .masc/audit schema; parse each row through its
     typed decoder so the transition class comes from the [action] variant,
     not a local string classifier. *)
  let claimed = ref 0 in
  let done_ = ref 0 in
  let released = ref 0 in
  let cancelled = ref 0 in
  let task_items = ref [] in
  let audit_truncated =
    fold_day_partitioned
      ~errs
      ~label:"audit"
      ~dir:(Filename.concat masc_dir audit_dirname)
      ~since_unix
      ~now_unix
      ~scan_days
      ~f:(fun json ->
        match Audit_log.entry_of_json_r json with
        | Error _ ->
          (* Valid JSON that is not an audit entry (e.g. a foreign row); the
             true parse-failure path is handled inside [read_jsonl_file]. *)
          ()
        | Ok ({ timestamp; agent_id; action; details; _ } : Audit_log.audit_entry)
          ->
          if timestamp > since_unix && identity_of agent_id
          then (
            let record transition =
              match task_id_of_audit_details ~errs details with
              | Some task_id ->
                task_items
                  := { task_id; transition; ts = timestamp; current_task = None }
                     :: !task_items
              | None -> ()
            in
            match action with
            | Audit_log.ClaimTask ->
              incr claimed;
              record "claim"
            | Audit_log.DoneTask ->
              incr done_;
              record "done"
            | Audit_log.ReleaseTask ->
              incr released;
              record "release"
            | Audit_log.CancelTask ->
              incr cancelled;
              record "cancel"
            | Audit_log.StartTask -> record "start"
            (* Non-task audit actions are not task transitions. Enumerated (no
               catch-all) so a new task-relevant action fails compile here. *)
            | Audit_log.Broadcast
            | Audit_log.Suspend
            | Audit_log.ToolCall _
            | Audit_log.AuthSuccess
            | Audit_log.AuthFailure
            | Audit_log.CircuitOpen
            | Audit_log.CircuitClose
            | Audit_log.SearchRefinement
            | Audit_log.GateDecision _
            | Audit_log.RuntimeConfigWrite
            | Audit_log.Custom _
            | Audit_log.Unknown _ -> ()))
  in
  (* lifecycle — durable transition-audit operator_pause/operator_resume +
     current paused state from meta. The durable store survives a keeper
     restart, which the in-memory ring (the recent_transitions API) does not,
     and restart-straddling is the digest's whole premise. *)
  let pause_events = ref 0 in
  let resume_events = ref 0 in
  let life_items = ref [] in
  let transition_truncated =
    fold_day_partitioned
      ~errs
      ~label:"transition-audit"
      ~dir:(Filename.concat masc_dir transition_audit_dirname)
      ~since_unix
      ~now_unix
      ~scan_days
      ~f:(fun json ->
        match
          Safe_ops.json_string_opt "keeper" json, Safe_ops.json_member_opt "record" json
        with
        | Some k, Some record when identity_of k ->
          (match
             Safe_ops.json_string_opt "event_type" record
           , json_num_field "wall_clock_at_decision" record
           with
           | Some event_type, Some ts when ts > since_unix ->
             if String.equal event_type operator_pause_event
             then (
               incr pause_events;
               life_items := { kind = event_type; ts } :: !life_items)
             else if String.equal event_type operator_resume_event
             then (
               incr resume_events;
               life_items := { kind = event_type; ts } :: !life_items)
           | _ -> ())
        | _ -> ())
  in
  let paused_now =
    let meta_path = Filename.concat keepers_dir (keeper_name ^ ".json") in
    match Keeper_meta_store.read_meta_file_path meta_path with
    | Ok (Some m) -> m.Keeper_meta_contract.paused
    | Ok None -> false
    | Error e ->
      bounded_add errs (Printf.sprintf "keeper-meta: %s: %s" meta_path e);
      false
  in
  let task_snapshot_by_id = read_task_snapshot_index ~errs ~masc_dir in
  let task_items_with_current =
    !task_items |> List.map (attach_current_task task_snapshot_by_id)
  in
  let coverage =
    let source causes = { lower_bound = causes <> []; causes } in
    { chat =
        source
          ((if chat_truncated then [ Chat_page_cap ] else [])
           @ if chat_retention_truncated then [ Chat_retention_window ] else [])
    ; turns =
        source
          ((if turns_day_truncated then [ Jsonl_retention_window ] else [])
           @ if crash_truncated then [ Crash_scan_cap ] else [])
    ; tasks =
        source (if audit_truncated then [ Jsonl_retention_window ] else [])
    ; board =
        source (if activity_truncated then [ Jsonl_retention_window ] else [])
    ; lifecycle =
        source (if transition_truncated then [ Jsonl_retention_window ] else [])
    }
  in
  { keeper = keeper_name
  ; since_unix
  ; generated_at_unix = now_unix
  ; chat
  ; turns = { completed = !completed; failed = !failed; crashes = !crashes }
  ; tasks =
      { claimed = !claimed
      ; done_ = !done_
      ; released = !released
      ; cancelled = !cancelled
      ; items = cap_task_items task_items_with_current
      }
  ; board = { posted = !posted; commented = !commented; voted = !voted }
  ; lifecycle =
      { paused_now
      ; pause_events = !pause_events
      ; resume_events = !resume_events
      ; items = cap_lifecycle_items !life_items
      }
  ; coverage
  ; read_errors = List.rev !errs
  }
;;

(* ── Wire encoding ───────────────────────────────────────────────── *)

let float_opt_to_json = function
  | Some f -> `Float f
  | None -> `Null
;;

let task_snapshot_to_json (s : task_snapshot) =
  `Assoc
    [ "title", `String s.title
    ; "status", `String s.status
    ; "assignee", string_opt_to_json s.assignee
    ; "phase", string_opt_to_json s.phase
    ; "verifier", string_opt_to_json s.verifier
    ; "submitted_at", string_opt_to_json s.submitted_at
    ; "verification_id", string_opt_to_json s.verification_id
    ; "handoff_summary", string_opt_to_json s.handoff_summary
    ; "handoff_next_step", string_opt_to_json s.handoff_next_step
    ; "handoff_evidence_refs", `List (List.map (fun ref_ -> `String ref_) s.handoff_evidence_refs)
    ]
;;

let task_item_to_json (i : task_item) =
  `Assoc
    [ "task_id", `String i.task_id
    ; "transition", `String i.transition
    ; "ts", `Float i.ts
    ; ( "current_task"
      , match i.current_task with
        | Some current_task -> task_snapshot_to_json current_task
        | None -> `Null )
    ]
;;

let lifecycle_item_to_json (i : lifecycle_item) =
  `Assoc [ "kind", `String i.kind; "ts", `Float i.ts ]
;;

let truncation_cause_to_wire = function
  | Chat_page_cap -> "chat_page_cap"
  | Chat_retention_window -> "chat_retention_window"
  | Jsonl_retention_window -> "jsonl_retention_window"
  | Crash_scan_cap -> "crash_scan_cap"
;;

let source_coverage_to_json (c : source_coverage) : Yojson.Safe.t =
  `Assoc
    [ "lower_bound", `Bool c.lower_bound
    ; "causes", `List (List.map (fun c -> `String (truncation_cause_to_wire c)) c.causes)
    ]
;;

let coverage_to_json (c : coverage) : Yojson.Safe.t =
  `Assoc
    [ "chat", source_coverage_to_json c.chat
    ; "turns", source_coverage_to_json c.turns
    ; "tasks", source_coverage_to_json c.tasks
    ; "board", source_coverage_to_json c.board
    ; "lifecycle", source_coverage_to_json c.lifecycle
    ]
;;

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [ "keeper", `String t.keeper
    ; "since_unix", `Float t.since_unix
    ; "generated_at_unix", `Float t.generated_at_unix
    ; ( "chat"
      , `Assoc
          [ "new_messages", `Int t.chat.new_messages
          ; "first_new_ts", float_opt_to_json t.chat.first_new_ts
          ; "transport_failures", `Int t.chat.transport_failures
          ] )
    ; ( "turns"
      , `Assoc
          [ "completed", `Int t.turns.completed
          ; "failed", `Int t.turns.failed
          ; "crashes", `Int t.turns.crashes
          ] )
    ; ( "tasks"
      , `Assoc
          [ "claimed", `Int t.tasks.claimed
          ; "done", `Int t.tasks.done_
          ; "released", `Int t.tasks.released
          ; "cancelled", `Int t.tasks.cancelled
          ; "items", `List (List.map task_item_to_json t.tasks.items)
          ] )
    ; ( "board"
      , `Assoc
          [ "posted", `Int t.board.posted
          ; "commented", `Int t.board.commented
          ; "voted", `Int t.board.voted
          ] )
    ; ( "lifecycle"
      , `Assoc
          [ "paused_now", `Bool t.lifecycle.paused_now
          ; "pause_events", `Int t.lifecycle.pause_events
          ; "resume_events", `Int t.lifecycle.resume_events
          ; "items", `List (List.map lifecycle_item_to_json t.lifecycle.items)
          ] )
    ; "coverage", coverage_to_json t.coverage
    ; "read_errors", `List (List.map (fun s -> `String s) t.read_errors)
    ]
;;
