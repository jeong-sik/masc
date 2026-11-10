(* Helpers, context, add_task, batch_add, claim, claim_next, release —
   extracted to [Tool_task_handlers] (godfile decomp). *)

open Tool_args
include Tool_task_handlers

module Workspace = Workspace_core

let workflow_rejection_result
      ~tool_name
      ~start_time
      ?rule_id
      ?recoverable
      ?extra_fields
      message
  =
  let data =
    Workflow_rejection_payload.payload
      ?rule_id
      ?recoverable
      ?extra_fields
      message
  in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data
    (Yojson.Safe.to_string data)

let handle_transition ~tool_name ~start_time ctx args =
  (* Underscore-prefixed keys (e.g. "_agent_name") are internal protocol markers
     injected by the HTTP transport and dashboard client for identity
     propagation. They are consumed upstream in Client_identity and must not
     trigger the strict-schema "Unknown argument(s)" rejection here. *)
  let is_internal_marker k =
    String.length k > 0 && Char.equal k.[0] '_'
  in
  let unknown = match args with
    | `Assoc kvs ->
      List.filter
        (fun (k, _) ->
          (not (is_internal_marker k))
          && not (List.mem k transition_known_args))
        kvs
    | _ -> []
  in
  if Stdlib.List.length unknown > 0 then
    let names = String.concat ", " (List.map fst unknown) in
    (* RFC-0189: schema-rejection — operator passed an unknown
       argument name. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "Unknown argument(s): %s. Valid: %s"
        names (String.concat ", " transition_known_args))
  else
  match Workspace.validate_expected_workspace ~config:ctx.config args with
  | Error error ->
    let rule_id =
      match error with
      | Workspace.Invalid_workspace_precondition -> "task_invalid_workspace_precondition"
      | Workspace.Workspace_precondition_failed -> "task_workspace_precondition_failed"
    in
    workflow_rejection_result ~tool_name ~start_time ~rule_id
      (Workspace.expected_workspace_error_message error)
  | Ok args ->
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let action_raw = get_string args "action" "" in
  if String.equal action_raw "" then
    (* RFC-0189: required-field violation. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "action is required (%s)" (String.concat ", " Masc_domain.valid_task_action_strings))
  else
  match Masc_domain.task_action_of_string action_raw with
  | Error msg ->
      (* RFC-0189: caller passed an unknown action enum value. *)
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name ~start_time msg
  | Ok action ->
  let action_s = Masc_domain.task_action_to_string action in
  let notes = get_string args "notes" "" in
  let reason = get_string args "reason" "" in
  let handoff_context =
    parse_handoff_context ~agent_name:ctx.agent_name ~action args
  in
  let expected_version = get_int_opt args "expected_version" in
  Workspace.ensure_initialized ctx.config;
  match Workspace_backlog.read_prepared_backlog_r ctx.config with
  | Error msg ->
    let err = Masc_domain.System (Masc_domain.System_error.IoError msg) in
    log_task_transition_failed ~agent_name:ctx.agent_name err;
    result_to_response ~tool_name ~start_time (Error err)
  | Ok prepared ->
  (* The lifecycle decides under the backlog lock. [task_opt] supplies
     observation and metrics only. *)
  let task_opt =
    Workspace_backlog.Task_id_map.find_opt task_id prepared.tasks_by_id
  in
  match handoff_context with
  | Error error ->
      (* RFC-0189: handoff_context parse error — caller passed
         malformed payload. *)
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name ~start_time error
  | Ok handoff_context ->
  (* [now () -. 60.0] used to stand in whenever the status carried no usable
     start: Todo, Done, Cancelled, an unparseable timestamp, or no task at all.
     That number reaches [Metrics_store_eio] as [started_at] and the average is
     computed as [completed_at -. started_at], so every such task recorded a
     duration of exactly one minute — indistinguishable in the aggregate from a
     task that really took one. Absence is [None] and the metric is not
     recorded (#29355). *)
  let started_at_of value = Masc_domain.parse_iso8601_opt value in
  let collaborators_of assignee =
    if (not (String.equal assignee "")) && not (String.equal assignee ctx.agent_name)
    then [ assignee ]
    else []
  in
  let (started_at_actual, collaborators_from_task) = match task_opt with
    | Some t -> (match t.task_status with
        | Masc_domain.InProgress { started_at; assignee } ->
            (started_at_of started_at, collaborators_of assignee)
        | Masc_domain.Claimed { claimed_at; assignee } ->
            (started_at_of claimed_at, collaborators_of assignee)
        (* [started_at] is the producer's original work start, preserved across
           submission and rejection (see task_status). [submitted_at] is when
           verification began, so using it reported the wait, not the work. *)
        | Masc_domain.AwaitingVerification { started_at; assignee; _ } ->
            (started_at_of started_at, collaborators_of assignee)
        | Masc_domain.Todo
        | Masc_domain.Done _
        | Masc_domain.Cancelled _ -> (None, []))
    | None -> (None, [])
  in
  (* Bind the receipt to the request created by this transition, before its
     notification can race with a verdict or another submission. An ordinary
     diagnostic read failure does not reject submission; cancellation still
     propagates through the existing preparation/commit boundary. *)
  let submission_receipt = ref None in
  let prepare_verification_request ~task ~assignee ~verification_id ~claim =
    let open Result.Syntax in
    let* () = (Atomic.get Workspace_hooks.verification_submit_request_fn)
      ctx.config ~task ~assignee ~verification_id ~claim in
    let receipt = match Workspace_verification_store.submission_receipt
      ~base_path:ctx.config.base_path ~request_id:verification_id
      ~task_id ~worker:assignee with
      | Ok receipt -> receipt
      | Error reason -> `Assoc ["verification_id", `String verification_id;
          "diagnostics_unavailable", `String
            (Workspace_verification_store.evidence_access_failure_to_string
              ~request_id:verification_id reason)]
    in
    submission_receipt := Some receipt;
    Ok ()
  in
  let result =
    Workspace.transition_task_r
      ctx.config
      ~agent_name:ctx.agent_name
      ~task_id
      ~action
      ~prepare_verification_request
      ?expected_version
      ~notes
      ~reason
      ?handoff_context
      ()
  in
  (* A missing task leaves any binding that still points at it stale, so it
     is reconciled the same way a committed transition is. *)
  (match result with
   | Ok _ | Error (Masc_domain.Task (Masc_domain.Task_error.NotFound _)) ->
     sync_owner_current_task_binding ctx;
     sync_planning_current_task_with_owned_task ctx
   | Error
       ( Masc_domain.Task
           ( Masc_domain.Task_error.AlreadyClaimed _
           | Masc_domain.Task_error.InvalidState _
           | Masc_domain.Task_error.BacklogVersionConflict _
           | Masc_domain.Task_error.InvalidId _
           | Masc_domain.Task_error.TransitionRejected _
           | Masc_domain.Task_error.VerificationSuperseded _ )
       | Masc_domain.Agent _ | Masc_domain.Auth _ | Masc_domain.System _ ) -> ());
  (* Notify A2A subscribers on successful transition *)
  (match result with
   | Ok _ ->
        (* Notification harness: push task transition to all active sessions *)
       (Atomic.get Workspace_hooks.push_task_event_fn)
          ~event_type:"masc/task_transition"
          ~details:[
            ("task_id", `String task_id);
            ("action", `String action_s);
            ("agent_name", `String ctx.agent_name);
          ];
   | Error err ->
       log_task_transition_failed ~agent_name:ctx.agent_name err);
  (* Record metrics *)
  (* A metric with no real start cannot say how long the work took, and an
     invented one is worse than a missing row: it lands in the same average.
     The transition itself is already recorded elsewhere; this hook exists to
     measure duration. *)
  (match result, action, started_at_actual with
   | Ok _, Masc_domain.Cancel, Some started_at ->
       (Atomic.get Workspace_hooks.record_task_metric_fn)
         ctx.config
         ~agent_id:ctx.agent_name
         ~task_id
         ~started_at
         ~completed_at:(Some (Time_compat.now ()))
         ~terminal:Task_outcome_measurement.Cancelled
         ~error_message:
           (Some
              (* The same sentence the transition recorded: the caller may have
                 stated it in handoff_context.summary rather than in [reason]. *)
              (match Masc_domain.stated_reason ~reason:(Some reason) ~handoff_context with
               | Some reason -> reason
               | None -> "Cancelled"))
         ~collaborators:collaborators_from_task
         ~handoff_from:None
         ~handoff_to:None
  | Ok _, Masc_domain.Cancel, None
  | Ok _, (Masc_domain.Claim | Masc_domain.Start | Masc_domain.Submit_for_verification
            | Masc_domain.Release | Masc_domain.Done_action), _
  | Error _, _, _ -> ());
  let invalid_state_response message =
    workflow_rejection_result
      ~tool_name
      ~start_time
      ~rule_id:"task_transition_invalid_state"
      ~recoverable:false
      ~extra_fields:
        [ "task_id", `String task_id
        ; "action", `String action_s
        ; "requested_agent", `String ctx.agent_name
        ]
      (Printf.sprintf "Invalid task state: %s" message)
  in
  let transition_result_to_response = function
    | Error (Masc_domain.Task (Masc_domain.Task_error.TransitionRejected rejection)) ->
      let data = Tool_task_transition_rejection.payload rejection in
      Tool_result.make_err ~tool_name ~start_time
        ~class_:Tool_result.Workflow_rejection ~data (Yojson.Safe.to_string data)
    | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState message)) ->
      invalid_state_response message
    | Error (Masc_domain.Task (Masc_domain.Task_error.BacklogVersionConflict { expected; actual })) ->
      invalid_state_response
        (Printf.sprintf "Version mismatch (expected %d, got %d)" expected actual)
    | (Error (Masc_error.Task (Masc_error.Task_error.NotFound _ | (Masc_error.Task_error.AlreadyClaimed _ | (Masc_error.Task_error.InvalidId _ | Masc_error.Task_error.VerificationSuperseded _)))) | Error (Masc_error.Agent _ | (Masc_error.Auth _ | Masc_error.System _)) | Ok _) as result -> result_to_response ~tool_name ~start_time result
  in
  match result, !submission_receipt with
  | Ok message, Some receipt ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc ["result", `String message; "evidence_capture", receipt]) ()
  | Ok _, None | Error _, _ -> transition_result_to_response result

let handle_update_priority ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let priority = get_int args "priority" 3 in
  match Workspace.update_priority ctx.config ~task_id ~priority with
  | Ok (Workspace.Updated { task_id; old_priority; new_priority }) ->
    Tool_result.ok
      ~tool_name
      ~start_time
      (Printf.sprintf "Task %s priority: P%d → P%d" task_id old_priority new_priority)
  | Ok (Workspace.Not_found { task_id }) ->
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name
      ~start_time
      (Printf.sprintf "Task %s not found" task_id)
  | Error Workspace.Not_initialized ->
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name
      ~start_time
      "MASC workspace is not initialized"
  | Error (Workspace.Backlog_read_error detail) ->
    Tool_result.error
      ~failure_class:Tool_result.Dependency_unavailable
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update could not read the backlog: %s" detail)
  | Error (Workspace.Backlog_write_error detail) ->
    Tool_result.error
      ~failure_class:Tool_result.Dependency_unavailable
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update could not commit the backlog: %s" detail)
  | Error (Workspace.Lock_error error) ->
    Tool_result.error
      ~failure_class:Tool_result.Dependency_unavailable
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update could not acquire the backlog lock: %s"
         (Masc_domain.masc_error_to_string error))
  | Error (Workspace.Unexpected_error detail) ->
    Tool_result.error
      ~failure_class:Tool_result.Runtime_failure
      ~tool_name
      ~start_time
      (Printf.sprintf "Task priority update failed: %s" detail)

let list_tasks ~tool_name ~start_time ctx args =
  let include_done = get_bool args "include_done" false in
  let include_cancelled = get_bool args "include_cancelled" false in
  let list ?status () =
    Tool_result.ok ~tool_name ~start_time
      (Workspace.list_tasks
         ctx.config
         ~include_done
         ~include_cancelled
         ?status)
  in
  let refuse message =
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time message
  in
  match args |> Json_util.assoc_member_opt "status" |> Option.value ~default:`Null with
  | `Null -> list ()
  | `String raw ->
    (match Masc_domain.Task_status_tag.of_string raw with
     | Some status -> list ~status ()
     | None ->
       (* RFC-0189: caller passed an unknown status enum value. Answering
          "No tasks." would read as an empty board. *)
       refuse
         (Printf.sprintf "unknown status %S; expected one of: %s" raw
            (String.concat ", " Masc_domain.valid_task_status_strings)))
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
    refuse "status must be a string"


let handle_tasks ~tool_name ~start_time ctx args =
  let refuse detail = Tool_result.error
    ~failure_class:Tool_result.Workflow_rejection ~tool_name ~start_time detail in
  match Workspace.validate_expected_workspace ~config:ctx.config args with
  | Error error -> refuse (Workspace.expected_workspace_error_message error)
  | Ok args ->
    (match Tool_task_args.parse_task_creation_request_id args with
     | Error detail -> refuse detail
     | Ok None -> list_tasks ~tool_name ~start_time ctx args
     | Ok (Some request_id) ->
       let unknown = Tool_task_args.unknown_args ~valid_keys:["creation_request_id"] args in
       if unknown <> [] then
         refuse "creation_request_id lookup cannot be combined with task-list filters or other arguments"
       else match Workspace.read_task_creation_r ctx.config ~request_id with
         | Error detail -> Tool_result.error
             ~failure_class:Tool_result.Runtime_failure ~tool_name ~start_time detail
         | Ok reading ->
           let state,ids = match reading.Workspace.creation_lookup with
             | Creation_unobserved -> "not_observed",[]
             | Creation_recorded id -> "recorded",[id]
             | Creation_ambiguous ids -> "ambiguous",ids in
           Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [
             "ok",`Bool true;
             "creation_request_id",`String (Masc_domain.task_creation_request_id_to_string request_id);
             "workspace",`Assoc ["base_path",`String (Unix.realpath ctx.config.base_path);
                                    "masc_root",`String (Unix.realpath (Workspace.masc_dir ctx.config))];
             "backlog_version",`Int reading.creation_backlog_version;
             "creation_receipt",`Assoc ["state",`String state;
               "task_ids",`List (List.map (fun id -> `String id) ids)]]) ())

