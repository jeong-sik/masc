(* Goal store — shared planning goals with a dedicated lifecycle phase.
   [phase] is the only persisted lifecycle representation.

   RFC-0444: the store is read through one closed sum, [source]. A store this
   build cannot read is [Unavailable], carrying the reason, the state of the
   .last-good mirror and the operator's next step; it never reads as an empty
   state. The only empty state is [Uninitialized]: neither goals.json nor its
   mirror exists. 2026-09-08 (#34459) 97 goals read as 0 for 7h29m because
   the reader folded a decode failure into a default state (B1). *)

include Goal_document

open Result.Syntax

type transition_effects = {
  events : (event_kind * Yojson.Safe.t) list;
  notifications : (string * string) list;
}

type rollup = {
  active_count : int;
  verifying_count : int;
  awaiting_confirmation_count : int;
  done_count : int;
  dropped_count : int;
  paused_count : int;
  blocked_count : int;
}
[@@deriving yojson]

let goals_filename = "goals.json"

let goals_path config =
  Filename.concat (Workspace_utils.masc_dir config) goals_filename

let goals_recovery_path config =
  goals_path config ^ Common.recovery_mirror_suffix

let goal_events_filename = "goal_events.jsonl"

let goal_events_path config =
  Filename.concat (Workspace_utils.masc_dir config) goal_events_filename

let ensure_dirs config =
  Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

(* The one empty state this module constructs. Its only call is the first
   write on an [Uninitialized] store (RFC-0444 §2.2, criterion 2); no reader
   builds it. *)
let default_state : unit -> state = fun () ->
  { version = 1; updated_at = Masc_domain.now_iso (); goals = []; pending_events = []; pending_notifications = [] }

(* {1 Source (RFC-0444 §2.1)} *)

type source =
  | Uninitialized
  | Available of state
  | Unavailable of unavailable

(* The value itself is defined in masc_types ([Goal_store_unavailable]) so
   the task-creation contract below this library can carry it; the manifest
   re-export keeps every constructor addressable as [Goal_store.X]. *)
and unavailable = Goal_store_unavailable.t =
  { file : string
  ; reason : reason
  ; mirror : mirror_status
  ; reset_step : reset_step
  }

and nonregular_kind = Goal_store_unavailable.nonregular_kind =
  | Nonregular_directory
  | Nonregular_character_device
  | Nonregular_block_device
  | Nonregular_symbolic_link
  | Nonregular_fifo
  | Nonregular_socket

and reason = Goal_store_unavailable.reason =
  | Missing_after_init
  | Unreadable of Unix.error
  | Nonregular of nonregular_kind
  | Not_json of string
  | Schema_rejected of { field : string; detail : string }

and mirror_status = Goal_store_unavailable.mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
  | Mirror_nonregular of nonregular_kind
  | Mirror_decodes of { goal_count : int; updated_at : string }
  | Mirror_rejected of reason

and reset_step = Goal_store_unavailable.reset_step =
  | Repair_field of string
  | Reset_goal_store
  | Restore_permission
  | Inspect_path

type lookup =
  | Goal_found of goal
  | Goal_absent
  | Store_unavailable of unavailable

(* An I/O failure is not evidence that resetting the store is appropriate. *)
let reset_step_of_reason = function
  | Schema_rejected { field; _ } -> Repair_field field
  | Unreadable error -> if error = Unix.EACCES then Restore_permission else Inspect_path
  | Nonregular _ -> Inspect_path
  | Missing_after_init -> Reset_goal_store
  | Not_json _ -> Reset_goal_store

let unavailable_to_string = Goal_store_unavailable.to_string

(* {2 Reading a file with its errno}

   The shared read chain ([Workspace_utils.read_json_doc] →
   [Safe_ops.read_file_result] → [Fs_compat.load_file]) renders every read
   failure to a sentence, so [Unreadable of Unix.error] cannot come out of it.
   The store opens the file itself. The read is inline on the calling
   fiber: goals.json holds the current set only (97 rows ≈ 40 KB on
   2026-09-08), well under the reads that measured on the main domain
   (RFC main-domain-scheduler-latency §8.8). *)

type file_read =
  | File_absent
  | File_unreadable of Unix.error
  | File_nonregular of nonregular_kind
  | File_bytes of string

let read_chunk_bytes = 65536

let rec missing_parent_result path : file_read =
  match Unix.lstat path with
  | stat ->
      if stat.Unix.st_kind = Unix.S_LNK then
        (match Unix.stat path with
         | target -> if target.Unix.st_kind = Unix.S_DIR then File_absent else File_unreadable Unix.ENOTDIR
         | exception Unix.Unix_error (error, _, _) -> File_unreadable error)
      else if stat.Unix.st_kind = Unix.S_DIR then File_absent
      else File_unreadable Unix.ENOTDIR
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      let parent = Filename.dirname path in
      if String.equal parent path then File_unreadable Unix.ENOENT
      else missing_parent_result parent
  | exception Unix.Unix_error (error, _, _) -> File_unreadable error

let read_path_error path error : file_read =
  if error = Unix.ENOENT then
      (* A dangling symlink is an existing entry, not an uninitialized store.
         A concurrent creation between the failed lookup and lstat is also
         not safe to classify as absent. *)
      (match Unix.lstat path with
       | _ -> File_unreadable Unix.ENOENT
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> missing_parent_result (Filename.dirname path)
       | exception Unix.Unix_error (error, _, _) -> File_unreadable error)
  else File_unreadable error

let unsupported_kind = function
  | Unix.S_REG -> None
  | Unix.S_DIR -> Some Nonregular_directory
  | Unix.S_CHR -> Some Nonregular_character_device
  | Unix.S_BLK -> Some Nonregular_block_device
  | Unix.S_LNK -> Some Nonregular_symbolic_link
  | Unix.S_FIFO -> Some Nonregular_fifo
  | Unix.S_SOCK -> Some Nonregular_socket

let read_file path : file_read =
  (* Follow links to regular files as before. Check the opened descriptor as
     well, since the path can change after [stat]. [O_NONBLOCK] prevents a
     replacement FIFO from waiting for a writer during [open], but that open
     can still wake a FIFO writer. It does not make opening an arbitrary
     device safe if the path changes to one. *)
  match Unix.stat path with
  | exception Unix.Unix_error (error, _, _) -> read_path_error path error
  | stat ->
      (match unsupported_kind stat.Unix.st_kind with
       | Some kind -> File_nonregular kind
       | None ->
           match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
           | exception Unix.Unix_error (error, _, _) -> read_path_error path error
           | fd ->
               Fun.protect
                 ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
                 (fun () ->
                   match Unix.fstat fd with
                   | exception Unix.Unix_error (error, _, _) -> File_unreadable error
                   | opened ->
                       match unsupported_kind opened.Unix.st_kind with
                       | Some kind -> File_nonregular kind
                       | None ->
                           let buffer = Buffer.create read_chunk_bytes in
                           let chunk = Bytes.create read_chunk_bytes in
                           let rec drain () =
                             match Unix.read fd chunk 0 read_chunk_bytes with
                             | 0 -> File_bytes (Buffer.contents buffer)
                             | count ->
                                 Buffer.add_subbytes buffer chunk 0 count;
                                 drain ()
                             | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
                             | exception Unix.Unix_error (error, _, _) -> File_unreadable error
                           in
                           drain ()))

let decode_bytes bytes : (state, reason) result =
  match Yojson.Safe.from_string bytes with
  | exception Yojson.Json_error detail -> Error (Not_json detail)
  | json ->
      (match state_of_yojson json with
       | Ok state -> Ok state
       | Error { field; detail } -> Error (Schema_rejected { field; detail }))

module Goal_id_map = Map.Make (String)

type prepared_state = {
  state : state;
  goals_by_id : goal Goal_id_map.t;
  sorted_goals : goal list;
}

let sort_goals goals =
  (* Sort key is [(priority asc, updated_at desc)]. *)
  List.sort
    (fun left right ->
      let by_priority = Int.compare left.priority right.priority in
      if by_priority <> 0 then
        by_priority
      else
        String.compare right.updated_at left.updated_at)
    goals

let prepare_state (state : state) : prepared_state =
  let goals_by_id =
    List.fold_left
      (fun acc (goal : goal) ->
        (* Preserve first-row precedence so [Goal_id_map.find_opt] agrees with
           [find_goal_in] when [state.goals] contains duplicate goal IDs. *)
        Goal_id_map.update
          goal.id
          (function
            | Some existing -> Some existing
            | None -> Some goal)
          acc)
      Goal_id_map.empty
      state.goals
  in
  { state; goals_by_id; sorted_goals = sort_goals state.goals }

(* Content-addressed prepared cache — the byte-equality and locking mechanics
   live in [Mirrored_store_cache.Content_cache], shared with the verification
   store. This instance skips repeated JSON parsing, decoding, sorting, and
   [Goal_id_map] construction when [goals.json] is unchanged. *)
let goals_cache : prepared_state Mirrored_store_cache.Content_cache.t =
  Mirrored_store_cache.Content_cache.create ()

let clear_goals_cache_for path =
  Mirrored_store_cache.Content_cache.clear goals_cache path

let decode_prepared_bytes ~path bytes : (prepared_state, reason) result =
  Mirrored_store_cache.Content_cache.memo goals_cache ~path ~bytes
    ~decode:decode_bytes ~prepare:prepare_state

(* The mirror is evidence of how far the primary drifted, never state: a
   mirror that decodes is reported with its size and stamp and is not served
   (RFC-0444 §5, "보여주되 서빙하지 않는다"). *)
let mirror_status_of_read = function
  | File_absent -> Mirror_absent
  | File_unreadable error -> Mirror_unreadable error
  | File_nonregular kind -> Mirror_nonregular kind
  | File_bytes bytes ->
      (match decode_bytes bytes with
       | Ok state ->
           Mirror_decodes
             { goal_count = List.length state.goals; updated_at = state.updated_at }
       | Error reason -> Mirror_rejected reason)

let make_unavailable config ~reason ~mirror =
  let reset_step = match mirror with
    | Mirror_unreadable _ | Mirror_nonregular _ -> Inspect_path
    | Mirror_absent | Mirror_decodes _ | Mirror_rejected _ -> reset_step_of_reason reason in
  { file = goals_path config; reason; mirror; reset_step }

let load_prepared_source config =
  let path = goals_path config in
  let read_mirror () = mirror_status_of_read (read_file (goals_recovery_path config)) in
  match read_file path with
  | File_absent ->
      clear_goals_cache_for path;
      (match read_mirror () with
       | Mirror_absent -> `Uninitialized
       | (Mirror_unreadable _ | Mirror_nonregular _ | Mirror_decodes _ | Mirror_rejected _) as mirror ->
           `Unavailable (make_unavailable config ~reason:Missing_after_init ~mirror))
  | File_unreadable error ->
      clear_goals_cache_for path;
      `Unavailable (make_unavailable config ~reason:(Unreadable error) ~mirror:(read_mirror ()))
  | File_nonregular kind ->
      clear_goals_cache_for path;
      `Unavailable (make_unavailable config ~reason:(Nonregular kind) ~mirror:(read_mirror ()))
  | File_bytes bytes ->
      (match decode_prepared_bytes ~path bytes with
       | Ok prepared -> `Available prepared
       | Error reason ->
           clear_goals_cache_for path;
           `Unavailable (make_unavailable config ~reason ~mirror:(read_mirror ())))

(* Only opens and reads: no directory creation, rename, write, delete or log
   line. A primary that decodes is [Available] without the mirror being
   opened at all. *)
let load_source config : source =
  match load_prepared_source config with
  | `Uninitialized -> Uninitialized
  | `Unavailable u -> Unavailable u
  | `Available prepared -> Available prepared.state

let find_goal config ~goal_id : lookup =
  match load_prepared_source config with
  | `Uninitialized -> Goal_absent
  | `Unavailable u -> Store_unavailable u
  | `Available prepared ->
      (match Goal_id_map.find_opt goal_id prepared.goals_by_id with
       | Some goal -> Goal_found goal
       | None -> Goal_absent)

(* {1 Writing} *)

(* The local JSON writer publishes by rename, which replaces a final symlink
   rather than updating its target. Preserve an observed mirror link. *)
let refuse_symlink_replacement path =
  match Unix.lstat path with
  | stat ->
      if stat.Unix.st_kind = Unix.S_LNK then
        Error (Printf.sprintf "refusing to replace symbolic link: %s" path)
      else Ok ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (error, _, _) ->
      Error (Printf.sprintf "cannot inspect %s: %s" path (Unix.error_message error))

type projection_effect = Projection_changed | Projection_unchanged

let notify_projection_change config =
  try
    (Atomic.get Workspace_hooks.on_goal_projection_mutation_fn)
      ~base_path:config.Workspace_utils.base_path
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Log.Misc.error "goal_store: projection observer failed for %s: %s"
        config.base_path (Printexc.to_string exn)

let projection_source_changed config =
  Goal_projection_generation.advance ();
  notify_projection_change config

let write_state_with_effect ~projection_effect config state =
  ensure_dirs config;
  let path = goals_path config in
  clear_goals_cache_for path;
  let json = state_to_yojson state in
  (* [load_source] reads the local primary for every workspace backend. Publish
     to that same authority through the shared encoder and atomic writer. *)
  let* () = Workspace_utils.write_json_local path json in
  Goal_projection_generation.advance ();
  (match projection_effect with
   | Projection_changed -> notify_projection_change config
   | Projection_unchanged -> ());
  (match
     let mirror = goals_recovery_path config in
     let* () = refuse_symlink_replacement mirror in
     Workspace_utils.write_json_local mirror json
   with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "goal_store: primary goals.json committed; recovery mirror write failed for %s: %s"
       (goals_recovery_path config)
       msg);
  Ok ()

let write_state_result config state =
  write_state_with_effect ~projection_effect:Projection_changed config state

let write_state config state =
  match write_state_result config state with
  | Ok () -> ()
  | Error msg ->
    Log.Misc.warn "goal_store.write_state failed for %s: %s"
      (goals_path config)
      msg

let now_ms () =
  int_of_float (Time_compat.now () *. 1000.0)

(* The suffix separates goals minted in the same millisecond, so it is not
   derived from a clock value: two clock hashes taken that close are nearly the
   same. [Random_id] is the entropy source the rest of the tree uses; take 4
   bytes from it. *)
let gen_goal_id () =
  Printf.sprintf "goal-%d-%s" (now_ms ()) (Random_id.hex ~bytes:4)

let replace_goal goals updated =
  List.map (fun goal -> if String.equal goal.id updated.id then updated else goal) goals

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Ambiguous_goal of string
  | Store_unavailable of unavailable
  | Persistence_failed of string

let delete_goal_error_to_string = function
  | Unknown_goal msg -> msg
  | Ambiguous_goal goal_id -> "goal ID has multiple rows: " ^ goal_id
  | Store_unavailable u -> unavailable_to_string u
  | Persistence_failed msg -> "goal persistence failed: " ^ msg

type goal_reference_error =
  | Goal_source_unavailable of unavailable
  | Goal_lock_failed of Masc_domain.masc_error
  | Goal_missing of string

(* Defined after [lookup] and [delete_goal_error] on purpose: a bare
   [Store_unavailable] resolves to this type, and the two functions that
   build the other two annotate their result. *)
type write_error =
  | Store_unavailable of unavailable
  | Goal_not_found of string
  | Goal_identity_ambiguous of string
  | Rejected of string
  | Persist_failed of string

let write_error_to_string = function
  | Store_unavailable u -> unavailable_to_string u
  | Goal_not_found goal_id -> "goal not found: " ^ goal_id
  | Goal_identity_ambiguous goal_id -> "goal ID has multiple rows: " ^ goal_id
  | Rejected detail -> detail
  | Persist_failed detail -> "goal persistence failed: " ^ detail

type goal_row_match = No_goal_row | One_goal_row of goal | Multiple_goal_rows

(* Callers use this classification after the document decoder has rejected
   duplicate JSON members, to detect multiple decoded rows with one ID. *)
let classify_goal_rows goals goal_id =
  match List.filter (fun (goal : goal) -> String.equal goal.id goal_id) goals with
  | [] -> No_goal_row
  | [goal] -> One_goal_row goal
  | _ :: _ :: _ -> Multiple_goal_rows

(* The caller must hold the Goal lock. *)
let unique_goal_in goals goal_id =
  match classify_goal_rows goals goal_id with
  | No_goal_row -> Ok None
  | One_goal_row goal -> Ok (Some goal)
  | Multiple_goal_rows -> Error (Goal_identity_ambiguous goal_id)

(* Goal membership and the dependent commit share the Goal lock. Callbacks
   may acquire backlog then link locks, never re-enter the Goal store. *)
let with_existing_goals config ~goal_ids f =
  match goal_ids with
  | [] -> Ok (f ())
  | first_id :: _ ->
    (match Workspace_utils.with_file_lock_r config (goals_path config) (fun () ->
      match load_prepared_source config with
      | `Unavailable u -> Error (Goal_source_unavailable u)
      | `Uninitialized -> Error (Goal_missing first_id)
      | `Available prepared ->
        match List.find_opt
          (fun id -> not (Goal_id_map.mem id prepared.goals_by_id))
          goal_ids with
        | Some id -> Error (Goal_missing id)
        | None -> Ok (f ())) with
     | Ok result -> result
     | Error error -> Error (Goal_lock_failed error))

type assignable_goal_error =
  | Assignment_source_unavailable of unavailable
  | Assignment_lock_failed of Masc_domain.masc_error
  | Assignment_goal_missing of string
  | Assignment_goal_ambiguous of string
  | Assignment_goal_closed of { goal_id : string; phase : Goal_phase.t }

(* Assignment and Task creation must recheck every row under the same lock
   held through the link write. A map lookup loses duplicate rows and misses
   whitespace aliases. *)
let with_assignable_goals config ~goal_ids f =
  match goal_ids with
  | [] -> Ok (f ())
  | first_id :: _ ->
    (match Workspace_utils.with_file_lock_r config (goals_path config) (fun () ->
      match load_prepared_source config with
      | `Unavailable u -> Error (Assignment_source_unavailable u)
      | `Uninitialized -> Error (Assignment_goal_missing first_id)
      | `Available prepared ->
        let rec first_rejection = function
          | [] -> None
          | goal_id :: remaining ->
            (match List.filter (fun (goal : goal) ->
              String.equal (String.trim goal.id) goal_id) prepared.state.goals with
             | [] -> Some (Assignment_goal_missing goal_id)
             | [goal] when String.equal goal.id goal_id ->
               (match goal.phase with
                | Goal_phase.Completed | Goal_phase.Dropped ->
                  Some (Assignment_goal_closed { goal_id; phase = goal.phase })
                | Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Awaiting_confirmation
                | Goal_phase.Paused _ | Goal_phase.Blocked _ -> first_rejection remaining)
             | [_] | _ :: _ :: _ -> Some (Assignment_goal_ambiguous goal_id))
        in
        (match first_rejection goal_ids with
         | Some error -> Error error
         | None -> Ok (f ()))) with
     | Ok result -> result
     | Error error -> Error (Assignment_lock_failed error))

let with_assignable_goal config ~goal_id f =
  with_assignable_goals config ~goal_ids:[goal_id] f

type 'a state_commit = {
  next_state : state;
  value : 'a;
}

