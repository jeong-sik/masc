(** Workspace_query -- Task/agent/message query and listing functions.

    Read-only operations on workspace state: raw list retrieval, orphan auditing,
    message collection, agent-session-bound checks, and formatted listing. *)

open Masc_domain
include Workspace_utils
include Workspace_state
open Workspace_backlog
open Workspace_identity

type update_priority_outcome =
  | Updated of
      { task_id : string
      ; old_priority : int
      ; new_priority : int
      }
  | Not_found of { task_id : string }

type update_priority_error =
  | Not_initialized
  | Backlog_read_error of string
  | Backlog_write_error of string
  | Lock_error of Masc_domain.masc_error
  | Unexpected_error of string

let update_priority config ~task_id ~priority =
  if not (is_initialized config)
  then Error Not_initialized
  else
    let operation () =
      try
        match read_backlog_r config with
        | Error message -> Error (Backlog_read_error message)
        | Ok backlog ->
          (match List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks with
           | None -> Ok (Not_found { task_id })
           | Some task ->
             let old_priority = task.priority in
             let new_tasks =
               List.map
                 (fun (t : task) ->
                    if t.id = task_id then { t with priority } else t)
                 backlog.tasks
             in
             (* [write_backlog] stamps version/last_updated at the commit point. *)
             let new_backlog = { backlog with tasks = new_tasks } in
             write_backlog config new_backlog;
             (* The primary backlog commit is the mutation authority. A
                post-commit event or wake callback failure must be explicit in
                telemetry, but must not be returned as a pre-commit error that
                invites a caller to repeat an already committed update. *)
             (try
                log_event config
                  (`Assoc
                    [ ("type", `String "priority_change")
                    ; ("task", `String task_id)
                    ; ("old", `Int old_priority)
                    ; ("new", `Int priority)
                    ; ("ts", `String (now_iso ()))
                    ])
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Task.error
                  "priority update committed but post-commit notification failed task=%s: %s"
                  task_id
                  (Printexc.to_string exn));
             Ok (Updated { task_id; old_priority; new_priority = priority }))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | Backlog_write_failed message -> Error (Backlog_write_error message)
      | exn -> Error (Unexpected_error (Printexc.to_string exn))
    in
    match with_file_lock_r config (backlog_lock_path config) operation with
    | Ok result -> result
    | Error error -> Error (Lock_error error)

(** Get raw task list (for orchestrator).
    Requires initialization. *)
let get_tasks_raw config =
  ensure_initialized config;
  (read_backlog config).tasks

(** Like [get_tasks_raw] but returns [[]] when MASC is not
    initialized — safe for dashboard and display contexts.
    Replaces the former [get_tasks_raw_in_workspace]. *)
let get_tasks_safe config =
  if not (root_is_initialized config) then []
  else (read_backlog config).tasks

let safe_yield () =
  Safe_ops.protect ~default:() (fun () -> Eio.Fiber.yield ())

let take_first = List.take

let list_leaf_json_names config dir =
  list_dir config dir
  |> List.filter (fun name ->
         name <> ""
         && not (String.contains name '/')
         && Filename.check_suffix name ".json")

let agents_persistence_surface = "workspace_agents"

(* A file under [agents/] that does not decode is dropped from the listing
   and counted on [masc_persistence_read_drops_total]; nothing rewrites it.
   An open() that failed under fd pressure is not a loss (RFC-0134) and is
   logged without the data-integrity counter. *)
let load_agents_from_dir config dir ~include_inactive =
  list_leaf_json_names config dir
  |> List.filter_map (fun name ->
         safe_yield ();
         let path = Filename.concat dir name in
         match read_agent_result config path with
         | Ok agent when include_inactive || agent.status <> Masc_domain.Inactive ->
             Some agent
         | Ok _ -> None
         | Error (Agent_fd_pressure exn) ->
             Log.Workspace.warn "agent listing skipped %s under fd pressure: %s"
               path (Printexc.to_string exn);
             None
         | Error (Agent_read_error detail) ->
             Safe_ops.report_persistence_read_drop_counted
               ~surface:agents_persistence_surface
               ~reason:Read_drop_reason.Entry_load_error
               ~path ~detail;
             None)