(* Walks newest-first and stops once [limit] events match [task_id], so [limit]
   counts the events a caller asked for. Counting raw lines instead made the
   caller filter afterwards, and no line budget expresses "this task's newest
   N": the budget fills with whatever the workspace last did, and a task whose
   events sit further back drops out of its own history entirely.

   Each file is parsed once and indexed by its top-level ["task"] and
   ["task_id"] fields because deciding on the raw line would mean matching an
   id as a substring of unparsed JSON — a different event's payload can carry
   that text. Malformed lines are skipped rather than counted: they are not
   events the caller asked for. *)
type cached_events_file = {
  st_dev : int;
  st_ino : int;
  st_size : int;
  st_mtime : float;
  st_ctime : float;
  ended_with_newline : bool;
  prefix_digest : Digest.t;
  bytes : int;
  by_task : (string, Yojson.Safe.t list) Hashtbl.t;
  mutable last_access_tick : int;
}

let max_cached_event_files = 256
(* A file-count bound alone does not bound memory: one entry retains the
   parsed events of a whole file. Keep the retained working set under this
   many bytes as well, evicting least-recently-touched files first. *)
let max_cached_event_bytes = 64 * 1024 * 1024
let events_file_cache : (string, cached_events_file) Hashtbl.t =
  Hashtbl.create 64