(* Rejection leaves an uninitialized store without a file. An accepted plan
   always commits, including upserts that preserve every editable field. *)
let commit_state config prepare =
  Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      let current : (state, write_error) result =
        match load_source config with
        | Unavailable u -> Error (Store_unavailable u)
        (* The first write creates the store; nothing writes an empty state
           ahead of it (RFC-0444 §2.2). *)
        | Uninitialized -> Ok (default_state ())
        | Available state -> Ok state
      in
      let* state = current in
      let* { next_state; value } = prepare state in
      match write_state_result config next_state with
      | Ok () -> Ok value
      | Error detail -> Error (Persist_failed detail))

let transact_goal ?effects config ~goal_id f =
  Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      let loaded : (goal * state, write_error) result =
        match load_source config with
        | Unavailable u -> Error (Store_unavailable u)
        | Uninitialized -> Error (Goal_not_found goal_id)
        | Available state ->
          (match unique_goal_in state.goals goal_id with
           | Error error -> Error error
           | Ok None -> Error (Goal_not_found goal_id)
           | Ok (Some goal) -> Ok (goal, state))
      in
      let* current, state = loaded in
      match f current with
      | Error detail -> Error (Rejected detail)
      | Ok (updated, result) ->
        if not (String.equal updated.id current.id) then
          Error (Rejected "goal transaction cannot replace goal identity")
        else if updated = current then Ok (current, result)
        else
          let now = Masc_domain.now_iso () in
          let updated = { updated with updated_at = now } in
          let revision = state.version + 1 in
          let effects = match effects with None -> {events=[]; notifications=[]}
            | Some make -> make updated result in
          let events = List.map (fun (kind, payload) ->
            {event_id=Random_id.hex ~bytes:16; goal_id; store_revision=revision;
             recorded_at=now; kind; payload}) effects.events in
          let notices = List.map (fun (sender, content) ->
            {notification_id=Workspace_request_id.(create () |> to_string);
             goal_id; sender; content; delivery=Awaiting_recipients}) effects.notifications in
          let next =
            { version = revision
            ; updated_at = now
            ; goals = replace_goal state.goals updated
            ; pending_events = state.pending_events @ events
            ; pending_notifications = state.pending_notifications @ notices
            } in
          (match write_state_result config next with
           | Ok () -> Ok (updated, result)
           | Error detail -> Error (Persist_failed detail)))