let state_backed_agent_type = "workspace-state"

let state_backed_agent state (name : string) : Masc_domain.agent =
  let agent_type = state_backed_agent_type in
  let timestamp = state.started_at in
  let meta : Masc_domain.agent_meta =
    { session_id = "workspace-state:" ^ name
    ; agent_type
    ; pid = None
    ; hostname = None
    ; tty = None
    ; parent_task = None
    ; keeper_name = None
    ; keeper_id = None
    }
  in
  { id = None
  ; name
  ; agent_type
  ; status = Masc_domain.Active
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = timestamp
  ; last_seen = timestamp
  ; meta = Some meta
  }

let state_backed_active_agents config =
  let state = read_state config in
  state.active_agents |> normalized_string_list |> List.map (state_backed_agent state)

(* Reading the runtime roster can fail on its own while the rest of the
   observation succeeds. The empty list that comes back then is
   indistinguishable from "no runtime agents are up", so the detail travels
   beside it and the caller decides whether anyone is told: the log line alone
   left [masc_status] answering with a shorter roster and no sign that a read
   had failed. *)
let runtime_agents config =
  try (Atomic.get Workspace_hooks.runtime_agents_fn) config, None with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let detail = Printexc.to_string exn in
    Log.Workspace.warn
      "runtime_agents_fn failed while reading active agents: %s"
      detail;
    [], Some ("runtime agent roster: " ^ detail)

let agent_status_is_active = function
  | Masc_domain.Active | Busy | Listening -> true
  | Inactive -> false

let active_runtime_agents config =
  let agents, failure = runtime_agents config in
  ( List.filter
      (fun (agent : Masc_domain.agent) -> agent_status_is_active agent.status)
      agents
  , failure )

let merge_agents primary secondary =
  let seen = Hashtbl.create (List.length primary + List.length secondary) in
  let add_if_new acc (agent : Masc_domain.agent) =
    if Hashtbl.mem seen agent.name then acc
    else (
      Hashtbl.add seen agent.name ();
      agent :: acc)
  in
  List.rev (List.fold_left add_if_new (List.fold_left add_if_new [] primary) secondary)

(** Get raw agent list (for orchestrator).
    Includes inactive agents. Requires initialization. *)
let get_agents_raw config =
  ensure_initialized config;
  let agents_path = agents_dir config in
  load_agents_from_dir config agents_path ~include_inactive:true

(** Active agents together with whatever went wrong while reading them. The
    roster is merged from three sources and one can fail while the others
    answer, so a caller that shows the roster to a person can say so instead of
    presenting a short list as a complete one. *)
let get_active_agents_observed config =
  if not (root_is_initialized config)
  then [], []
  else (
    let agents_path = agents_dir config in
    let workspace_agents = load_agents_from_dir config agents_path ~include_inactive:false in
    let state_agents = state_backed_active_agents config in
    let runtime, runtime_failure = active_runtime_agents config in
    ( merge_agents (merge_agents workspace_agents state_agents) runtime
    , Option.to_list runtime_failure ))

(** Return active agents only.  Returns [[]] when MASC is not
    initialized — safe for dashboard and display contexts.
    Replaces the former [get_agents_raw_in_workspace]. *)
let get_active_agents config = fst (get_active_agents_observed config)

(** Like [get_agents_raw] but returns [[]] when not initialized
    instead of raising.  Includes inactive agents.
    Useful for keeper backlog-triage enrollment. *)
let get_all_agents config =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir config in
    load_agents_from_dir config agents_path ~include_inactive:true

(** Audit owned tasks ([Claimed], [InProgress], [AwaitingVerification]) whose
    exact assignee identity is absent from explicit active workspace/session
    membership. [last_seen] is retained as observation and never changes task
    ownership. *)