let events_file_cache_mutex = Mutex.create ()
let events_file_cache_tick = ref 0
let events_file_cache_retained_bytes = ref 0

let with_events_cache_lock f =
  Mutex.lock events_file_cache_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock events_file_cache_mutex) f

let touch_events_cache_tick () =
  incr events_file_cache_tick;
  !events_file_cache_tick

(* The caller holds the cache lock. *)
let evict_oldest_events_file () =
  let oldest_key = ref None in
  let oldest_tick = ref max_int in
  Hashtbl.iter
    (fun key (entry : cached_events_file) ->
       if entry.last_access_tick < !oldest_tick then begin
         oldest_tick := entry.last_access_tick;
         oldest_key := Some key
       end)
    events_file_cache;
  match !oldest_key with
  | Some key ->
    (match Hashtbl.find_opt events_file_cache key with
     | Some (entry : cached_events_file) ->
       events_file_cache_retained_bytes :=
         !events_file_cache_retained_bytes - entry.bytes
     | None -> ());
    Hashtbl.remove events_file_cache key
  | None -> ()

(* The caller holds the cache lock. *)
let evict_events_file_cache_if_needed () =
  while Hashtbl.length events_file_cache > 0
        && (Hashtbl.length events_file_cache > max_cached_event_files
            || !events_file_cache_retained_bytes > max_cached_event_bytes)
  do
    evict_oldest_events_file ()
  done