let delete_goal config ~goal_id : (delete_goal_outcome, delete_goal_error) result =
  Workspace_utils.with_file_lock config (goals_path config)
    (fun () : (delete_goal_outcome, delete_goal_error) result ->
      let deleted : (unit, delete_goal_error) result =
        match load_source config with
        | Unavailable u -> Error (Store_unavailable u)
        | Uninitialized -> Error (Unknown_goal "Goal not found")
        | Available state ->
          (match classify_goal_rows state.goals goal_id with
          | No_goal_row -> Error (Unknown_goal "Goal not found")
          | Multiple_goal_rows -> Error (Ambiguous_goal goal_id)
          | One_goal_row _ ->
            match
              write_state_result
                config
                { state with version = state.version + 1
                ; goals =
                    List.filter
                      (fun goal -> not (String.equal goal.id goal_id))
                      state.goals
                ; updated_at = Masc_domain.now_iso ()
                }
            with
            | Ok () -> Ok ()
            | Error msg -> Error (Persistence_failed msg))
      in
      match deleted with
      | Error _ as error -> error
      | Ok () ->
        (* Keep membership removal and link cleanup in the same Goal lock.
           Persistence remains two stores; a cleanup failure is reported explicitly. *)
        (match Workspace_goal_index.prune_links_for_goal_result config ~goal_id with
         | Ok () -> Ok Deleted
         | Error detail ->
           Log.Misc.warn
             "goal_store.delete_goal: goal %s removed but goal_task_links prune failed: %s"
             goal_id
             detail;
           let warning =
             Printf.sprintf
               "goal deleted but failed to prune goal_task_links for %s: %s"
               goal_id
               detail
           in
           Ok (Deleted_with_orphaned_links warning)))