let audit_orphan_tasks_in_tasks config tasks : (Masc_domain.task * string) list =
  if not (is_initialized config) then []
  else
    let active_names =
      get_active_agents config
      |> List.map (fun (agent : Masc_domain.agent) -> agent.name)
    in
    let is_active_agent assignee = List.mem assignee active_names in
    List.filter_map (fun (task : Masc_domain.task) ->
      match task.task_status with
      | Masc_domain.Claimed { assignee; _ }
      | Masc_domain.InProgress { assignee; _ }
      | Masc_domain.AwaitingVerification { assignee; _ } ->
          if is_active_agent assignee then None
          else Some (task, assignee)
      | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None
    ) tasks

let audit_orphan_tasks config : (Masc_domain.task * string) list =
  if not (is_initialized config) then []
  else audit_orphan_tasks_in_tasks config (read_backlog config).tasks

(* RFC-0294 PR-4: the single typed source of truth for "is this status
   orphan-eligible, and under which gauge class". EXHAUSTIVE over [task_status]
   ([@warning "-4"] absent on purpose): adding a new constructor forces a
   classification decision here at compile time, so a future orphan-eligible
   status can never be silently dropped from the gauge — the exact failure the
   old [String.equal (task_status_to_string …)] round-trip allowed. The label
   strings are the [Masc_domain.task_status_to_string] values for the active
   statuses, kept here so the metric vocabulary has one owner. Must stay aligned
   with the orphan-eligibility match in [audit_orphan_tasks] above (both select
   Claimed / InProgress / AwaitingVerification); the surfacer test pins both the
   Some-labels and the None-set so a divergence fails the test. *)
let orphan_status_class_of_status : Masc_domain.task_status -> string option = function
  | Masc_domain.Claimed _ -> Some "claimed"
  | Masc_domain.InProgress _ -> Some "in_progress"
  | Masc_domain.AwaitingVerification _ -> Some "awaiting_verification"
  | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None

(* The fixed class set the gauge reports (0 when a class is empty, so a cleared
   class resets rather than going stale). Exactly the Some-range of
   [orphan_status_class_of_status]; the drift-guard test pins that equality. *)
let orphan_status_classes = [ "claimed"; "in_progress"; "awaiting_verification" ]

(* Pure: count orphan-audit results per status class over the fixed class set.
   Membership is decided by the typed [orphan_status_class_of_status], not a
   string round-trip, so the grouping shares one exhaustive classifier with the
   gauge vocabulary. Separated from the metric I/O (the gauge emitter lives in
   the orchestrator pulse, which owns the Otel dependency) so the grouping is
   unit-testable without workspace or metric-store side effects. *)
let orphan_counts_by_status_class (orphans : (Masc_domain.task * string) list)
  : (string * int) list =
  List.map
    (fun status_class ->
       let count =
         List.length
           (List.filter
              (fun ((task : Masc_domain.task), _assignee) ->
                 match orphan_status_class_of_status task.task_status with
                 | Some c -> String.equal c status_class
                 | None -> false)
              orphans)
       in
       status_class, count)
    orphan_status_classes

let is_agent_active_at_path config path =
  match read_json_opt config path with
  | None -> false
  | Some json ->
      (match agent_of_yojson json with
       | Ok agent -> agent.status <> Inactive
       | Error _ -> false)

(** Check if an agent has session-bound *)
let is_agent_session_bound config ~agent_name =
  if not (root_is_initialized config) then false
  else
    let actual_name = resolve_agent_name config agent_name in
    let filename = safe_filename actual_name ^ ".json" in
    let agents_path = agents_dir config in
    let agent_path = Filename.concat agents_path filename in
    is_agent_active_at_path config agent_path

(** Check if filename is valid (no special characters) *)
let is_valid_filename name =
  String.for_all (fun c ->
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c = '_' || c = '-' || c = '.'
  ) name