let add_event_for_task_key by_task key json =
  let existing = Option.value ~default:[] (Hashtbl.find_opt by_task key) in
  Hashtbl.replace by_task key (json :: existing)

let index_event_json by_task json =
  let task = Json_util.get_string json "task" in
  let task_id_field = Json_util.get_string json "task_id" in
  match task, task_id_field with
  | Some t1, Some t2 when String.equal t1 t2 ->
    add_event_for_task_key by_task t1 json
  | Some t1, Some t2 ->
    add_event_for_task_key by_task t1 json;
    add_event_for_task_key by_task t2 json
  | Some t1, None ->
    add_event_for_task_key by_task t1 json
  | None, Some t2 ->
    add_event_for_task_key by_task t2 json
  | None, None -> ()

(* Scan [content] forward from [start_pos] to [end_pos]. Because each matched
   event is prepended onto its per-task list in [by_task], the resulting list
   for each task is ordered newest-to-oldest within the file, matching the
   reverse-line traversal of the uncached implementation without allocating an
   intermediate list of all lines. *)
let index_events_content_range by_task content ~start_pos ~end_pos =
  let rec loop line_start =
    if line_start >= end_pos then ()
    else
      let line_end =
        match String.index_from_opt content line_start '\n' with
        | Some idx when idx < end_pos -> idx
        | _ -> end_pos
      in
      let line_len = line_end - line_start in
      if line_len > 0 then begin
        let line = String.sub content line_start line_len in
        match Yojson.Safe.from_string line with
        | json -> index_event_json by_task json
        | exception Yojson.Json_error _ -> ()
      end;
      loop (line_end + 1)
  in
  loop start_pos