let list_goals_result config ?phase ?kind () : (goal list, unavailable) result =
  match load_prepared_source config with
  | `Unavailable u -> Error u
  | `Uninitialized -> Ok []
  | `Available prepared ->
      let filtered =
        match phase with
        | None -> prepared.sorted_goals
        | Some phase ->
            List.filter (fun (goal : goal) -> goal.phase = phase) prepared.sorted_goals
      in
      let filtered =
        match kind with
        | None -> filtered
        | Some kind ->
            List.filter
              (fun (goal : goal) -> Goal_phase.kind goal.phase = kind)
              filtered
      in
      Ok filtered

let load_goals_by_id_result config : (goal Goal_id_map.t, unavailable) result =
  match load_prepared_source config with
  | `Unavailable u -> Error u
  | `Uninitialized -> Ok Goal_id_map.empty
  | `Available prepared -> Ok prepared.goals_by_id

let blank_opt = function
  | None -> true
  | Some raw -> String.trim raw = ""

(* A due date is refused where it is written, so an unreadable one never
   reaches the store. Reading it back is {!Goal_due}'s job. *)
let due_date_refusal = function
  | None -> None
  | Some raw ->
    (match Goal_due.read (Some raw) with
     | Goal_due.Unreadable_due_date _ ->
       Some
         (Printf.sprintf
            "due_date must be a calendar date written YYYY-MM-DD (it falls due \
             at 23:59:59 UTC that day), got %S"
            raw)
     | Goal_due.No_due_date | Goal_due.Due_date _ -> None)

let upsert_event_intents ~actor ~revision (goal : goal) action =
  let actor_field = "actor", `String actor in
  let snapshot = match goal_to_yojson goal with
    | `Assoc fields -> `Assoc (actor_field :: ("store_version", `Int revision) :: fields)
    | _ -> assert false in
  let extras = match action with
    | `created -> []
    | `updated previous ->
        let phase = if previous.phase = goal.phase then [] else
          [ Phase, `Assoc [ actor_field; "phase", `String (Goal_phase.to_string goal.phase);
                           "resume_phase", Goal_phase.resume_phase_to_yojson goal.phase;
                           "previous_phase", `String (Goal_phase.to_string previous.phase);
                           "previous_resume_phase", Goal_phase.resume_phase_to_yojson previous.phase;
                           "cause", `String "criterion_edit" ] ] in
        let change name before after =
          name, `Assoc [ "from", before; "to", after ] in
        let due_date = if previous.due_date = goal.due_date then [] else
          [ change "due_date" (Json_util.string_opt_to_json previous.due_date)
              (Json_util.string_opt_to_json goal.due_date) ] in
        let priority = if previous.priority = goal.priority then [] else
          [ change "priority" (`Int previous.priority) (`Int goal.priority) ] in
        phase @ (match due_date @ priority with
          | [] -> [] | changes -> [ Edited, `Assoc (actor_field :: changes) ]) in
  ((match action with `created -> Created | `updated _ -> Updated), snapshot) :: extras
  |> List.map (fun (kind, payload) ->
       { event_id = Random_id.hex ~bytes:16; goal_id = goal.id;
         store_revision = revision; recorded_at = goal.updated_at; kind; payload })