let select_recent_message_names ~since_seq ~limit names =
  let insert_candidate acc name =
    let seq = message_seq_of_filename name in
    if limit <= 0 || seq <= since_seq then
      acc
    else
      let rec insert prefix = function
        | [] -> List.rev_append prefix [ (seq, name) ]
        | ((existing_seq, _) as existing) :: rest ->
            if seq >= existing_seq then
              List.rev_append prefix ((seq, name) :: existing :: rest)
            else
              insert (existing :: prefix) rest
      in
      insert [] acc |> take_first limit
  in
  names
  |> List.fold_left
       (fun acc name ->
         safe_yield ();
         insert_candidate acc name)
       []
  |> List.map snd

let select_all_message_names ~since_seq names =
  names
  |> List.filter_map (fun name ->
       let seq = message_seq_of_filename name in
       if seq <= since_seq then None else Some (seq, name))
  |> List.sort (fun (seq_a, name_a) (seq_b, name_b) ->
       let cmp = compare seq_a seq_b in
       if cmp <> 0 then cmp else String.compare name_a name_b)
  |> List.map snd

let select_all_message_names_newest_first ~since_seq names =
  select_all_message_names ~since_seq names |> List.rev

(** Read most-recent messages without parsing the entire history directory.

    [keep] decides which messages COUNT toward [limit]. Without it a caller that
    filters afterwards cannot express "the newest [limit] messages of MINE": the
    store returns [limit] messages from every agent and the caller's filter thins
    them to an unpredictable number, which is zero once other agents fill the
    window. Callers used to compensate by requesting a multiple of what they
    wanted — 200, 2000, [limit * 5], [limit * 10] capped at 1000, a different
    guess at each call site — and each guess is wrong at some fleet size.

    Filtering here costs a wider directory walk, bounded by the messages that
    exist rather than by a guess, and stops as soon as [limit] matches are
    found. *)
(* The two reads walk different amounts of the directory, so which one is
   wanted is a caller's decision rather than a default. [Newest_window] can stop
   at [limit] names because every name it reads is an answer; [Matching] cannot
   know how far back the [limit]-th match sits. Collapsing them into an optional
   predicate would make the cheap walk the silent default for a caller that
   needed the other one — the exact shape that put a filter after the read in
   the first place. *)
type message_scan =
  | Newest_window
  | Matching of (Masc_domain.message -> bool)

let collect_recent_messages config ~msgs_path ~since_seq ~limit ~scan ~warn_label =
  if not (Sys.file_exists msgs_path) then []
  else
    let names =
      Sys.readdir msgs_path
      |> Array.to_list
      |> List.filter is_valid_filename
      |> (match scan with
          | Newest_window -> select_recent_message_names ~since_seq ~limit
          | Matching _ -> select_all_message_names_newest_first ~since_seq)
    in
    let keep (msg : Masc_domain.message) =
      match scan with
      | Newest_window -> true
      | Matching predicate -> predicate msg
    in
    let rec loop remaining acc = function
      | _ when remaining <= 0 -> List.rev acc
      | [] -> List.rev acc
      | name :: rest ->
          safe_yield ();
          if message_seq_of_filename name <= since_seq then List.rev acc
          else
            let path = Filename.concat msgs_path name in
            match read_json config path with
            | json ->
                (match message_of_yojson json with
                 | Ok msg when msg.seq > since_seq && keep msg ->
                     loop (remaining - 1) (msg :: acc) rest
                 | Ok _ | Error _ -> loop remaining acc rest)
            | exception (Eio.Cancel.Cancelled _ as e) -> raise e
            | exception e ->
                Log.legacy_traceln ~level:Log.Warn ~module_name:"Workspace"
                  (Printf.sprintf "[WARN] Failed to read %s %s: %s" warn_label
                     name (Printexc.to_string e));
                loop remaining acc rest
    in
    loop limit [] names

(** Get raw message list (for dashboard).
    Returns [[]] when MASC is not initialized. *)
let get_messages_raw config ~since_seq ~limit =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir config in
    collect_recent_messages
      config
      ~msgs_path
      ~since_seq
      ~limit
      ~scan:Newest_window
      ~warn_label:"message"

let get_messages_matching config ~since_seq ~limit ~keep =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir config in
    collect_recent_messages
      config
      ~msgs_path
      ~since_seq
      ~limit
      ~scan:(Matching keep)
      ~warn_label:"message"

