(** Keeper_catchup_digest — see the .mli for the contract and design SSOT. *)

(* ── Named constants ─────────────────────────────────────────────── *)

let digest_items_cap = 20

(* Upper bound on the [read_errors] list so a corrupt store cannot fan the
   payload out without limit; the digest reports at most this many failures. *)
let read_errors_cap = 50

(* Retention SSOT is MASC_JSONL_RETENTION_DAYS (default 30d); look-back is
   clamped to this window plus slack so a far-past cursor cannot fan the
   day-file scan out unboundedly. Beyond it the counts are a lower bound and
   the echoed [since_unix] lets the client detect it. *)
let max_scan_days = 40

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

type task_item =
  { task_id : string
  ; transition : string
  ; ts : float
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

type t =
  { keeper : string
  ; since_unix : float
  ; generated_at_unix : float
  ; chat : chat
  ; turns : turns
  ; tasks : tasks
  ; board : board
  ; lifecycle : lifecycle
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

(* ── Fail-visible day-partitioned reader ─────────────────────────── *)

(* A parse or IO failure is appended to [errs] (fail-visible), never
   silently dropped. The list is bounded by {!read_errors_cap}. *)
let bounded_add errs msg = if List.length !errs < read_errors_cap then errs := msg :: !errs

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
   [[since_unix, now_unix]] (look-back clamped to {!max_scan_days}). A missing
   day-file is zero activity, not an error. Day indexing off [ts /. 86400] is
   month/year-boundary safe because 86400 divides UTC days exactly and the
   epoch is UTC midnight. *)
let fold_day_partitioned ~errs ~label ~dir ~since_unix ~now_unix ~f =
  let day_seconds = 86400. in
  let start_unix =
    Float.max since_unix (now_unix -. (float_of_int max_scan_days *. day_seconds))
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
  let start_day = day_index start_unix in
  let end_day = day_index now_unix in
  for d = start_day to end_day do
    let path = path_of_day d in
    if Sys.file_exists path then read_jsonl_file ~errs ~label ~path ~f
  done
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
let read_chat ~base_dir ~keeper_name ~since =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let new_messages = ref 0 in
  let transport = ref 0 in
  let first_new = ref None in
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
  let rec loop before iters =
    if iters >= chat_page_cap
    then ()
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
      | Some o when o > since && has_more -> loop (Some o) (iters + 1)
      | Some _ | None -> ())
  in
  loop None 0;
  { new_messages = !new_messages
  ; first_new_ts = !first_new
  ; transport_failures = !transport
  }
;;

(* ── Aggregation ─────────────────────────────────────────────────── *)

let build ~base_path ~keeper_name ~since_unix ~now_unix =
  let errs = ref [] in
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
  let chat = read_chat ~base_dir:base_path ~keeper_name ~since:since_unix in
  (* turns.completed — keeper-local turn-records *)
  let completed = ref 0 in
  fold_day_partitioned
    ~errs
    ~label:"turn-records"
    ~dir:(keeper_local Common.Keeper_turn_records)
    ~since_unix
    ~now_unix
    ~f:(fun json ->
      match json_num_field "ts" json with
      | Some ts when ts > since_unix -> incr completed
      | _ -> ());
  (* turns.crashes — Keeper_crash_persistence exposes the crash-events reader,
     so use it rather than re-spelling that store's path. *)
  let crashes = ref 0 in
  Keeper_crash_persistence.recent_crashes
    ~keepers_dir
    ~name:keeper_name
    ~max_entries:crash_scan_max
  |> List.iter (fun json ->
    match json_num_field "ts" json with
    | Some ts when ts > since_unix -> incr crashes
    | _ -> ());
  (* turns.failed + board — one pass over activity-events *)
  let failed = ref 0 in
  let posted = ref 0 in
  let commented = ref 0 in
  let voted = ref 0 in
  let since_ms = since_unix *. 1000. in
  fold_day_partitioned
    ~errs
    ~label:"activity-events"
    ~dir:(Filename.concat masc_dir activity_events_dirname)
    ~since_unix
    ~now_unix
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
          then incr voted);
  (* tasks — Audit_log owns the .masc/audit schema; parse each row through its
     typed decoder so the transition class comes from the [action] variant,
     not a local string classifier. *)
  let claimed = ref 0 in
  let done_ = ref 0 in
  let released = ref 0 in
  let cancelled = ref 0 in
  let task_items = ref [] in
  fold_day_partitioned
    ~errs
    ~label:"audit"
    ~dir:(Filename.concat masc_dir audit_dirname)
    ~since_unix
    ~now_unix
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
          let task_id =
            Option.value ~default:"" (Safe_ops.json_string_opt "task_id" details)
          in
          let record transition =
            task_items := { task_id; transition; ts = timestamp } :: !task_items
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
          | Audit_log.GovernanceDecision _
          | Audit_log.RuntimeConfigWrite
          | Audit_log.Custom _
          | Audit_log.Unknown _ -> ()));
  (* lifecycle — durable transition-audit operator_pause/operator_resume +
     current paused state from meta. The durable store survives a keeper
     restart, which the in-memory ring (the recent_transitions API) does not,
     and restart-straddling is the digest's whole premise. *)
  let pause_events = ref 0 in
  let resume_events = ref 0 in
  let life_items = ref [] in
  fold_day_partitioned
    ~errs
    ~label:"transition-audit"
    ~dir:(Filename.concat masc_dir transition_audit_dirname)
    ~since_unix
    ~now_unix
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
      | _ -> ());
  let paused_now =
    let meta_path = Filename.concat keepers_dir (keeper_name ^ ".json") in
    match Keeper_meta_store.read_meta_file_path meta_path with
    | Ok (Some m) -> m.Keeper_meta_contract.paused
    | Ok None -> false
    | Error e ->
      bounded_add errs (Printf.sprintf "keeper-meta: %s: %s" meta_path e);
      false
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
      ; items = cap_task_items !task_items
      }
  ; board = { posted = !posted; commented = !commented; voted = !voted }
  ; lifecycle =
      { paused_now
      ; pause_events = !pause_events
      ; resume_events = !resume_events
      ; items = cap_lifecycle_items !life_items
      }
  ; read_errors = List.rev !errs
  }
;;

(* ── Wire encoding ───────────────────────────────────────────────── *)

let float_opt_to_json = function
  | Some f -> `Float f
  | None -> `Null
;;

let task_item_to_json (i : task_item) =
  `Assoc
    [ "task_id", `String i.task_id
    ; "transition", `String i.transition
    ; "ts", `Float i.ts
    ]
;;

let lifecycle_item_to_json (i : lifecycle_item) =
  `Assoc [ "kind", `String i.kind; "ts", `Float i.ts ]
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
    ; "read_errors", `List (List.map (fun s -> `String s) t.read_errors)
    ]
;;