(* All writers of this ledger use the same durable transaction, including
   writers already holding the Goal lock. This function never takes that lock
   or calls back into the Goal store. *)
let append_audit_event config json =
  Fun.protect ~finally:(fun () -> Goal_event_observation.attempted ~base_path:config.Workspace_utils.base_path)
    (fun () ->
  let path = goal_events_path config in
  try
    let expected = try (Unix.stat path).Unix.st_size with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> 0 in
    (* The transaction carries the new end offset on success and the append
       error on failure; the offset mismatch is a failure, the same reading
       world_constitution_store gives it. The append did not commit on a
       mismatch, so the retry cannot write the event twice. *)
    let rec append expected_end_offset =
      match Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result
          path ~expected_end_offset (Yojson.Safe.to_string json ^ "\n") with
      | Fs_compat.Private_file_failed (Fs_compat.End_offset_mismatch {actual;_})
      | Fs_compat.Private_file_failed_with_cleanup_failure
          { error = Fs_compat.End_offset_mismatch {actual;_}; _ } -> append actual
      | (Fs_compat.Private_file_failed (Fs_compat.Incomplete_jsonl_tail | (Fs_compat.Invalid_jsonl_suffix | Fs_compat.Existing_jsonl_refused _ | (Fs_compat.Incomplete_jsonl_tail_truncate_failed _ | (Fs_compat.Negative_expected_end_offset _ | Fs_compat.Durable_jsonl_append_failed _)))) | Fs_compat.Private_file_failed_with_cleanup_failure { error = (Fs_compat.Incomplete_jsonl_tail | (Fs_compat.Invalid_jsonl_suffix | Fs_compat.Existing_jsonl_refused _ | (Fs_compat.Incomplete_jsonl_tail_truncate_failed _ | (Fs_compat.Negative_expected_end_offset _ | Fs_compat.Durable_jsonl_append_failed _))));_} | Fs_compat.Private_file_succeeded _ | Fs_compat.Private_file_succeeded_with_cleanup_failure _) as outcome -> outcome in
    match append expected with
    | Fs_compat.Private_file_succeeded _ ->
        projection_source_changed config;
        Ok ()
    | Private_file_succeeded_with_cleanup_failure { cleanup_failure; _ } ->
        (* The durable effect committed; the cleanup failure is descriptor
           settlement, and reporting it as an append failure would invite a
           retry that writes the event twice. *)
        Log.Misc.warn "goal event transaction cleanup failed: %s"
          (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
        projection_source_changed config;
        Ok ()
    | Private_file_failed error ->
        Error (Fs_compat.private_jsonl_append_error_to_string error)
    | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
        Error (Fs_compat.private_jsonl_append_error_to_string error ^ "; "
               ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn))

(* The Goal lock orders the outbox against every mutation and acknowledgement.
   Delivery uses the existing durable JSONL transaction, never a caller callback.
   Its path mutex also serializes ordinary cached writers. Stable IDs make an
   append followed by an unsuccessful outbox acknowledgement safe to retry. *)
let flush_pending_events_locked config =
  try
      match load_source config with
      | Uninitialized -> Ok ()
      | Unavailable unavailable -> Error (unavailable_to_string unavailable)
      | Available { pending_events = []; _ } -> Ok ()
      | Available state ->
          let path = goal_events_path config in
          let append_attempted = ref false in
          let outcome = Fun.protect
            ~finally:(fun () ->
              if !append_attempted then
                Goal_event_observation.attempted ~base_path:config.Workspace_utils.base_path)
            (fun () -> Fs_compat.update_private_file_durable_locked_result path (fun existing ->
            let inspect () =
              if existing <> "" && not (String.ends_with ~suffix:"\n" existing) then
                Error "goal event ledger has an incomplete tail"
              else
                let rec decode acc malformed = function
                  | [] ->
                      if malformed > 0 then
                        Log.Misc.warn
                          "goal event ledger retained %d malformed complete rows during audit delivery"
                          malformed;
                      Ok (List.rev acc)
                  | "" :: rest -> decode acc malformed rest
                  | line :: rest ->
                      (match Yojson.Safe.from_string line with
                       | json -> decode (json :: acc) malformed rest
                       | exception Yojson.Json_error _ ->
                           (* Complete historical rows remain byte-for-byte in
                              the ledger; they cannot witness event identity.
                              The tail check above still rejects torn writes. *)
                           decode acc (malformed + 1) rest) in
                let* rows = decode [] 0 (String.split_on_char '\n' existing) in
                let rec select acc = function
                  | [] -> Ok (List.rev acc)
                  | event :: rest ->
                      let matching = List.filter (fun json ->
                        Json_util.get_string json "event_id" = Some event.event_id) rows in
                      let expected = pending_event_to_yojson event in
                      if List.exists (fun json -> not (Yojson.Safe.equal json expected)) matching then
                        Error ("goal event identity has different content: " ^ event.event_id)
                      else select (if matching = [] then event :: acc else acc) rest in
                select [] state.pending_events in
            match inspect () with
            | Error detail -> None, Error detail
            | Ok missing ->
                let suffix, changed = match missing with
                  | [] -> None, false
                  | events -> Some (String.concat "" (List.map (fun event ->
                      Yojson.Safe.to_string (pending_event_to_yojson event) ^ "\n") events)), true in
                (* The transaction may leave visible bytes after an uncertain
                   write. A read, empty outbox or duplicate suffix owes no hint. *)
                if changed then append_attempted := true;
                suffix, Ok changed)) in
          let appended = match outcome with
            | Fs_compat.Private_file_succeeded result -> result
            | Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
                Log.Misc.warn "goal event transaction cleanup failed: %s"
                  (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
                value
            | Private_file_failed error -> Error (Fs_compat.durable_append_error_to_string error)
            | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
                Error (Fs_compat.durable_append_error_to_string error ^ "; "
                       ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure) in
          let* changed = appended in
          if changed then projection_source_changed config;
          (match write_state_with_effect ~projection_effect:Projection_unchanged config
                   { state with pending_events = []; version = state.version + 1;
                     updated_at = Masc_domain.now_iso () } with
           | Ok () -> ()
           | Error detail ->
               Log.Misc.warn "goal events committed; outbox acknowledgement retained for retry: %s" detail);
          Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

let flush_pending_events config =
  try
    Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      flush_pending_events_locked config)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

let append_audit_event_after_pending_locked config json =
  let* () = flush_pending_events_locked config in
  append_audit_event config json

let append_audit_event_after_pending config json =
  try
    Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      append_audit_event_after_pending_locked config json)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