let same_stat_identity (entry : cached_events_file) (st : Unix.stats) =
  entry.st_dev = st.st_dev
  && entry.st_ino = st.st_ino
  && entry.st_size = st.st_size
  && Float.equal entry.st_mtime st.st_mtime
  && Float.equal entry.st_ctime st.st_ctime

let load_events_file_index ~verify_content path =
  match Unix.stat path with
  | exception Unix.Unix_error _ -> None
  | st when st.st_kind <> Unix.S_REG -> None
  | st ->
    let check_stat_hit () =
      with_events_cache_lock (fun () ->
        match Hashtbl.find_opt events_file_cache path with
        | Some entry ->
          entry.last_access_tick <- touch_events_cache_tick ();
          Some entry
        | None -> None)
    in
    let should_verify = verify_content && st.st_size <= 262_144 in
    match check_stat_hit () with
    | Some entry when not should_verify && same_stat_identity entry st ->
      Some entry.by_task
    | _ ->
      (* No stripe lock across the scan: reads, digests and index builds run
         unlocked so a large scan cannot block another worker domain that
         hashes to the same stripe. Concurrent first scans duplicate work and
         the last publication wins — both idempotent. Cancellation must
         propagate: the loader checks the cancel context after its systhread
         read, so swallowing every exception here would convert a cancel into
         a silent miss. *)
      (match Fs_compat.load_file path with
       | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
       | exception _ -> None
       | content ->
         let cached_opt =
           with_events_cache_lock (fun () ->
             match Hashtbl.find_opt events_file_cache path with
             | Some entry ->
               entry.last_access_tick <- touch_events_cache_tick ();
               Some entry
             | None -> None)
         in
         let len = String.length content in
         let full_digest = Digest.string content in
         let by_task, was_exact_digest_hit =
           match cached_opt with
           | Some entry
             when entry.st_dev = st.st_dev
                  && entry.st_ino = st.st_ino
                  && entry.st_size = len
                  && Digest.equal full_digest entry.prefix_digest ->
             entry.by_task, true
           | Some entry
             when entry.st_dev = st.st_dev
                  && entry.st_ino = st.st_ino
                  && len > entry.st_size
                  && entry.ended_with_newline
                  && Digest.equal
                       (Digest.substring content 0 entry.st_size)
                       entry.prefix_digest ->
             let updated = Hashtbl.copy entry.by_task in
             index_events_content_range updated content
               ~start_pos:entry.st_size ~end_pos:len;
             updated, false
           | _ ->
             let fresh = Hashtbl.create 64 in
             index_events_content_range fresh content ~start_pos:0 ~end_pos:len;
             fresh, false
         in
         let stat_unchanged =
           match cached_opt with
           | Some entry -> same_stat_identity entry st
           | None -> false
         in
         if not (was_exact_digest_hit && stat_unchanged) then
           (match Unix.stat path with
            | st_after
              when st_after.st_kind = Unix.S_REG
                   && st_after.st_dev = st.st_dev
                   && st_after.st_ino = st.st_ino
                   && st_after.st_size = len
                   && Float.equal st_after.st_mtime st.st_mtime
                   && Float.equal st_after.st_ctime st.st_ctime ->
              let ended_with_newline =
                len > 0 && Char.equal content.[len - 1] '\n'
              in
              with_events_cache_lock (fun () ->
                (match Hashtbl.find_opt events_file_cache path with
                 | Some (entry : cached_events_file) ->
                   events_file_cache_retained_bytes :=
                     !events_file_cache_retained_bytes - entry.bytes
                 | None -> ());
                let tick = touch_events_cache_tick () in
                Hashtbl.replace events_file_cache path
                  {
                    st_dev = st.st_dev;
                    st_ino = st.st_ino;
                    st_size = len;
                    st_mtime = st.st_mtime;
                    st_ctime = st.st_ctime;
                    ended_with_newline;
                    prefix_digest = full_digest;
                    bytes = len;
                    by_task;
                    last_access_tick = tick;
                  };
                events_file_cache_retained_bytes :=
                  !events_file_cache_retained_bytes + len;
                evict_events_file_cache_if_needed ())
            | _ | exception Unix.Unix_error _ -> ());
         Some by_task)