let get_all_messages_raw config ~since_seq =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir config in
    if not (Sys.file_exists msgs_path) then []
    else
      let names =
        Sys.readdir msgs_path
        |> Array.to_list
        |> List.filter is_valid_filename
        |> select_all_message_names ~since_seq
      in
      let rec loop acc = function
        | [] -> List.rev acc
        | name :: rest ->
            safe_yield ();
            let path = Filename.concat msgs_path name in
            match read_json config path with
            | json ->
                (match message_of_yojson json with
                 | Ok msg when msg.seq > since_seq -> loop (msg :: acc) rest
                 | Ok _ | Error _ -> loop acc rest)
            | exception (Eio.Cancel.Cancelled _ as e) -> raise e
            | exception e ->
                Log.legacy_traceln ~level:Log.Warn ~module_name:"Workspace"
                  (Printf.sprintf
                     "[WARN] Failed to read workspace message %s: %s"
                     name (Printexc.to_string e));
                loop acc rest
      in
      loop [] names

(** List tasks *)
let list_tasks ?(include_done = false) ?(include_cancelled = false) ?status config =
  ensure_initialized config;

  let backlog = read_backlog config in
  let tasks =
    match status with
    | Some status_filter ->
        List.filter (fun (task : task) ->
          String.equal status_filter (string_of_task_status task.task_status)
        ) backlog.tasks
    | None ->
        List.filter (fun (task : task) ->
          let status = task.task_status in
          let is_done = Masc_domain.task_status_is_done status in
          let is_cancelled = match status with
            | Masc_domain.Cancelled _ -> true
            | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
            | Masc_domain.AwaitingVerification _ | Masc_domain.Done _ -> false
          in
          (include_done || not is_done) &&
          (include_cancelled || not is_cancelled)
        ) backlog.tasks
  in
  if tasks = [] then
    if backlog.tasks = [] then
      "No tasks."
    else
      "No active tasks (all done/cancelled)."
  else begin
    let buf = Buffer.create 256 in
    Buffer.add_string buf "Quest Board\n";
    Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

    let sorted = List.sort (fun a b -> compare a.priority b.priority) tasks in
    List.iter (fun task ->
      let status_icon = Masc_domain.task_status_icon task.task_status in
      let assignee = Masc_domain.task_display_assignee task.task_status in
      let status_str = Masc_domain.string_of_task_status task.task_status in
      Printf.bprintf buf "%s [%d] %s: %s\n" status_icon task.priority task.id task.title;
      Printf.bprintf buf "   └─ %s | %s\n" status_str assignee;
      match task.task_status with
      | Masc_domain.AwaitingVerification { verification_id; _ } ->
        (* Task listing is metadata-only by construction. Evidence bytes are
           read only through [inspect_submitted_evidence_for_authority] after an
           authenticated completion authority has been produced. *)
        Printf.bprintf buf
          "   └─ verification_request=%s evidence=metadata_only\n"
          verification_id;
        Printf.bprintf buf
          "   └─ awaiting_completion_authority task_id=%s\n"
          task.id
      | Masc_domain.Todo
      | Masc_domain.Claimed _
      | Masc_domain.InProgress _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ -> ()
    ) sorted;

    Buffer.contents buf
  end

(** Get recent messages *)
let get_messages config ~since_seq ~limit =
  ensure_initialized config;

  let buf = Buffer.create 256 in
  Buffer.add_string buf "Recent Messages\n";
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
  let messages = get_messages_raw config ~since_seq ~limit in
  List.iter
    (fun msg ->
      let time_part =
        String.sub msg.timestamp 0 (min 16 (String.length msg.timestamp))
      in
      let time_str = String.map (function 'T' -> ' ' | c -> c) time_part in
      Buffer.add_string buf
        (Printf.sprintf "[%s] %s: %s\n" time_str msg.from_agent msg.content))
    messages;

  if Buffer.length buf = 73 then (* Only header *)
    Buffer.add_string buf "(no new messages)\n";

  Buffer.contents buf