let goal_with_fields ~now ?title ?metric ?target_value ?due_date ?priority
    (existing : goal) =
  let updated =
    { existing with
      title = Option.value title ~default:existing.title;
      metric = (match metric with Some _ -> metric | None -> existing.metric);
      target_value =
        (match target_value with Some _ -> target_value | None -> existing.target_value);
      due_date = (match due_date with Some _ -> due_date | None -> existing.due_date);
      priority = clamp_priority (Option.value priority ~default:existing.priority);
      updated_at = now;
    }
  in
  let criterion_changed =
    not (String.equal existing.title updated.title)
    || not (Option.equal String.equal existing.metric updated.metric)
    || not (Option.equal String.equal existing.target_value updated.target_value)
  in
  updated, criterion_changed

let validate_changed_criterion (goal : goal) : (unit, write_error) result =
  if blank_opt (Some goal.title) || blank_opt goal.metric
     || blank_opt goal.target_value then
    Error (Rejected
      "a changed goal criterion requires non-blank title, metric and target_value; \
       omitted fields retain their stored values")
  else Ok ()

let goal_with_new_criterion ~criterion_revision (goal : goal) =
  { goal with criterion_revision; phase = Goal_phase.criterion_changed goal.phase;
    last_review_note = None; last_review_at = None }