let read_matching_task_events config ~task_id ~limit =
  if limit <= 0 then []
  else
    let events_dir = Filename.concat (Workspace.masc_dir config) "events" in
    if not (Sys.file_exists events_dir) then []
    else
      let month_dirs =
        Sys.readdir events_dir
        |> Array.to_list
        |> List.sort (fun a b -> Dated_jsonl.Layout.compare_month_entries b a)
      in
      let collected = ref [] in
      let remaining = ref limit in
      let is_first_file = ref true in
      let add_file_events path =
        if !remaining <= 0 then ()
        else
          let is_day_file =
            Option.is_some
              (Dated_jsonl.Layout.day_file_parts (Filename.basename path))
          in
          let verify_content = !is_first_file in
          match load_events_file_index ~verify_content path with
          | None -> ()
          | Some by_task ->
            if is_day_file then is_first_file := false;
            (match Hashtbl.find_opt by_task task_id with
             | None -> ()
             | Some events ->
               let rec take = function
                 | [] -> ()
                 | json :: rest ->
                   if !remaining > 0 then begin
                     collected := json :: !collected;
                     decr remaining;
                     take rest
                   end
               in
               take events)
      in
      List.iter
        (fun month ->
           if !remaining > 0 then
             let month_path = Filename.concat events_dir month in
             if Sys.file_exists month_path && Sys.is_directory month_path then
               let files =
                 Sys.readdir month_path
                 |> Array.to_list
                 |> List.sort (fun a b ->
                      Dated_jsonl.Layout.compare_day_files b a)
               in
               List.iter
                 (fun file ->
                    if !remaining > 0 then
                      let path = Filename.concat month_path file in
                      if Sys.file_exists path then add_file_events path)
                 files)
        month_dirs;
      List.rev !collected

let task_history_events_json (config : Workspace.config) ~task_id ~limit =
  `List (read_matching_task_events config ~task_id ~limit)

let handle_task_history ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  let limit = get_int args "limit" 50 in
  Tool_result.make_ok
    ~tool_name
    ~start_time
    ~data:(task_history_events_json ctx.config ~task_id ~limit)
    ()

include Tool_task_schemas
(* Dispatch function *)
(* The masc_* task tools route on Tool_name.Task_name, so a constructor added
   there is a compile error here rather than a tool that is advertised and then
   answers "unknown". keeper_task_claim is in the keeper_* namespace and is not
   part of that vocabulary. *)
let dispatch_task_name ?created_by ctx ~name ~args ~start = function
  | Tool_name.Task_name.Add_task ->
    handle_add_task ?created_by ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Batch_add_tasks ->
    handle_batch_add_tasks ?created_by ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Task_history ->
    handle_task_history ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Task_set_goal ->
    handle_set_goal ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Tasks -> handle_tasks ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Transition ->
    handle_transition ~tool_name:name ~start_time:start ctx args
  | Tool_name.Task_name.Update_priority ->
    handle_update_priority ~tool_name:name ~start_time:start ctx args
;;

let dispatch_internal ?created_by ctx ~name ~args =
  let start = Tool_timing.start () in
  match Tool_name.Task_name.of_string name with
  | Some task_name ->
    Some (dispatch_task_name ?created_by ctx ~name ~args ~start task_name)
  | None ->
    (match name with
     | "keeper_task_claim" ->
       let task_id = get_string args "task_id" "" in
       if String.equal task_id ""
       then Some (handle_claim_next ~tool_name:name ~start_time:start ctx args)
       else Some (handle_claim ~tool_name:name ~start_time:start ctx args)
     | _ -> None)

let dispatch ctx ~name ~args =
  dispatch_internal ctx ~name ~args
;;

let dispatch_for_keeper ~created_by ctx ~name ~args =
  dispatch_internal ~created_by ctx ~name ~args
;;