let new_goal ~now ~id ~criterion_revision ~title ~metric ~target_value ~due_date
    ~priority : goal =
  { id; criterion_revision; title; metric; target_value; due_date;
    priority = clamp_priority (Option.value priority ~default:3);
    phase = Goal_phase.Executing;
    last_review_note = None; last_review_at = None;
    created_at = now; updated_at = now }

type goal_id_error = Goal_id_blank | Goal_id_padded of string

let goal_id_error_to_string = function
  | Goal_id_blank -> "goal id cannot be blank"
  | Goal_id_padded raw_id ->
    Printf.sprintf "goal id %S must not have leading or trailing whitespace" raw_id

let validate_goal_id raw_id =
  let trimmed = String.trim raw_id in
  if String.equal trimmed "" then Error Goal_id_blank
  else if not (String.equal trimmed raw_id) then
    Error (Goal_id_padded raw_id)
  else Ok ()

let resolve_goal_id = function
  | None -> Ok (gen_goal_id ())
  | Some raw_id ->
      let* () = Result.map_error (fun error -> Rejected (goal_id_error_to_string error))
          (validate_goal_id raw_id) in
      Ok raw_id

type upsert_precondition = Unconditional | Require_absent

let upsert_goal_with_events config ~actor ?id ?title ?metric ?target_value ?due_date
    ?priority ?(precondition = Unconditional) () =
  let is_new_goal = id = None in
  if is_new_goal && blank_opt title then
    Error (Rejected "title required for new goal")
  else
    let* resolved_id = resolve_goal_id id in
    match due_date_refusal due_date with
    | Some message -> Error (Rejected message)
    | None ->
        commit_state config (fun state ->
          let now = Masc_domain.now_iso () in
          let* () =
            match precondition with
            | Unconditional -> Ok ()
            | Require_absent ->
                if List.exists (fun (goal : goal) ->
                  String.equal (String.trim goal.id) resolved_id) state.goals
                then Error (Rejected "goal ID is already present")
                else Ok () in
          let* existing_goal = unique_goal_in state.goals resolved_id in
          let* goal, action =
            match existing_goal with
            | Some existing ->
                let updated, criterion_changed =
                  goal_with_fields ~now ?title ?metric ?target_value ?due_date
                    ?priority existing in
                let* () =
                  if criterion_changed then validate_changed_criterion updated
                  else Ok () in
                let updated =
                  if criterion_changed then
                    let criterion_revision = Random_id.hex ~bytes:16 in
                    goal_with_new_criterion ~criterion_revision updated
                  else updated in
                Ok (updated, `updated existing)
            | None ->
                (* Creation gates run after the authoritative read under the
                   write lock. Updates may be backdated and omit unchanged
                   condition fields; changed criteria are checked above. *)
                let* title =
                  match title with
                  | Some title when String.trim title <> "" -> Ok title
                  | None | Some _ ->
                      Error (Rejected
                        "a non-blank title is required for a new goal \
                         (a goal without a name states no success condition \
                         to hold it to)") in
                if blank_opt metric || blank_opt target_value then
                  Error (Rejected
                    "metric and target_value are required for a new goal \
                     (RFC-0387 B1: a goal must declare a measurable \
                     success condition)")
                else
                  let criterion_revision = Random_id.hex ~bytes:16 in
                  let goal = new_goal ~now ~id:resolved_id ~criterion_revision
                      ~title ~metric ~target_value ~due_date ~priority in
                  Ok (goal, `created)
          in
          let revision = state.version + 1 in
          let goals = match action with
            | `created -> state.goals @ [goal]
            | `updated _ -> replace_goal state.goals goal in
          let pending = upsert_event_intents ~actor ~revision goal action in
          Ok {
            next_state =
              { state with version = revision; updated_at = now; goals;
                pending_events = state.pending_events @ pending };
            value = goal, action, pending;
          })

let compute_rollup goals =
  let count predicate =
    List_util.count_if predicate goals
  in
  {
    active_count = count (fun goal -> goal.phase = Goal_phase.Executing);
    verifying_count = count (fun goal -> goal.phase = Goal_phase.Verifying);
    awaiting_confirmation_count = count (fun goal -> goal.phase = Goal_phase.Awaiting_confirmation);
    done_count = count (fun goal -> goal.phase = Goal_phase.Completed);
    dropped_count = count (fun goal -> goal.phase = Goal_phase.Dropped);
    paused_count = count (fun goal -> Goal_phase.kind goal.phase = Goal_phase.Kind.Paused);
    blocked_count = count (fun goal -> Goal_phase.kind goal.phase = Goal_phase.Kind.Blocked);
  }

let pending_notifications config = match load_source config with
  | Uninitialized -> Ok []
  | Unavailable unavailable -> Error (Store_unavailable unavailable)
  | Available state -> Ok state.pending_notifications

let update_notification config (expected : pending_notification) change =
  Workspace_utils.with_file_lock config (goals_path config) (fun () ->
    match load_source config with
    | Uninitialized -> Ok None
    | Unavailable unavailable -> Error (Store_unavailable unavailable)
    | Available state ->
        match List.find_opt (fun notice -> notice.notification_id = expected.notification_id)
            state.pending_notifications with
        | None -> Ok None
        | Some current ->
            if current.goal_id <> expected.goal_id || current.sender <> expected.sender
              || current.content <> expected.content then
              Error (Rejected "Goal notification identity has different content")
            else
              let* next = change current |> Result.map_error (fun detail -> Rejected detail) in
              if next = Some current then Ok next else
              let pending_notifications = List.filter_map (fun notice ->
                if notice.notification_id = expected.notification_id then next else Some notice)
                state.pending_notifications in
              let updated = {state with pending_notifications; version=state.version + 1;
                updated_at=Masc_domain.now_iso ()} in
              write_state_with_effect ~projection_effect:Projection_unchanged config updated
              |> Result.map_error (fun detail -> Persist_failed detail)
              |> Result.map (fun () -> next))

(* The host roster arrives as strings; each is parsed here once and the
   captured audience keeps the parsed names. *)
let snapshot_notification_recipients config notice ~recipients =
  let parsed = List.map Keeper_id.Keeper_name.of_string recipients in
  if List.exists Result.is_error parsed then
    Error (Rejected "invalid Goal notification recipient")
  else
    let names = List.filter_map Result.to_option parsed in
    update_notification config notice (fun current -> match current.delivery with
      | Pending_recipients _ -> Ok (Some current)
      | Awaiting_recipients ->
          Ok (Some {current with delivery=Pending_recipients (List.sort_uniq Keeper_id.Keeper_name.compare names)}))

let acknowledge_notification_recipient config notice ~recipient =
  let* () = match notice.delivery with
    | Pending_recipients names when List.exists (Keeper_id.Keeper_name.equal recipient) names -> Ok ()
    | Pending_recipients _ | Awaiting_recipients -> Error (Rejected "recipient is outside the captured Goal notification") in
  update_notification config notice (fun current -> match current.delivery with
    | Awaiting_recipients -> Error "Goal notification recipients have not been captured"
    | Pending_recipients remaining ->
        Ok (Some {current with delivery=Pending_recipients
          (List.filter (fun name -> not (Keeper_id.Keeper_name.equal name recipient)) remaining)}))
  |> Result.map (fun _ -> ())

let acknowledge_notification config notice =
  update_notification config notice (fun current -> match current.delivery with
    | Pending_recipients [] -> Ok None
    | Awaiting_recipients | Pending_recipients (_ :: _) -> Error "Goal notification recipients are still pending")
  |> Result.map (fun _ -> ())
