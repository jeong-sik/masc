(** TUI data loading functions — split from masc_tui.ml (#3808) *)

(* Independent reads share the current Eio cancellation scope. Keep the
   synchronous entry point usable when no TUI runtime has been installed. *)
let read_pair left right =
  match Eio_context.get_switch_opt () with
  | Some _ -> Eio.Fiber.pair left right
  | None ->
      let left = left () in
      left, right ()

(* Child reads inherit their caller's workspace binding. Each map joins its
   children in the current cancellation scope and retains input/result pairing;
   callers without an installed TUI runtime keep the synchronous entry point. *)
let read_map read items =
  match Eio_context.get_switch_opt () with
  | Some _ -> Eio.Fiber.List.map read items
  | None -> List.map read items

(* Typed results keyed by the physical identity of the JSON they were decoded
   from. A 304 answers with the very object the last pass decoded, so the
   typed decode runs only when a fresh body arrived. Decoders here are pure,
   so an identical input answers identically -- success or failure. Input and
   result share one immutable list reference, so concurrent readers always see a
   consistent pair and multi-page loaders (such as connector directory pages)
   retain every kept page across passes without thrashing a single slot. *)
let json_memo_capacity = 32

type 'a json_memo = { mutable memo_entries : (Yojson.Safe.t * 'a) list }

let json_memo () = { memo_entries = [] }

let rec take_at_most n = function
  | [] -> []
  | _ when n <= 0 -> []
  | head :: tail -> head :: take_at_most (n - 1) tail

let decode_memoized memo decode json =
  match List.find_opt (fun (previous, _) -> previous == json) memo.memo_entries with
  | Some (_, result) -> result
  | None ->
      let result = decode json in
      let remaining =
        List.filter (fun (previous, _) -> previous != json) memo.memo_entries
        |> take_at_most (json_memo_capacity - 1)
      in
      memo.memo_entries <- (json, result) :: remaining;
      result

(* A dashboard GET decode: skipped when the kept answer did not move, run on
   the CPU pool otherwise. For single-JSON decodes only -- decodes that read
   anything else (a second body, a reference, caller strings) take
   [Masc_tui_response_decode.run] directly. *)
let decode_offloaded memo ~name decode json =
  decode_memoized memo
    (fun json -> Masc_tui_response_decode.run ~name (fun () -> decode json))
    json

module Keeper_declared_roster = Masc.Keeper_declared_roster
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_status_runtime = Masc.Keeper_status_runtime
module Keeper_snapshot_unread = Masc.Keeper_snapshot_unread
module Keeper_types_profile = Masc.Keeper_types_profile
module Keeper_selection = Masc_tui_keeper_selection
module Context_state = Masc_tui_context_state

open Masc_tui_types
open Tui_decode
open Masc_tui_http

let report path err =
  Console_sink.write
    (Printf.sprintf "[masc-tui] decode failed for %s: %s"
       (Masc_tui_ansi.Terminal_text.single_line path)
       (Masc_tui_ansi.Terminal_text.single_line err))

let summarize_errors label errors =
  match List.rev errors with
  | [] -> None
  | first :: rest ->
      let suffix =
        match rest with
        | [] -> ""
        | _ -> Printf.sprintf " (+%d more)" (List.length rest)
      in
      Some (Printf.sprintf "%s: %s%s" label first suffix)

(** Load keepers through the canonical metadata classifier and typed store.
    The classifier preserves valid dotted names and excludes sidecars. *)
(* Every refresh read all ten meta files whole, and in a thirty-second sample
   not one of them changed. A file nothing has written to since the last read
   still decodes to what it decoded then, so the read is skipped and that value
   reused -- the same size-and-modification-time test [Workspace_backlog]
   already applies to the backlog. [Unix.stat] carries sub-second times here, so
   a write cannot land inside one without moving it. *)
type cached_keeper_meta = {
  cached_mtime : float;
  cached_size : int;
  cached_keeper : keeper;
}

let keeper_meta_cache : (string, cached_keeper_meta) Hashtbl.t =
  Hashtbl.create 16

let stat_opt path =
  try Some (Unix.stat path) with Unix.Unix_error _ | Sys_error _ -> None

let cached_keeper_for path stat =
  match stat, Hashtbl.find_opt keeper_meta_cache path with
  | Some (st : Unix.stats), Some entry
    when st.Unix.st_mtime = entry.cached_mtime
         && st.Unix.st_size = entry.cached_size ->
      Some entry.cached_keeper
  | (Some _ | None), (Some _ | None) -> None

let remember_keeper path stat keeper =
  match stat with
  | None -> ()
  | Some (st : Unix.stats) ->
      Hashtbl.replace keeper_meta_cache path
        { cached_mtime = st.Unix.st_mtime;
          cached_size = st.Unix.st_size;
          cached_keeper = keeper;
        }

let load_keepers (base_path : string) : keeper list * string option =
  let config = Workspace_core.default_config base_path in
  match Keeper_meta_store.persisted_keeper_names_result config with
  | Error err ->
      report (Keeper_types_profile.keeper_dir config) err;
      [], Some ("keeper metadata unavailable: " ^ err)
  | Ok names ->
      (* [keeper_meta_path] resolves the directory again for every name it is
         handed, and resolving it takes a lock and a stat each time. The
         directory is the same for all of them, so it is resolved once and the
         file names hung off it. *)
      let keepers_dir = Keeper_types_profile.keeper_dir config in
      let meta_path name =
        Filename.concat keepers_dir
          (Keeper_runtime_root_entry.keeper_basename ~keeper_name:name
             Keeper_runtime_root_entry.Metadata)
      in
      let paths = List.map meta_path names in
      (* A cache entry belongs to the actual file, not a repeated Keeper name.
         Retain only this observed source's inventory. *)
      Hashtbl.filter_map_inplace
        (fun path entry -> if List.mem path paths then Some entry else None)
        keeper_meta_cache;
      let keepers, errors =
        List.fold_left
          (fun (keepers, errors) name ->
             let path = meta_path name in
             let stat = stat_opt path in
             match cached_keeper_for path stat with
             | Some keeper -> keeper :: keepers, errors
             | None -> (
                 match Keeper_meta_store.read_meta config name with
                 | Ok (Some meta) ->
                     let keeper = Tui_decode.keeper_of_meta meta in
                     remember_keeper path stat keeper;
                     keeper :: keepers, errors
                 | Ok None -> keepers, errors
                 | Error err ->
                     report path err;
                     keepers, (Printf.sprintf "%s: %s" name err :: errors)))
          ([], []) names
      in
      let declarations = Keeper_declared_roster.missing ~base_path
          ~persisted_names:names |> List.map Tui_decode.keeper_of_declaration in
      ( List.sort (fun a b -> String.compare a.k_name b.k_name) (keepers @ declarations)
      , summarize_errors "keeper metadata read failed" errors )

(* The tasks [masc_gc] moved out of the backlog, for the flow's windows.
   The archive is megabytes and only a GC rewrites it, so it is parsed again
   only when its size or modification time changed. A row that does not
   decode is counted and named, not dropped quietly. *)
type cached_archive = {
  archive_path : string;
  archive_mtime : float;
  archive_size : int;
  archive_read : Masc_domain.task list * int;
}

let archive_seen : cached_archive option ref = ref None

let read_archived_tasks path : (Masc_domain.task list * int, string) result =
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ([], 0)
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | { Unix.st_mtime; st_size; _ } ->
    (match !archive_seen with
     | Some cached when String.equal cached.archive_path path
                        && Float.equal cached.archive_mtime st_mtime
                        && cached.archive_size = st_size -> Ok cached.archive_read
     | Some _ | None ->
       (match Safe_ops.read_json_file_safe path with
        | Error error -> Error error
        | Ok json ->
          let read =
            List.fold_right
              (fun entry (tasks, undecoded) ->
                match Masc_domain.task_of_yojson entry with
                | Ok task -> task :: tasks, undecoded
                | Error _ -> tasks, undecoded + 1)
              (Workspace_task_id.archive_entries_of_json json) ([], 0)
          in
          archive_seen := Some {archive_path = path; archive_mtime = st_mtime;
                                archive_size = st_size; archive_read = read};
          Ok read))
;;

(** Load tasks from the canonical workspace backlog: the active rows for the
    Overview list, plus the full domain rows the detail view reads. Terminal
    tasks remain available in Planning rollups and the detail view but do not
    occupy the Overview list. *)
let load_active_tasks ~fresh (base_path : string) :
    Masc_tui_overview_tasks.rows_reading
    * Masc_domain.task list
    * string option
    * Masc_tui_task_flow.t option
    * Masc_tui_agenda.stalled Masc_tui_agenda.reading
    * task_goal_links_reading =
  let config = Workspace_core.default_config base_path in
  if fresh then Workspace_backlog.invalidate_backlog_cache config;
  let path = Workspace_backlog.backlog_path config in
  match Workspace_backlog.read_backlog_observation_with_source_r config with
  | Error err ->
      report path err;
      let reason = "task backlog unavailable: " ^ err in
      ( Masc_tui_overview_tasks.Rows_unavailable reason
      , []
      , Some reason
      , None
      , Masc_tui_agenda.Read_failed reason
      , Goal_links_not_read )
  | Ok observation ->
      let recovery_error =
        match observation.recovered_from with
        | None -> None
        | Some recovery ->
            report path recovery.primary_error;
            Some ("task backlog recovered from backup: " ^ recovery.primary_error)
      in
      (* Goal links are supplemental to tasks, but only a successful primary
         registry read can establish their presence or absence. *)
      let goal_task_links =
        match Workspace_goal_index.read_goal_task_links_authoritative_r config with
        | Error err ->
            let reason = "goal links unavailable: " ^ err in
            Goal_links_read_failed reason
        | Ok goal_task_links ->
            Goal_links_read
              (Workspace_goal_index.build_task_goal_index ~goal_task_links ())
      in
      let goals_for_task =
        match goal_task_links with
        | Goal_links_read index ->
            fun task_id -> Workspace_goal_index.goals_for_task index ~task_id
        | Goal_links_not_read | Goal_links_read_failed _ -> fun _ -> []
      in
      let archived, archive_error =
        match read_archived_tasks (Workspace_utils_paths_backend.archive_path config) with
        | Ok (tasks, 0) -> tasks, None
        | Ok (tasks, undecoded) ->
          ( tasks
          , Some
              (Printf.sprintf "%d archived tasks could not be read; the day bars miss them"
                 undecoded) )
        | Error error ->
          report (Workspace_utils_paths_backend.archive_path config) error;
          [], Some ("task archive unavailable, the day bars miss archived tasks: " ^ error)
      in
      ( Masc_tui_overview_tasks.Rows_read
          (Tui_decode.active_tasks_of_domain ~goals_for_task
             observation.observed_backlog.tasks)
      , observation.observed_backlog.tasks
      , (match List.filter_map Fun.id
                 [ recovery_error; archive_error ] with
         | [] -> None
         | errors -> Some (String.concat " · " errors))
      , Some (Masc_tui_task_flow.of_tasks ~now:(Unix.gettimeofday ()) ~archived
                observation.observed_backlog.tasks)
      (* Projected here rather than on a render frame: resolving whether an
         assignee has a Keeper queue reads the registry and the meta store, and
         a frame that touches the filesystem per row is a frame that stutters.
         Same rows, same load, same answer the rejection delivery computes. *)
      , (match recovery_error with
         | Some reason -> Masc_tui_agenda.Read_failed reason
         | None ->
             Masc_tui_agenda.Read
               (Masc.Operator_task_attention.project ~config
                  observation.observed_backlog.tasks))
      , goal_task_links )

(* Goals whose stored phase awaits the operator's confirmation. This query does
   not read their proof ledger. Read the goal store as the tasks above read the backlog,
   so the agenda has the answer on every surface and not only on Planning. A
   store that does not read is said as such rather than as an empty list.
   Titles and the failure are made one printable row here, as every other
   goal title on the screen is. *)
let load_goals_to_confirm (base_path : string) :
    Masc_tui_agenda.goal_to_confirm Masc_tui_agenda.reading =
  let config = Workspace_core.default_config base_path in
  match
    Goal_store.list_goals_result config ~phase:Goal_phase.Awaiting_confirmation ()
  with
  | Error unavailable ->
      Masc_tui_agenda.Read_failed
        (Masc_tui_ansi.Terminal_text.single_line
           ("goals load failed: " ^ Goal_store.unavailable_to_string unavailable))
  | Ok goals ->
      Masc_tui_agenda.Read
        (List.map
           (fun (goal : Goal_store.goal) ->
             { Masc_tui_agenda.goal_id = goal.id
             ; title = Masc_tui_ansi.Terminal_text.single_line goal.title
             ; since_iso = goal.updated_at
             })
           goals)

(** Add an event to the TUI session log, which Metrics draws. *)
let add_event (state : state) event_type content =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let ev = { timestamp; event_type; content } in
  state.events <- ev :: List.filteri (fun i _ -> i < 10) state.events

let record_observer_opened (state : state) ~session_id ~at =
  state.observer_last_close <- None;
  state.observer <- Observer_live { session_id; since = at; events = 0 };
  Log.Transport.info "tui_observer_opened replay=%s"
    (observer_replay_word state.observer_replay);
  add_event state "observer"
    (observer_replay_description ~ko:false ~source_loss:state.observer_source_loss
       state.observer_replay);
  add_event state "observer" "runtime event feed open"

let record_observer_closed (state : state) ~workspace outcome ~reason ~at =
  (* The transport log is how connection cadence is measured at all: the
     session event list is bounded and in-memory. lived_s says whether this
     was a long-lived stream ending or another flap. *)
  (match state.observer with
   | Observer_live { since; _ } ->
       Log.Transport.info "tui_observer_closed lived_s=%.1f reason=%s" (at -. since) reason
   | Observer_off | Observer_opening | Observer_closed_before_answer _
   | Observer_closed_after_live _ -> Log.Transport.info "tui_observer_closed reason=%s" reason);
  let repeated =
    match state.observer_last_close with
    | Some (previous_workspace, previous) ->
        previous_workspace = workspace && previous = outcome
    | None -> false
  in
  (* Keep the latest transport observation even when the same outage has
     already been reported. A retry must not fill the bounded session log
     and evict unrelated operator actions or failures. *)
  state.observer <-
    (match state.observer with
     | Observer_live { events; _ } ->
         Observer_closed_after_live { reason; at; events }
     | Observer_off | Observer_opening | Observer_closed_before_answer _
     | Observer_closed_after_live _ ->
         Observer_closed_before_answer { reason; at });
  state.observer_last_close <- Some (workspace, outcome);
  if not repeated then
    add_event state "observer" ("runtime event feed closed: " ^ reason)

(* An outcome the operator pressed a key for, rather than something that
   happened on its own. It goes to the session log like any other event, and
   to the footer, because the log is drawn by Metrics alone: the operator who
   pressed [a] on Workspace reads on Workspace whether the registration
   landed, the declaration was refused, or the editor never started. Every
   call site that answers a key or a command, or finishes the request one
   started, uses this; [add_event] alone is for what happened on its own --
   the feed, a failed poll, the server's lifecycle. The footer copy is one
   line: a server's reason can carry newlines. *)
let report_action ?(show_in_footer = true) (state : state) event_type content =
  add_event state event_type content;
  set_last_action state
    (if show_in_footer then
      Some (Masc_tui_ansi.Terminal_text.single_line content, Unix.gettimeofday ())
    else None)

let report_input_rejection (state : state) kind content =
  add_event state "error" content;
  state.last_action <- Masc_tui_action_notice.reject state.last_action kind
      ~now:(Unix.gettimeofday ()) ~window:Masc_tui_types.last_action_window_s

(* Local metadata and the public remote roster share identity-based navigation.
   Replacing rows never reads a local directory. *)
let replace_keeper_rows ?(before_view_change = fun () -> ()) ~preserve_on_error (state : state)
    ~keepers:loaded_keepers ~error:keepers_error =
  let set_view view =
    if state.view <> view then begin
      before_view_change ();
      state.view <- view
    end in
  (* Capture navigation before replacing the roster. Detail and logs are bound
     to the selected row; message mode is bound to its explicit target. *)
  let current_keeper_ids =
    List.map (fun keeper -> keeper.k_name) (keepers_for_selection state)
  in
  let selected_keeper_name =
    match state.detail_focus_recovery with
    | Some (origin, name, _) when state.view = Keepers Keeper_detail
        && server_workspace_matches ~expected:(Some origin)
             (match state.server_identity with Some current -> Ok current | None -> Error "unread") ->
        Some name
    | _ ->
        if state.keeper_cursor < 0 then None
        else Option.map (fun keeper -> keeper.k_name) (selected_keeper state)
  in
  let current_keeper_mode =
    match state.view with
    | Keepers mode -> Some mode
    | Overview | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals
    | Planning | Schedules | Verification | Harness | Fusion | Repositories
    | Code | Changes | Connectors | Runtime | Config | Resources | Tools
    | System_logs -> None
  in
  let current_navigation =
    match current_keeper_mode with
    | Some Keeper_detail ->
        (match selected_keeper_name with
         | Some keeper_name ->
             Keeper_selection.Detail_keeper
               { keeper_name; cursor = state.keeper_cursor }
         | None -> Keeper_selection.List_cursor state.keeper_cursor)
    | Some Keeper_logs ->
        (match selected_keeper_name with
         | Some keeper_name ->
             Keeper_selection.Logs_keeper
               { keeper_name; cursor = state.keeper_cursor }
         | None -> Keeper_selection.List_cursor state.keeper_cursor)
    | Some Keeper_calls ->
        (match selected_keeper_name with
         | Some keeper_name ->
             Keeper_selection.Calls_keeper
               { keeper_name; cursor = state.keeper_cursor }
         | None -> Keeper_selection.List_cursor state.keeper_cursor)
    | Some Keeper_message ->
        (match state.msg_target_keeper_name with
         | Some keeper_name ->
             Keeper_selection.Message_keeper
               { keeper_name; cursor = state.keeper_cursor;
                 return_keeper = state.keeper_message_return }
         | None -> Keeper_selection.List_cursor state.keeper_cursor)
    | Some Keeper_list
    (* The picker rides the list cursor: its own cursor points into the
       runtime catalogue, not the roster. *)
    | Some Keeper_runtime_pick
    | None ->
        Keeper_selection.List_cursor state.keeper_cursor
  in

  let keepers =
    match keepers_error, current_keeper_mode with
    | Some _, _ when state.detail_focus_recovery <> None ->
        (* A partial remote roster must not make cursor zero name a different
           Keeper while the withdrawn detail is waiting for its own name. *)
        []
    | Some _, Some (Keeper_detail | Keeper_logs | Keeper_calls
                   | Keeper_runtime_pick) when preserve_on_error ->
        (* A partial or failed read cannot prove that the focused Keeper was
           deleted. Keep the last complete roster until a reliable refresh can
           reconcile that identity. Message mode instead uses its explicit
           target and can render the unavailable state safely. *)
        state.keepers
    | Some _, Some (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_runtime_pick
                   | Keeper_list | Keeper_message) | Some _, None | None, _ ->
        loaded_keepers
  in
  state.keepers <- keepers;
  state.keepers_error <- keepers_error;

  let next_keeper_ids =
    List.map (fun keeper -> keeper.k_name) (keepers_for_selection state)
  in
  let hold_created_chat =
    match current_keeper_mode with
    | Some Keeper_message ->
        (match state.msg_target_keeper_name with
         | None -> false
         | Some target ->
             match keeper_creation_wait_for state target with
             | Some wait -> Option.is_some keepers_error
                 || not (Local_read_order.covers state.local_keeper_read_order wait.kcw_revision)
             | None -> false)
    | Some (Keeper_list | Keeper_detail | Keeper_logs | Keeper_calls | Keeper_runtime_pick)
    | None -> false
  in
  reconcile_identity_login_keepers state ~keeper_names:next_keeper_ids
    ~error:keepers_error;
  (* A roster change no longer dismisses an action notice: the notice answers
     the operator's last action, and a refresh tick would otherwise wipe it
     before it is read. User actions still clear it. *)
  if current_keeper_mode <> Some Keeper_message then
    state.keeper_message_return <- None;
  if state.detail_focus_recovery <> None && keepers_error <> None then ()
  else (match
     Keeper_selection.reconcile ~current_ids:current_keeper_ids
       ~next_ids:next_keeper_ids ~current:current_navigation
   with
   | Keeper_selection.List_cursor cursor ->
       state.detail_focus_recovery <- None;
       state.keeper_cursor <- cursor;
       (match current_keeper_mode with
        | Some Keeper_message when hold_created_chat -> ()
        | Some (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message) ->
            set_view (Keepers Keeper_list);
            state.detail_scroll <- 0;
            state.log_scroll <- 0;
            state.keeper_calls_scroll <- 0
        (* The picker rides the list cursor, so a reconciled cursor is not a
           lost focus: it stays open across refreshes. *)
        | Some Keeper_runtime_pick | Some Keeper_list | None -> ())
   | Keeper_selection.Detail_keeper { cursor; _ } ->
       state.keeper_cursor <- cursor;
       set_view (Keepers Keeper_detail)
   | Keeper_selection.Logs_keeper { cursor; _ } ->
       state.keeper_cursor <- cursor;
       set_view (Keepers Keeper_logs)
   | Keeper_selection.Calls_keeper { cursor; _ } ->
       state.keeper_cursor <- cursor;
       set_view (Keepers Keeper_calls)
   | Keeper_selection.Message_keeper { cursor; return_keeper; _ } ->
       state.keeper_cursor <- cursor;
       state.keeper_message_return <- return_keeper;
       set_view (Keepers Keeper_message));

  (* A partial roster may have clamped the cursor to another Keeper while a
     Skill image owned the terminal. Restore its captured owner on recovery. *)
  if Option.is_none keepers_error && state.workspace_identity=Workspace_identity_match then
    Option.iter (fun (keeper_name, _) ->
      List.find_index (String.equal keeper_name) next_keeper_ids
      |> Option.iter (fun cursor -> state.keeper_cursor <- cursor))
      (tools_skill_cell_image_owner state);

  let selected_keeper_name_after_refresh =
    Option.map (fun keeper -> keeper.k_name) (selected_keeper state)
  in
  if not (Option.equal String.equal selected_keeper_name selected_keeper_name_after_refresh)
  then clear_keeper_logs state

(** Immutable local work observation. Required Keeper metadata is a
    separate source, so task/archive work cannot gate chat availability. *)
type local_reading =
  { lr_rows : Masc_tui_overview_tasks.rows_reading
  ; lr_task_payloads : Masc_tui_task_payloads.t
  ; lr_tasks_error : string option
  ; lr_task_flow : Masc_tui_task_flow.t option
  ; lr_operator_stalled : Masc_tui_agenda.stalled Masc_tui_agenda.reading
  ; lr_goal_task_links : task_goal_links_reading
  ; lr_goals_to_confirm : Masc_tui_agenda.goal_to_confirm Masc_tui_agenda.reading
  }

(* Planning is constant-time and the opaque observation keeps raw source and
   stable values together. Full comparisons run only for a new producer list,
   after the actual I/O submission and cache lock have returned. *)
let prepare_local_workspace (request : local_workspace_request) (reading : local_reading) =
  match Masc_tui_task_payloads.prepare ~previous:request.lwr_previous_tasks reading.lr_task_payloads with
  | Immediate payloads ->
    Masc_tui_local_read_observation.observe request.lwr_observation (Comparison_decided Immediate);
    {reading with lr_task_payloads=payloads}
  | Compare comparison ->
    Masc_tui_local_read_observation.observe request.lwr_observation (Comparison_decided Compare);
    Masc_tui_local_read_observation.compare_tasks request.lwr_observation
      ~name:"local.work.task_payloads.reuse_wait" (fun () ->
        {reading with lr_task_payloads=Masc_tui_task_payloads.finish comparison})

type local_keeper_reading =
  { lkr_keepers : keeper list
  ; lkr_error : string option
  }

(* A returned worker can still report a source failure. Keep its useful partial
   payload, but do not let it settle the source's observation revision. Optional
   data that was not requested is not a failure; explicit read failures are. *)
let local_workspace_observed (reading : local_reading) =
  let rows_observed = match reading.lr_rows with
    | Masc_tui_overview_tasks.Rows_read _ -> true
    | Masc_tui_overview_tasks.Rows_unread | Masc_tui_overview_tasks.Rows_unavailable _ -> false in
  let agenda_observed = function
    | Masc_tui_agenda.Read_failed _ -> false
    | Masc_tui_agenda.Not_read | Masc_tui_agenda.Read _ -> true in
  let links_observed = match reading.lr_goal_task_links with
    | Goal_links_read_failed _ -> false
    | Goal_links_not_read | Goal_links_read _ -> true in
  rows_observed && Option.is_none reading.lr_tasks_error && links_observed
  && agenda_observed reading.lr_operator_stalled
  && agenda_observed reading.lr_goals_to_confirm

let local_keepers_observed (reading : local_keeper_reading) =
  Option.is_none reading.lkr_error

(* The metadata and archive caches have different resource owners. A work
   scan must not hold the metadata lock needed by input and saved chat opening. *)
let local_work_read_mutex = Eio.Mutex.create ()
let local_keeper_read_mutex = Eio.Mutex.create ()

(* Cache entries are replaced atomically, so a failed/cancelled scan leaves
   individually valid entries. Release the cache lock before propagating the
   exception: Eio's write helper otherwise poisons the source for every future
   read. Cancellation is re-raised with its backtrace, without retry or await. *)
let with_local_read_mutex mutex read =
  let outcome = Eio.Mutex.use_rw ~protect:false mutex (fun () ->
      try Ok (read ()) with
      | Eio.Cancel.Cancelled _ as exn -> Error (exn, Printexc.get_raw_backtrace ())
      | exn -> Error (exn, Printexc.get_raw_backtrace ())) in
  match outcome with
  | Ok reading -> reading
  | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace

let read_local_work_unlocked ~fresh (base_path : string) : local_reading =
  let rows, tasks_domain, tasks_error, task_flow, operator_stalled, goal_task_links =
    load_active_tasks ~fresh base_path
  in
  let goals_to_confirm = load_goals_to_confirm base_path in
  { lr_rows = rows; lr_task_payloads = Masc_tui_task_payloads.observe tasks_domain
  ; lr_tasks_error = tasks_error; lr_task_flow = task_flow
  ; lr_operator_stalled = operator_stalled; lr_goal_task_links = goal_task_links
  ; lr_goals_to_confirm = goals_to_confirm }

let read_local_workspace ?(fresh = false) base_path =
  with_local_read_mutex local_work_read_mutex
    (fun () ->
      if fresh then archive_seen := None;
      read_local_work_unlocked ~fresh base_path)

(* Whether the named Keeper's metadata file is not the one the last local
   read decoded: written since, created, or removed. The server announces a
   Keeper row change for a receipt, a candle or a rest move too, and those
   leave the file as it was, so the local list has nothing new to read. A
   file the last read could not decode is never remembered and always counts
   as moved. *)
let local_keeper_meta_moved base_path keeper_name =
  with_local_read_mutex local_keeper_read_mutex (fun () ->
      let config = Workspace_core.default_config base_path in
      let path =
        Filename.concat (Keeper_types_profile.keeper_dir config)
          (Keeper_runtime_root_entry.keeper_basename ~keeper_name
             Keeper_runtime_root_entry.Metadata)
      in
      match stat_opt path, Hashtbl.find_opt keeper_meta_cache path with
      | Some _ as stat, Some _ -> Option.is_none (cached_keeper_for path stat)
      | None, None -> false
      | Some _, None | None, Some _ -> true)

let read_local_keepers base_path =
  with_local_read_mutex local_keeper_read_mutex (fun () ->
      let lkr_keepers, lkr_error = load_keepers base_path in
      { lkr_keepers; lkr_error })

let apply_local_workspace (state : state) (reading : local_reading) =
  (* The domain rows land first: a detail view open across this refresh keeps
     its row even when the task just turned terminal, because the projection
     below drops exactly those. *)
  let rows = reading.lr_rows in
  state.task_payloads <- reading.lr_task_payloads;
  state.goal_task_links <- reading.lr_goal_task_links;
  state.task_reading <- rows;
  state.tasks <-
    (match rows with
     | Masc_tui_overview_tasks.Rows_read tasks -> tasks
     | Masc_tui_overview_tasks.Rows_unread
     | Masc_tui_overview_tasks.Rows_unavailable _ -> []);
  state.tasks_error <- reading.lr_tasks_error;
  (* A chosen task that left rows that were read (finished, or back to Todo)
     is dropped here, where the rows change, and said once. A failed read
     keeps the choice: it did not look, so nothing left. With that task's
     detail open the detail still shows it, so the footer says nothing that
     the screen contradicts. *)
  (let focus, left =
     Masc_tui_overview_tasks.after_read rows state.task_focus
   in
   state.task_focus <- focus;
   Option.iter
     (fun task_id ->
       if not (Option.equal String.equal state.task_detail_id (Some task_id))
       then
         report_action state "system"
           (Printf.sprintf "%s left the held tasks; nothing is chosen"
              task_id))
     left);
  state.task_flow <- reading.lr_task_flow;
  state.operator_stalled <- reading.lr_operator_stalled;
  state.goals_to_confirm <- reading.lr_goals_to_confirm;
  state.local_workspace <- Local_workspace_read

let apply_local_keepers ?before_view_change (state : state) (reading : local_keeper_reading) =
  replace_keeper_rows ?before_view_change ~preserve_on_error:true state ~keepers:reading.lkr_keepers
    ~error:reading.lkr_error;
  state.local_keepers <- Local_workspace_read

let clear_local_workspace ?(keep_keeper_rows = false) (state : state) =
  invalidate_local_source_read state Local_keepers;
  invalidate_local_source_read state Local_work;
  state.tasks <- [];
  state.task_payloads <- Masc_tui_task_payloads.empty;
  state.goal_task_links <- Goal_links_not_read;
  state.task_focus <- Masc_tui_overview_tasks.No_task_focus;
  state.task_reading <- Masc_tui_overview_tasks.Rows_unread;
  state.task_flow <- None;
  state.operator_stalled <- Masc_tui_agenda.Not_read;
  state.goals_to_confirm <- Masc_tui_agenda.Not_read;
  state.tasks_error <- None;
  if not keep_keeper_rows then begin
    state.keepers <- [];
    state.keepers_error <- None;
    state.keeper_cursor <- 0
  end;
  state.lanes_action_error <- None;
  clear_keeper_logs state;
  state.live_context <- Context_state.clear state.live_context;
  supersede_live_context_read state None;
  state.local_workspace <- Local_workspace_unread;
  state.local_keepers <- Local_workspace_unread
;;

(** HTTP JSON decoding helpers. These intentionally fail closed for the TUI
    dashboard surfaces: an empty list means the API really returned an empty
    list, not that a malformed payload was silently dropped. *)
let ( let* ) = Result.bind

let decode_workspace_health raw =
  match String.lowercase_ascii (String.trim raw) with
  | "critical" -> Ok Workspace_health_critical
  | "bad" -> Ok Workspace_health_bad
  | "risk" -> Ok Workspace_health_risk
  | "warn" | "warning" | "watch" -> Ok Workspace_health_warning
  | "degraded" | "interrupted" -> Ok Workspace_health_degraded
  | "initializing" -> Ok Workspace_health_initializing
  | "ok" | "good" | "healthy" -> Ok Workspace_health_ok
  | "unknown" -> Ok Workspace_health_unknown
  | other ->
      Error
        (Printf.sprintf
           "unknown workspace health %S (normalized %S)"
           raw
           other)

let decode_board_post ?(require_body = false) json =
  let* bp_id = Masc.Tui_decode_fields.required_string_field json "id" in
  let* bp_author = Masc.Tui_decode_fields.required_string_field json "author" in
  let* bp_title = Masc.Tui_decode_fields.required_string_field json "title" in
  let* bp_body =
    if require_body then required_body_field json else optional_body_field json
  in
  let* bp_votes = Masc.Tui_decode_fields.required_int_field json "votes" in
  let* bp_comment_count = Masc.Tui_decode_fields.required_int_field json "comment_count" in
  let* bp_created_at =
    required_display_any_field json [ "created_at_iso"; "created_at" ]
  in
  (* The numeric field, not its ISO twin: the list draws an age, and parsing a
     formatted timestamp back into one would be a second reading of the same
     fact. Absent reads as the creation time, which is what an untouched post's
     [updated_at] holds anyway -- so a server too old to send it degrades to
     "as old as it looks" rather than to a blank column. With neither there is
     no time at all, and it stays unknown: read as the epoch it drew a post
     from 1970, twenty thousand days old, folded to "2…d09h". *)
  let created_at_epoch =
    match Yojson.Safe.Util.member "created_at" json with
    | `Float value -> Some value
    | `Int value -> Some (Float.of_int value)
    | `Intlit raw -> float_of_string_opt raw
    | `String value -> float_of_string_opt value
    | _ -> None
  in
  let updated_at =
    match Yojson.Safe.Util.member "updated_at" json with
    | `Float value -> Some value
    | `Int value -> Some (Float.of_int value)
    | _ -> None
  in
  (* task-1758/#39356: [closed] is absent on an open post (or one minted
     before this field existed), an object on a closed one. Only closed_by
     is required inside it; closed_at/successor_id/summary each degrade to
     [None] independently rather than failing the whole post read, the same
     shape [decode_schedule_actor]'s nested reads already use elsewhere in
     this file. *)
  let* bp_closed =
    match Yojson.Safe.Util.member "closed" json with
    | `Null -> Ok None
    | `Assoc _ as nested ->
        let* bpc_closed_by = Masc.Tui_decode_fields.required_string_field nested "closed_by" in
        let* bpc_successor_id = Masc.Tui_decode_fields.optional_string_field nested "successor_id" in
        let* bpc_summary = Masc.Tui_decode_fields.optional_string_field nested "summary" in
        let bpc_closed_at =
          match Yojson.Safe.Util.member "closed_at" nested with
          | `Float value -> Some value
          | `Int value -> Some (Float.of_int value)
          | _ -> None
        in
        Ok (Some { bpc_closed_by; bpc_closed_at; bpc_successor_id; bpc_summary })
    | value ->
        Error
          (Printf.sprintf "board post closed must be an object or null: %s"
             (Yojson.Safe.to_string value))
  in
  let* bp_hearth = Masc.Tui_decode_fields.optional_string_field json "hearth" in
  let* raw_kind = Masc.Tui_decode_fields.optional_string_field json "post_kind" in
  (* Optional, and an unknown value is carried rather than rejected: the list
     is a projection for a pane, and a post whose kind this build does not know
     is still a post the operator should see. *)
  let bp_kind =
    match raw_kind with
    | Some "direct" -> Some Post_by_person
    | Some "automation" -> Some Post_by_automation
    | Some "system" -> Some Post_by_system
    | Some other -> Some (Post_kind_unknown other)
    | None -> None
  in
  (* Attachments decode per entry and can never fail the post: a broken
     entry is carried as its [Error], an unknown kind as [Ak_unknown]
     (spec decision 5 -- deliberately not the [bp_closed] shape above, where
     one malformed nested field fails the whole read). *)
  let bp_attachments = decode_board_attachments json in
  Ok
    {
      bp_id;
      bp_author;
      bp_title;
      bp_body;
      bp_votes;
      bp_comment_count;
      bp_created_at;
      bp_created_at_unix = created_at_epoch;
      bp_updated_at =
        (match updated_at with
         | Some _ -> updated_at
         | None -> created_at_epoch);
      bp_hearth;
      bp_kind;
      bp_closed;
      bp_attachments;
    }

(* The board's own hearth census: name and post count, over the whole board.
   Sorted busiest first here rather than trusted from the wire, so the pane's
   order is its own statement and not a property of whichever query answered.
   An entry missing either half is dropped -- a hearth with no name cannot be
   narrowed to, and one with no count cannot be weighed. *)
let decode_board_hearths json =
  match Yojson.Safe.Util.member "hearths" json with
  | `List items ->
      Ok
        (items
        |> List.filter_map (fun item ->
               match
                 ( Yojson.Safe.Util.member "name" item
                 , Yojson.Safe.Util.member "count" item )
               with
               | `String name, `Int count when String.trim name <> "" ->
                   Some (String.trim name, count)
               | _ -> None)
        |> List.sort (fun (left_name, left) (right_name, right) ->
               match Int.compare right left with
               | 0 -> String.compare left_name right_name
               | order -> order))
  | `Null -> Ok []
  | value ->
      Error
        (Printf.sprintf "board hearths must be a list: %s"
           (Yojson.Safe.to_string value))

let memo_board_hearths = json_memo ()

(** Load the hearth census from /api/v1/board/hearths. *)
let load_board_hearths ~(host : string) ~(port : int) :
    ((string * int) list, string) result =
  match fetch_board_hearths ~host ~port with
  | Error err -> Error ("board hearths load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_board_hearths ~name:"board.hearths.decode_wait"
        decode_board_hearths json

let decode_board_posts json_list =
  Masc.Tui_decode_fields.decode_list "posts" decode_board_post json_list

let decode_board_comment json =
  let* bc_id = Masc.Tui_decode_fields.required_string_field json "id" in
  (* Optional because a top-level comment has none, not because the field may
     be absent: the wire always carries the key and answers [null] there. *)
  let* bc_parent_id = Masc.Tui_decode_fields.optional_string_field json "parent_id" in
  let* bc_author = Masc.Tui_decode_fields.required_string_field json "author" in
  let* bc_content = Masc.Tui_decode_fields.required_string_field json "content" in
  let* bc_created_at =
    required_display_any_field json [ "created_at_iso"; "created_at" ]
  in
  (* Required, as a post's [votes] is: the server writes both counts on every
     comment, and a comment without them has no score to draw. *)
  let* bcv_up = Masc.Tui_decode_fields.required_int_field json "votes_up" in
  let* bcv_down = Masc.Tui_decode_fields.required_int_field json "votes_down" in
  Ok
    { bc_id; bc_parent_id; bc_author; bc_content; bc_created_at
    ; bc_votes = { bcv_up; bcv_down } }

let decode_board_comments json_list =
  Masc.Tui_decode_fields.decode_list "comments" decode_board_comment json_list

let memo_schedules = json_memo ()

let validate_schedule_page ~payload_target ~cursor snapshot =
  if not (Option.equal String.equal snapshot.scs_payload_target payload_target) then
    Error "schedule page belongs to a different target"
  else if Option.is_none snapshot.scs_request_count then
    Error (Option.value ~default:"schedule store unreadable" snapshot.scs_read_error)
  else match snapshot.scs_paging, cursor with
    | Schedule_paging_unavailable, None -> Ok snapshot
    | Schedule_paging_unavailable, Some _ -> Error "server did not return schedule paging metadata"
    | Schedule_paging { page_cursor; next_cursor = _ }, _ ->
        if Option.equal String.equal page_cursor cursor then Ok snapshot
        else Error "schedule page does not match the requested cursor"

(** Load one fleet page from /api/v1/dashboard/scheduled-automation. *)
let load_schedules ~(host : string) ~(port : int) ~(cursor : string option) :
    (schedule_snapshot, string) result =
  match fetch_schedules ~host ~port ~cursor with
  | Error err -> Error ("schedule load failed: " ^ err)
  | Ok json ->
      Result.bind
        (decode_offloaded memo_schedules ~name:"schedules.decode_wait"
           Masc_tui_schedule_decode.snapshot_of_json json)
        (validate_schedule_page ~payload_target:None ~cursor)

let memo_schedule_wake_history = json_memo ()

(** Load one schedule's wake history from the exact lookup. *)
let load_schedule_wake_history ~(host : string) ~(port : int)
    ~(schedule_id : string) : (schedule_wake_history, string) result =
  match fetch_schedule_detail ~host ~port ~schedule_id with
  | Error err -> Error ("schedule detail load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_schedule_wake_history
        ~name:"schedule.wake_history.decode_wait"
        Masc_tui_schedule_decode.wake_history_of_json json
let memo_schedules_for_target = json_memo ()

(** Load one target's schedules. Same envelope as the fleet page, so the same
    decoder reads it and the pane keeps its truncation reading. *)
let load_schedules_for_target ~(host : string) ~(port : int)
    ~(payload_target : string) ~(cursor : string option) : (schedule_snapshot, string) result =
  Result.bind
    (fetch_schedules_for_target ~host ~port ~payload_target ~cursor)
    (fun json ->
       Result.bind
         (decode_offloaded memo_schedules_for_target
            ~name:"schedules.target.decode_wait"
            Masc_tui_schedule_decode.snapshot_of_json json)
         (validate_schedule_page ~payload_target:(Some payload_target) ~cursor))

let memo_board_list = json_memo ()

(** Load board post list from /api/v1/board *)
let load_board_list ~(host : string) ~(port : int)
    ~(sort_by : string) ~(hearth : string option) :
    (board_post list, string) result =
  match fetch_board ~host ~port ~sort_by ~hearth with
  | Error err -> Error ("board load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_board_list ~name:"board.list.decode_wait"
        (fun json ->
          let* posts = Masc.Tui_decode_fields.required_list_field json "posts" in
          decode_board_posts posts)
        json

(** The ordinary Board read uses the newest twenty. The reader can request
    the complete history explicitly; that read walks bounded REST pages. *)
let load_board_post ?(full_history = false) ~(host : string) ~(port : int)
    ~(post_id : string) () : (board_post * board_comment list * string option, string) result =
  let read_page offset =
    let* json =
      Masc_tui_frame_timing.time_stage ~name:"board.http_json"
        (fun () ->
          match offset with
          | None -> fetch_board_post ~host ~port ~post_id ()
          | Some offset ->
              fetch_board_post ~comment_offset:offset
                ~comment_limit:Masc.Board.Limits.max_comment_page_limit
                ~host ~port ~post_id ())
    in
    Masc_tui_frame_timing.time_stage ~name:"board.model_decode"
      (fun () ->
        Masc_tui_response_decode.run ~name:"board.page.decode_wait" (fun () ->
          let* comments_json = Masc.Tui_decode_fields.required_list_field json
            (if full_history then "comments" else "comment_context") in
          let* comments = decode_board_comments comments_json in
          let* revision = Masc.Tui_decode_fields.required_string_field json "comment_revision" in
          let* () = if String.length revision=64 && String.for_all
              (function '0'..'9' | 'a'..'f' -> true | _ -> false) revision
            then Ok () else Error "board detail comment revision is malformed" in
          let* page = Masc.Tui_decode_fields.required_object_field json "comment_page" in
          let* actual_offset = Masc.Tui_decode_fields.required_int_field page "offset" in
          let* total = Masc.Tui_decode_fields.required_int_field page "total" in
          match offset with
          | Some expected when actual_offset <> expected ->
              Error "board detail returned a different comment offset"
          | None | Some _ -> Ok (json, comments, actual_offset, total, revision)))
  in
  let* (first_json, first_comments, first_offset, total, revision) =
    read_page (if full_history then Some 0 else None)
  in
  let post_json =
    match Yojson.Safe.Util.member "post" first_json with
    | `Null -> first_json
    | value -> value
  in
  let* post =
    Masc_tui_frame_timing.time_stage ~name:"board.model_decode"
      (fun () ->
        Masc_tui_response_decode.run ~name:"board.post.decode_wait" (fun () ->
          decode_board_post ~require_body:true post_json))
  in
  let rec read_remaining offset total reversed =
    if offset >= total then Ok (post, List.rev reversed, None)
    else
      let* (_, comments, _, page_total, page_revision) = read_page (Some offset) in
      let* () = if page_revision=revision && page_total=total then Ok ()
        else Error "Board comment thread changed during full history read; refresh to read one snapshot" in
      let next_offset = offset + List.length comments in
      if next_offset <= offset then
        Error "board detail comment page did not advance"
      else read_remaining next_offset total (List.rev_append comments reversed)
  in
  if full_history then
    read_remaining (first_offset + List.length first_comments) total
      (List.rev first_comments)
  else
    let* page_json = Masc.Tui_decode_fields.required_list_field first_json "comments" in
    let* page_comments = decode_board_comments page_json in
    let* () =
      if List.for_all (fun page_comment ->
          List.exists (fun context_comment ->
            String.equal page_comment.bc_id context_comment.bc_id) first_comments)
          page_comments then Ok ()
      else Error "Board comment context is missing a page comment"
    in
    let landing =
      if List.length first_comments = List.length page_comments then None
      else match List.rev page_comments with
        | [] -> None
        | comment :: _ -> Some comment.bc_id in
    Ok (post, first_comments, landing)

let memo_approvals = json_memo ()

(** Load the actor-scoped pending confirmation envelope from the operator
    surface. Missing or malformed envelopes remain explicit errors. *)
let load_approvals ~(host : string) ~(port : int) :
    (approval_snapshot, string) result =
  match fetch_operator_snapshot ~host ~port with
  | Error err -> Error ("approvals load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_approvals ~name:"approvals.decode_wait"
        Masc_tui_operator_projection.decode_snapshot json

let load_workspace_approvals ~(expected_workspace : Tui_decode.server_identity)
    ~(host : string) ~(port : int) : (approval_snapshot, string) result =
  let ( let* ) = Result.bind in
  let* json = fetch_operator_snapshot ~host ~port in
  Masc_tui_response_decode.run ~name:"approvals.workspace.decode_wait" (fun () ->
    Masc_tui_operator_projection.decode_workspace_snapshot
      ~expected_base_path:(Canonical_path.to_string expected_workspace.sid_base_path)
      ~expected_masc_root:(Canonical_path.to_string expected_workspace.sid_masc_root)
      json)

let memo_runtime_catalog = json_memo ()

(** Load the runtime catalogue, lanes, and keeper assignments for the picker. *)
let load_runtime_resolved ~(host : string) ~(port : int) :
    ( Tui_decode.runtime_option list
      * Tui_decode.runtime_resolved_lane list
      * Tui_decode.runtime_assignment list
      * string option,
      string )
    result =
  match fetch_runtime_resolved ~host ~port with
  | Error err -> Error ("runtime catalogue load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_runtime_catalog ~name:"runtime.catalog.decode_wait"
        (fun json ->
          Tui_decode.decode_runtime_resolved_full json
          |> Result.map (fun catalog ->
            let snapshot = catalog.Tui_decode.rrc_snapshot in
            snapshot.rrs_runtimes, snapshot.rrs_lanes, catalog.rrc_assignments, snapshot.rrs_default_route))
        json

let memo_runtime_quota = json_memo ()

(** One read of [/api/v1/runtime/resolved] for the Overview: runtime rows and
    provider usage share interpretation while keeping independent errors.
    A failed fetch fails both with one reason. *)
let load_overview_runtime_resolved ~(host : string) ~(port : int) :
    (Tui_decode.runtime_option list, string) result
    * (Masc.Tui_decode_usage.provider_usage_windows, string) result =
  match fetch_runtime_resolved ~host ~port with
  | Error err ->
      let reason = "runtime catalogue load failed: " ^ err in
      (Error reason, Error reason)
  | Ok json ->
      decode_offloaded memo_runtime_quota ~name:"runtime.quota.decode_wait"
        (fun json ->
          let observation = Tui_decode.decode_runtime_resolved_observation json in
          ( Result.map
              (fun catalog -> catalog.Tui_decode.rrc_snapshot.rrs_runtimes)
              observation.rro_catalog
          , observation.rro_usage ))
        json

let memo_keeper_usage = json_memo ()

let load_keeper_usage ~(host : string) ~(port : int) =
  match fetch_keeper_usage ~host ~port with
  | Error reason -> Error ("keeper usage load failed: " ^ reason)
  | Ok json ->
      decode_offloaded memo_keeper_usage ~name:"keeper.usage.decode_wait"
        Masc.Tui_decode_usage.decode_keeper_usage_window json

let memo_provider_history = json_memo ()

let load_provider_usage_history ~(host : string) ~(port : int) ~(days : int) =
  match fetch_provider_usage_history ~host ~port ~days with
  | Error reason -> Error ("provider usage history load failed: " ^ reason)
  | Ok json ->
      decode_offloaded memo_provider_history ~name:"provider.history.decode_wait"
        (fun json ->
        let cache_error =
          match Json_util.assoc_member_opt "cache" json with
          | Some cache ->
              (match Json_util.assoc_member_opt "last_error" cache with
               | Some (`String reason) -> Some reason
               | _ -> None)
          | None -> None
        in
        (match cache_error with
         | Some reason -> Error ("history read failed: " ^ reason)
         | None ->
        match Json_util.assoc_member_opt "state" json with
         | Some (`String "loading") ->
             Error "history is loading"
         | Some (`String "unavailable") ->
             (match Json_util.assoc_member_opt "reason" json with
              | Some (`String reason) -> Error reason
              | _ -> Error "history unavailable without a reason")
         | Some _ | None -> Masc.Tui_decode_usage.decode_provider_usage_history json))
        json

let memo_tool_series = json_memo ()

let load_tool_series ~(host : string) ~(port : int)
    ~(width : Masc.Tui_decode_tool_series.tool_series_width) ~(since_hours : int) =
  match fetch_tool_series ~host ~port ~width ~since_hours with
  | Error reason -> Error ("tool series load failed: " ^ reason)
  | Ok json ->
      decode_offloaded memo_tool_series ~name:"tool.series.decode_wait"
        Masc.Tui_decode_tool_series.decode_tool_series json

type runtime_surface_load = {
  rsl_resolved : Tui_decode.runtime_resolved_snapshot;
  rsl_probe : (Masc.Tui_decode_runtime_probe.runtime_probe_snapshot, string) result;
  rsl_evidence : (Masc_tui_runtime_evidence.t, string) result;
}

(** Load the Runtime operator surface from its identity projection, optional
    probe observation and operator history. The requests run together when an Eio switch is
    available. A resolved failure rejects the load; a probe failure remains an
    inner result so lane identity can still be drawn as unobserved. *)
let load_runtime_surface ~(host : string) ~(port : int) ~(force : bool) :
    (runtime_surface_load, string) result =
  let requests =
    [ (fun () -> fetch_runtime_probe ~host ~port ~force)
    ; (fun () -> fetch_runtime_resolved ~host ~port)
    ; (fun () -> Masc_tui_http.get_json ~host ~port ~path:"/api/v1/runtime/metrics")
    ]
  in
  let results =
    match Eio_context.get_switch_opt () with
    | Some _ -> Eio.Fiber.List.map ~max_fibers:3 (fun request -> request ()) requests
    | None -> List.map (fun request -> request ()) requests
  in
  match results with
  | [ _; Error detail; _ ] -> Error ("runtime resolved load failed: " ^ detail)
  | [ probe_result; Ok resolved_json; evidence_result ] ->
      Masc_tui_response_decode.run ~name:"runtime.surface.decode_wait" (fun () ->
        match Tui_decode.decode_runtime_resolved_snapshot resolved_json with
        | Error detail -> Error ("runtime resolved decode failed: " ^ detail)
        | Ok rsl_resolved ->
            let rsl_probe =
              match probe_result with
              | Error detail -> Error ("runtime probe load failed: " ^ detail)
              | Ok probe_json ->
                  (match Masc.Tui_decode_runtime_probe.decode_runtime_probe_snapshot probe_json with
                   | Ok probe -> Ok probe
                   | Error detail ->
                       Error ("runtime probe decode failed: " ^ detail))
            in
            let rsl_evidence = match evidence_result with
              | Ok json -> Masc_tui_runtime_evidence.decode json
              | Error _ -> Error "runtime history unavailable; check server support and operator access" in
            Ok { rsl_resolved; rsl_probe; rsl_evidence })
  | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ ->
      Error "runtime surface loader lost a projection read"

let memo_keeper_tool_approvals = json_memo ()

(** Load the tool calls keepers are holding, for the Approvals surface. *)
let load_keeper_tool_approvals ~(host : string) ~(port : int) :
    (Tui_decode.keeper_tool_approval list, string) result =
  match fetch_keeper_tool_approvals ~host ~port with
  | Error err -> Error ("tool approvals load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_keeper_tool_approvals
        ~name:"keeper.tool_approvals.decode_wait"
        Tui_decode.decode_keeper_tool_approvals json

let memo_keeper_turns = json_memo ()

(** Load which keepers are mid-turn right now (the "answering now" badge). *)
let load_keeper_turns ~(host : string) ~(port : int) ~preparation_details_for :
    (Tui_decode.keeper_turns_projection, string) result =
  let ( let* ) = Result.bind in
  let* json = fetch_keeper_turns ~host ~port ~preparation_details_for in
  decode_offloaded memo_keeper_turns ~name:"keeper.turns.decode_wait"
    Tui_decode.decode_keeper_turns_projection json

let memo_dashboard_gate = json_memo ()

(** Load the durable Gate: pending approvals and both lane modes. *)
let load_dashboard_gate ~(host : string) ~(port : int) :
    (Tui_decode.gate_snapshot, string) result =
  (* Both ways this read can fail carry the label. Only the transport half did,
     so a payload this build cannot decode reached the screen as "approval_queue
     is neither a list nor null" with nothing saying which read said it. 29 of
     the 47 reads in this file share that asymmetry -- #35573. *)
  Result.map_error
    (fun detail -> "gate load failed: " ^ detail)
    (Result.bind (fetch_dashboard_gate ~host ~port)
       (decode_offloaded memo_dashboard_gate ~name:"gate.decode_wait"
          Tui_decode.decode_gate_snapshot))

let memo_keeper_gate_settings = json_memo ()

(** Load the durable per-keeper Gate settings. *)
let load_keeper_gate_settings ~(host : string) ~(port : int) :
    ((string * Tui_decode.gate_mode) list * Tui_decode.keeper_exact_lane_first list, string) result =
  match fetch_keeper_gate_settings ~host ~port with
  | Error err -> Error ("keeper Gate settings load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_keeper_gate_settings
        ~name:"keeper.gate_settings.decode_wait"
        Tui_decode.decode_keeper_gate_settings json

let memo_runtime_params = json_memo ()

(** Load the Runtime_params registry rows. *)
let load_runtime_params ~(host : string) ~(port : int) :
    (Tui_decode.runtime_param_row list, string) result =
  match fetch_runtime_params ~host ~port with
  | Error err -> Error ("runtime params load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_runtime_params ~name:"runtime.params.decode_wait"
        Tui_decode.decode_runtime_params json

let memo_keeper_tool_approval_modes = json_memo ()

(** Load the keepers whose approval gate is moved off [auto]. *)
let load_keeper_tool_approval_modes ~(host : string) ~(port : int) :
    ((string * Masc.Keeper_tool_approval_mode.mode) list, string) result =
  match fetch_keeper_tool_approval_modes ~host ~port with
  | Error err -> Error ("tool approval modes load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_keeper_tool_approval_modes
        ~name:"keeper.tool_approval_modes.decode_wait"
        Tui_decode.decode_tool_approval_mode_overrides json

let memo_transport = json_memo ()

(** Load the delivery-path summary from /api/v1/dashboard/transport-health. *)
let load_transport_health ~(host : string) ~(port : int) :
    (Tui_decode.transport_health, string) result =
  match fetch_transport_health ~host ~port with
  | Error err -> Error ("transport health load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_transport ~name:"transport.decode_wait"
        Tui_decode.decode_transport_health json

let memo_account_emails = json_memo ()

(* Plan usage on Usage names each account's email. The route needs Admin,
   and a read that fails is said beside the section rather than drawn as
   accounts without an email. The section names the failure, so the reason is
   passed on as the transport gave it. *)
let load_account_emails ~(host : string) ~(port : int) :
    ((string * string) list * int, string) result =
  match Masc_tui_http.fetch_account_emails ~host ~port with
  | Error err -> Error err
  | Ok json ->
      decode_offloaded memo_account_emails ~name:"account.emails.decode_wait"
        Masc_tui_account_login.emails_of_document json

let memo_overview_goals = json_memo ()

(* The goal tree Work reads for exact measurement. A phase this build does not
   know refuses the whole reading: a goal dropped from the list, or shown under
   a phase it is not in, would answer "is work moving a goal" about a different
   fleet. *)
let load_overview_goals ~(host : string) ~(port : int) :
    (Tui_decode.overview_goal list, string) result =
  match Masc_tui_http.fetch_dashboard_goals ~host ~port with
  | Error err -> Error ("goals load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_overview_goals ~name:"overview.goals.decode_wait"
        (fun json ->
          Result.map_error Tui_decode.overview_goals_error_to_string
            (Tui_decode.decode_overview_goals json))
        json

let memo_overview = json_memo ()

(** The Home Health line as [GET /api/v1/dashboard/health-line] answers it.
    An answer that names an error is a failed read, said as the server said
    it. *)
let decode_health_line json : (overview_snapshot, string) result =
  let* error = Masc.Tui_decode_fields.optional_string_field json "error" in
  match error with
  | Some detail -> Error ("overview unavailable: " ^ detail)
  | None ->
      let* ov_keeper_listing =
        let* listing = Masc.Tui_decode_fields.required_object_field json "keepers_listing" in
        Keeper_snapshot_unread.listing_of_json listing
      in
      let* ov_workspace_health =
        let* workspace_health =
          Masc.Tui_decode_fields.required_string_field json "workspace_health"
        in
        decode_workspace_health workspace_health
      in
      let* ov_unreadable_keepers =
        Masc.Tui_decode_fields.required_nonnegative_int_field json "unreadable_keepers"
      in
      Ok { ov_workspace_health; ov_keeper_listing; ov_unreadable_keepers }

let load_overview ~(host : string) ~(port : int) :
    (overview_snapshot, string) result =
  match fetch_dashboard_health_line ~host ~port with
  | Error err -> Error ("overview load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_overview ~name:"overview.decode_wait" decode_health_line json

let memo_tools_inventory = json_memo ()

(** Load the registered tool inventory and, when selected, one Keeper's exact
    effective turn surface from /api/v1/dashboard/tools. *)
let load_tools ~(host : string) ~(port : int) ?keeper () :
    (Masc.Tui_decode_tools.tool_snapshot, string) result =
  match fetch_dashboard_tools ~host ~port ?keeper () with
  | Error err -> Error ("tool inventory load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_tools_inventory ~name:"tools.inventory.decode_wait"
        Masc.Tui_decode_tools.decode_tool_snapshot json

(** Load the selected Keeper's skill activations for the Activations pane.
    The decode checks the answer against [keeper], so it is not memoised by
    the answer alone. *)
let load_keeper_skill_activations ~(host : string) ~(port : int) ~(keeper : string) :
    (Masc.Tui_decode_tools.skill_activation_projection, string) result =
  match fetch_keeper_skill_activations ~host ~port ~keeper with
  | Error err -> Error ("skill activations load failed: " ^ err)
  | Ok json ->
      Masc_tui_response_decode.run ~name:"tools.activations.decode_wait" (fun () ->
        Masc.Tui_decode_tools.decode_keeper_skill_activations ~keeper json)

(** Load one Keeper's usage of the skill catalog for the Usage pane. The
    decode checks the answer against [keeper], so it is not memoised by the
    answer alone. *)
let load_keeper_skill_usage ~(host : string) ~(port : int) ~(keeper : string) :
    (Masc.Tui_decode_tools.keeper_skill_usage, string) result =
  match fetch_keeper_skill_usage ~host ~port ~keeper with
  | Error err -> Error ("skill usage load failed: " ^ err)
  | Ok json ->
      Masc_tui_response_decode.run ~name:"tools.usage.decode_wait" (fun () ->
        Masc.Tui_decode_tools.decode_keeper_skill_usage ~keeper json)

let memo_skills_catalog = json_memo ()

(** Load the workspace skills catalog for the Tools screen tracking views. *)
let load_skills_catalog ~(host : string) ~(port : int) :
    (Masc.Tui_decode_tools.skills_catalog, string) result =
  Result.bind (fetch_skills_catalog ~host ~port) (fun json ->
    decode_offloaded memo_skills_catalog ~name:"skills.catalog.decode_wait"
      Masc.Tui_decode_tools.decode_skills_catalog json)

let memo_connectors_snapshot = json_memo ()
let memo_connectors_names = json_memo ()

(** Load connector status from /api/v1/gate/connectors *)
let load_connectors ~(host : string) ~(port : int) ~on_status :
    (Masc.Tui_decode_connectors.connector_snapshot, string) result =
  match fetch_connectors ~host ~port with
  | Error err -> Error err
  | Ok json ->
      (match decode_offloaded memo_connectors_snapshot ~name:"connectors.snapshot.decode_wait"
         Masc.Tui_decode_connectors.decode_connector_snapshot json with
       | Error _ as error -> error
       | Ok snapshot ->
           (* Publish useful status/bindings before optional names, on the
              original read fiber and under its workspace/receipt scope. *)
           on_status snapshot;
           let load_pages connector kind =
             let label = match kind with
               | Masc.Tui_decode_connectors.Connector_server_name -> "server"
               | Masc.Tui_decode_connectors.Connector_channel_name -> "channel"
               | Masc.Tui_decode_connectors.Connector_person_name -> "person"
             in
             let rec loop after_id pages =
               match
                 Masc_tui_http.fetch_connector_names ~host ~port
                   ~connector:connector.Masc.Tui_decode_connectors.cn_id ~kind:label ?after_id ()
               with
               | Error detail ->
                 List.rev pages, Some (label ^ ": " ^ detail)
               | Ok json ->
                 (match decode_offloaded memo_connectors_names ~name:"connectors.names.decode_wait"
                    Masc.Tui_decode_connectors.decode_connector_name_page json with
                  | Error detail ->
                    List.rev pages, Some (label ^ ": " ^ detail)
                  | Ok page ->
                    let count = List.length page.cnp_mappings in
                    if not (String.equal page.cnp_connector_id connector.cn_id) then
                      ( List.rev pages
                      , Some (label ^ ": directory connector response mismatch") )
                    else if page.cnp_kind <> kind then
                      ( List.rev pages
                      , Some (label ^ ": directory kind response mismatch") )
                    else if page.cnp_after_id <> after_id then
                      ( List.rev pages
                      , Some (label ^ ": directory cursor response mismatch") )
                    else if page.cnp_total < count then
                      ( List.rev pages
                      , Some (label ^ ": directory page count exceeds total") )
                    else if page.cnp_has_more && count = 0 then
                      ( List.rev (page :: pages)
                      , Some (label ^ ": directory pagination made no progress") )
                    else if page.cnp_has_more then
                      (match page.cnp_next_after_id with
                       | None ->
                         ( List.rev (page :: pages)
                         , Some (label ^ ": directory page has no next cursor") )
                       | Some next_after
                         when (match after_id with
                               | Some previous ->
                                 String.compare next_after previous <= 0
                               | None -> false) ->
                         ( List.rev (page :: pages)
                         , Some
                             (label ^ ": directory cursor did not advance") )
                       | Some next_after ->
                         loop (Some next_after) (page :: pages))
                    else List.rev (page :: pages), None)
             in
             loop None []
           in
           let connectors =
             read_map
               (fun connector ->
                  let directory_results =
                    read_map (load_pages connector)
                      [ Masc.Tui_decode_connectors.Connector_server_name
                      ; Masc.Tui_decode_connectors.Connector_channel_name
                      ; Masc.Tui_decode_connectors.Connector_person_name
                      ]
                  in
                  let pages =
                    directory_results
                    |> List.map fst
                    |> List.flatten
                  in
                  let read_problems =
                    List.filter_map snd directory_results
                  in
                  Masc_tui_response_decode.run ~name:"connectors.names.project_wait" (fun () ->
                    Masc.Tui_decode_connectors.connector_with_name_pages connector ~pages
                      ~error:
                        (match read_problems with
                         | [] -> None
                         | problems -> Some (String.concat "; " problems))))
               snapshot.cs_connectors
           in
           Ok { snapshot with cs_connectors = connectors })

(** Load one Keeper's execution row and secret projection from
    /api/v1/keepers/<name>/composite. Info and Secrets read different parts
    of the same body. *)
let load_keeper_composite ~(host : string) ~(port : int) ~(keeper_name : string) :
    (Tui_decode.keeper_lane * Tui_decode.keeper_secret_projection option, string)
    result =
  match fetch_keeper_composite ~host ~port ~keeper_name with
  | Error err -> Error ("keeper composite load failed: " ^ err)
  | Ok json -> Tui_decode.decode_keeper_composite json

let memo_lane_inventory = json_memo ()

(** Load the common Lane inventory independently from Keeper lane rows so a
    failure on either observation does not erase the last good other one. *)
let load_lane_inventory ~(host : string) ~(port : int) :
    (Masc.Tui_decode_lane_inventory.snapshot, string) result =
  match fetch_lane_inventory ~host ~port with
  | Error err -> Error err
  | Ok json ->
      decode_offloaded memo_lane_inventory ~name:"lane.inventory.decode_wait"
        Masc.Tui_decode_lane_inventory.decode json

let memo_clients = json_memo ()

(** Load the clients roster from /api/v1/dashboard/clients *)
let load_clients ~(host : string) ~(port : int) :
    (Tui_decode.clients_snapshot, string) result =
  match fetch_clients ~host ~port with
  | Error err -> Error ("clients load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_clients ~name:"clients.decode_wait"
        Tui_decode.decode_clients_snapshot json

let memo_repositories = json_memo ()

(** Load the repository list from /api/v1/repositories *)
let load_repositories ~(host : string) ~(port : int) :
    (Tui_decode.repository_snapshot, string) result =
  match fetch_repositories ~host ~port with
  | Error err -> Error ("repository load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_repositories ~name:"repository.decode_wait"
        Tui_decode.decode_repository_snapshot json

let memo_repository_changes = json_memo ()

(** Load one repository's current Git working-tree changes. *)
let load_repository_changes ~(host : string) ~(port : int)
    ~(repository_id : string) :
    (Tui_decode.repository_change_snapshot, string) result =
  match fetch_repository_changes ~host ~port ~repository_id with
  | Error err -> Error ("repository changes load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_repository_changes
        ~name:"repository.changes.decode_wait"
        Tui_decode.decode_repository_change_snapshot json

let memo_memory_health = json_memo ()

let load_memory_health ~(host : string) ~(port : int) :
    (Masc.Tui_decode_memory_health.memory_health_snapshot, string) result =
  match fetch_keeper_memory_health ~host ~port with
  | Error err -> Error ("memory health load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_memory_health ~name:"memory.health.decode_wait"
        Masc.Tui_decode_memory_health.decode_memory_health_snapshot json

(** One Keeper's memory health row (RFC-0487). *)
let load_memory_health_row ~(host : string) ~(port : int) ~(keeper : string) :
    (Masc.Tui_decode_memory_health.memory_health_row_answer, string) result =
  match fetch_keeper_memory_health_row ~host ~port ~keeper with
  | Error err -> Error ("memory health row load failed: " ^ err)
  | Ok json -> Masc.Tui_decode_memory_health.decode_memory_health_row ~keeper json

(** The workspace memory world (RFC-0511 D2c). The answer is one small object,
    so it is decoded where it is read and not handed to the decode domain. A
    failure goes up as the text it was built with: the world line draws it
    after "read failed", where a prefix naming the read would repeat the
    line's own label. *)
let load_memory_world ~(host : string) ~(port : int) :
    (Masc.Tui_decode_workspace_memory.inventory, string) result =
  Result.bind
    (fetch_workspace_memory_inventory ~host ~port)
    Masc.Tui_decode_workspace_memory.decode_inventory

let memo_memory_facts = json_memo ()

(** One shared reading for the browser and its Story preview. *)
let load_memory_facts ~(host : string) ~(port : int) ~(keeper_name : string) :
    (Masc.Tui_decode_memory_facts.memory_fact_snapshot, string) result =
  match fetch_keeper_memory_facts ~host ~port ~keeper_name with
  | Error reason -> Error ("memory facts load failed: " ^ reason)
  | Ok json ->
    match decode_offloaded memo_memory_facts ~name:"memory.facts.decode_wait"
        Masc.Tui_decode_memory_facts.decode_memory_fact_snapshot json with
    | Error reason -> Error reason
    | Ok facts when facts.mfs_keeper <> keeper_name -> Error "memory facts Keeper mismatch"
    | Ok facts ->
      let partial = match Json_util.require_int json "events_unreadable_lines" with
        | Ok 0 -> None
        | Ok count -> Some (Printf.sprintf "%d unreadable retrieval event lines" count)
        | Error reason -> Some reason in
      let mfs_events_read_error = match facts.mfs_events_read_error, partial with
        | None, partial -> partial
        | Some reason, None -> Some reason
        | Some reason, Some partial -> Some (reason ^ "; " ^ partial) in
      Ok { facts with mfs_events_read_error }

let memo_project_changes = json_memo ()

(** Load the current project's Git working-tree changes. *)
let load_project_changes ~(host : string) ~(port : int) :
    (Tui_decode.repository_change_snapshot, string) result =
  match fetch_project_changes ~host ~port with
  | Error err -> Error ("project changes load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_project_changes ~name:"project.changes.decode_wait"
        Tui_decode.decode_repository_change_snapshot json

(** Load a keeper's file changes from /api/v1/keepers/:name/file-changes. *)
let load_keeper_file_changes ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(window_hours : float) :
    (Tui_decode.file_change_snapshot, string) result =
  match fetch_keeper_file_changes ~host ~port ~keeper_name ~window_hours with
  | Error err -> Error ("file change load failed: " ^ err)
  | Ok snapshot -> Ok snapshot

(** Load what the working tree holds for one file, from /api/v1/git/diff. *)
let load_git_diff ?repo ~(host : string) ~(port : int)
    ~(keeper : string option) ~(path : string) ~(against : git_diff_against) () :
    (Tui_decode.git_diff, string) result =
  match fetch_git_diff ?repo ~host ~port ~keeper ~path ~against () with
  | Error err -> Error ("git diff load failed: " ^ err)
  | Ok diff -> Ok diff

let memo_harness = json_memo ()

(** Load the harness snapshot from /api/v1/dashboard/harness-health *)
let load_harness ~(host : string) ~(port : int) :
    (Tui_decode.harness_snapshot, string) result =
  match fetch_harness_health ~host ~port with
  | Error err -> Error ("harness load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_harness ~name:"harness.decode_wait"
        Tui_decode.decode_harness_snapshot json

let memo_fusion_runs = json_memo ()

(** Load the retained Fusion registry list. *)
let load_fusion_runs ~(host : string) ~(port : int) :
    (Masc.Tui_decode_fusion.fusion_snapshot, string) result =
  match fetch_fusion_runs ~host ~port with
  | Error err -> Error ("fusion runs load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_fusion_runs ~name:"fusion.runs.decode_wait"
        Masc.Tui_decode_fusion.decode_fusion_snapshot json

(** Load one exact Fusion run/evidence projection. *)
let load_fusion_historical_detail ~(host : string) ~(port : int) ~reference =
  match fetch_board_post ~host ~port ~post_id:reference.Masc.Tui_decode_fusion.fhe_post_id () with
  | Error err -> Error ("Fusion Board original load failed: " ^ err)
  | Ok json ->
      Masc_tui_response_decode.run ~name:"fusion.historical_detail.decode_wait" (fun () ->
        Masc.Tui_decode_fusion.decode_fusion_historical_detail ~reference json)

let memo_fusion_detail = json_memo ()

let load_fusion_detail ~(host : string) ~(port : int) ~(run_id : string) :
    (Masc.Tui_decode_fusion.fusion_detail, string) result =
  match fetch_fusion_detail ~host ~port ~run_id with
  | Error err -> Error ("fusion detail load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_fusion_detail ~name:"fusion.detail.decode_wait"
        Masc.Tui_decode_fusion.decode_fusion_detail json

let memo_fusion_launch_options = json_memo ()

(** Read what the launch form offers. *)
let load_fusion_launch_options ~(host : string) ~(port : int) :
    (Masc.Tui_decode_fusion.fusion_launch_options, string) result =
  match fetch_fusion_config ~host ~port with
  | Error err -> Error ("fusion presets load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_fusion_launch_options
        ~name:"fusion.launch_options.decode_wait"
        Masc.Tui_decode_fusion.decode_fusion_launch_options json

(** Read which Keepers the memory recall judgment reaches now. A server older
    than the route answers 404, which comes back as the error. *)
let load_memory_recall_standing ~(host : string) ~(port : int) :
    (Masc.Tui_decode_memory_recall.memory_recall_reading, string) result =
  match fetch_memory_recall_standing ~host ~port with
  | Error err -> Error ("memory recall standing load failed: " ^ err)
  | Ok json -> Masc.Tui_decode_memory_recall.decode_memory_recall_reading json

(** Start a Fusion run and read back its run id. A refusal is the server's
    sentence; an unanswered request says so, because the run may have
    started and the list is the place to look. *)
let launch_fusion_run ~(host : string) ~(port : int)
    ~(request : Masc_tui_fusion_launch.request) : (string, string) result =
  match
    post_fusion_launch ~host ~port ~keeper:request.Masc_tui_fusion_launch.keeper
      ~body:(Masc_tui_fusion_launch.request_body request)
  with
  | Post_answered json ->
      Masc_tui_response_decode.run ~name:"fusion.launch_receipt.decode_wait" (fun () ->
        Masc.Tui_decode_fusion.decode_fusion_launch_receipt json)
  | Post_refused detail -> Error detail
  | Post_unanswered detail ->
      Error ("fusion launch unanswered: " ^ detail ^ "; the run may have started, r refreshes the list")

let memo_verification = json_memo ()

(** Load one page of one view from /api/v1/verification/requests *)
let load_verification ~(host : string) ~(port : int) ~(limit : int)
    ~(view : Tui_decode.verification_view) ~(offset : int) :
    (Tui_decode.verification_snapshot, string) result =
  match fetch_verification_requests ~host ~port ~limit ~view ~offset with
  | Error err -> Error ("verification load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_verification ~name:"verification.decode_wait"
        Tui_decode.decode_verification_snapshot json

let memo_planning = json_memo ()

(** Load planning snapshot from /api/v1/dashboard/planning *)
let load_planning ~(host : string) ~(port : int) :
    (planning_snapshot, string) result =
  match fetch_dashboard_planning ~host ~port with
  | Error err -> Error ("planning load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_planning ~name:"planning.decode_wait"
        Tui_decode.decode_planning_snapshot json

let memo_server_identity = json_memo ()

(* Which server this is. [/health] is the compact probe, and the caller asks on
   every refresh because another process may bind the same endpoint without a
   failed request reaching this TUI. *)
let load_server_identity ~(host : string) ~(port : int) :
    (Tui_decode.server_identity, string) result =
  match fetch_server_identity ~host ~port with
  | Error err -> Error ("server identity load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_server_identity ~name:"server.identity.decode_wait"
        Tui_decode.decode_server_identity json

let memo_prompts = json_memo ()

(** Load the prompt registry from /api/v1/prompts. *)
let load_prompts ~(host : string) ~(port : int) :
    (Tui_decode.prompts_snapshot, string) result =
  match fetch_prompts ~host ~port with
  | Error err -> Error ("prompts load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_prompts ~name:"prompts.decode_wait"
        Tui_decode.decode_prompts json

let memo_presets = json_memo ()

(** The prompt presets from /api/v1/presets. *)
let load_presets ~(host : string) ~(port : int) :
    (Tui_decode.presets_snapshot, string) result =
  match Masc_tui_http.fetch_presets ~host ~port with
  | Error err -> Error ("presets load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_presets ~name:"presets.decode_wait"
        Tui_decode.decode_presets json

let memo_preset_detail = json_memo ()

(** GET /api/v1/presets/show — what the named preset holds. *)
let load_preset_detail ~(host : string) ~(port : int) ~(name : string)
  : (Tui_decode.preset_detail, string) result
  =
  match Masc_tui_http.fetch_preset_detail ~host ~port ~name with
  | Error err -> Error ("preset detail load failed: " ^ err)
  | Ok json ->
      decode_offloaded memo_preset_detail ~name:"preset.detail.decode_wait"
        Tui_decode.decode_preset_detail json
;;

(** POST /api/v1/presets — the manifest the server wrote. *)
let save_preset ~(host : string) ~(port : int) ~(name : string) ~(description : string)
    ~expected_workspace ~before_dispatch ~after_auth_refused
    : (Tui_decode.preset_manifest, preset_save_failure) result =
  match Masc_tui_http.post_preset_save ~host ~port ~name ~description ~expected_workspace
          ~before_dispatch ~after_auth_refused with
  | Error failure -> Error failure
  | Ok (Post_refused detail) -> Error (Preset_save_refused detail)
  | Ok (Post_unanswered detail) -> Error (Preset_save_unconfirmed detail)
  | Ok (Post_answered json) ->
      Masc_tui_response_decode.run ~name:"preset.save.decode_wait" (fun () ->
        match Tui_decode.decode_preset_saved json with
        | Ok manifest when String.equal manifest.Tui_decode.pm_name (String.trim name) -> Ok manifest
        | Ok _ -> Error (Preset_save_unconfirmed "Preset save receipt names a different preset")
        | Error detail -> Error (Preset_save_unconfirmed detail))

(** POST /api/v1/presets/restore — the per-surface report. A transport
    failure leaves the outcome unknown: the server writes an autosave and
    three surfaces, and it may have finished after the client gave up, so the
    operator is told to read the preset list rather than to retry. *)
let restore_preset ~(host : string) ~(port : int) ~(name : string)
    : (Tui_decode.preset_restore_report, string) result =
  let unconfirmed message =
    Error
      ("preset restore result unconfirmed — changes may already be applied; \
        inspect current settings and _autosave before restoring again, which \
        replaces the undo snapshot: " ^ message)
  in
  match Masc_tui_http.post_preset_restore ~host ~port ~name with
  | Error (`Unknown_outcome message) -> unconfirmed message
  | Ok json ->
      Masc_tui_response_decode.run ~name:"preset.restore.decode_wait" (fun () ->
        match Tui_decode.decode_preset_restore json with
        | Ok report -> Ok report
        | Error detail -> unconfirmed detail)

(** POST /api/v1/presets/delete — the name the server removed. An unanswered
    request may still have removed it, so the operator is told to read the
    list before trying again. *)
let delete_preset ~(host : string) ~(port : int) ~(name : string) : (string, string) result =
  match Masc_tui_http.post_preset_delete ~host ~port ~name with
  | Post_answered json ->
      Masc_tui_response_decode.run ~name:"preset.delete.decode_wait" (fun () ->
        Tui_decode.decode_preset_deleted json)
  | Post_refused detail -> Error ("preset delete refused: " ^ detail)
  | Post_unanswered detail ->
    Error
      ("preset delete unanswered — the preset may be gone; \
        check the preset list before retrying: " ^ detail)

(** Load the live keeper roster. Truncation is carried into the typed roster
    rather than dropped: a clamped list cannot answer whether a keeper the TUI
    knows from disk has a running fiber, and the lifecycle actions depend on
    that answer. The read goes past the server's list cache, so a whole
    roster is never older than a row the TUI read before it (RFC-0481
    §3.3). *)
let load_keeper_roster ~(host : string) ~(port : int) ~expected_workspace :
    (Masc_tui_keeper_control.roster * (Tui_decode.candle_reading, string) result, Masc_tui_keeper_control.roster_failure)
    result =
  match fetch_keeper_runtimes ~host ~port ~expected_workspace with
  | Error transport ->
      Error (Masc_tui_keeper_control.Roster_unreachable transport)
  | Ok (status, body) when not (Tui_decode.is_success_http_status status) ->
      Error (Masc_tui_keeper_control.roster_failure_of_status ~status ~body)
  | Ok (_, body) ->
      Masc_tui_response_decode.run ~name:"keeper.roster.decode_wait" (fun () ->
        match Yojson.Safe.from_string body with
        | exception Yojson.Json_error detail ->
            Error (Masc_tui_keeper_control.Roster_malformed detail)
        | json -> (
            match Tui_decode.decode_keeper_runtime_list json with
            | Error detail ->
                Error (Masc_tui_keeper_control.Roster_malformed detail)
            | Ok (rows, errors, truncated, total, candle) ->
                Ok (Masc_tui_keeper_control.roster_of_reading ~errors ~rows ~truncated ~total, candle)))

(** Load one Keeper's roster row (RFC-0481 §3.1). The answer must name the
    Keeper it was asked for, so it cannot be read as a whole roster. *)
let load_keeper_row ~(host : string) ~(port : int) ~expected_workspace ~keeper_name :
    (Masc_tui_keeper_control.row_reading * (Tui_decode.candle_reading, string) result,
     Masc_tui_keeper_control.roster_failure)
    result =
  match fetch_keeper_runtime ~host ~port ~expected_workspace ~keeper_name with
  | Error transport ->
      Error (Masc_tui_keeper_control.Roster_unreachable transport)
  | Ok (status, body) when not (Tui_decode.is_success_http_status status) ->
      Error (Masc_tui_keeper_control.roster_failure_of_status ~status ~body)
  | Ok (_, body) ->
      Masc_tui_response_decode.run ~name:"keeper.row.decode_wait" (fun () ->
        match Yojson.Safe.from_string body with
        | exception Yojson.Json_error detail ->
            Error (Masc_tui_keeper_control.Roster_malformed detail)
        | json -> (
            match Yojson.Safe.Util.member "name" json with
            | `String named when String.equal named keeper_name -> (
                match Tui_decode.decode_keeper_runtime_list json with
                | Error detail ->
                    Error (Masc_tui_keeper_control.Roster_malformed detail)
                | Ok (rows, errors, _truncated, _total, candle) -> (
                    match Masc_tui_keeper_control.row_reading_of_reading ~keeper_name ~rows ~errors with
                    | Ok reading -> Ok (reading, candle)
                    | Error detail -> Error (Masc_tui_keeper_control.Roster_malformed detail)))
            | named ->
                Error (Masc_tui_keeper_control.Roster_malformed
                         (Printf.sprintf "the row read for %s named %s" keeper_name
                            (Yojson.Safe.to_string named)))
            | exception Yojson.Safe.Util.Type_error (detail, _) ->
                Error (Masc_tui_keeper_control.Roster_malformed detail)))

let load_keeper_config_view ~(host : string) ~(port : int)
    ~(keeper_name : string) : (string list, string) result =
  match
    Masc_tui_http.fetch_keeper_config_snapshot ~host ~port ~keeper_name
  with
  | Error err -> Error ("keeper config load failed: " ^ err)
  | Ok json ->
    (* The pane is formatted in one place. Sanitizing happens per fetched
       value there rather than per finished line here: the frame carries the
       styling that says which rows [e] reaches, and a line-level sanitizer
       would escape it along with the data. *)
    Ok
      (Masc_tui_keeper_config.view_lines
         ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text json)

let load_keeper_sandbox_view ~(host : string) ~(port : int)
    ~(keeper_name : string) : (Masc_tui_keeper_sandbox.t, string) result =
  match
    Masc_tui_http.fetch_keeper_status_snapshot ~host ~port ~keeper_name
  with
  | Error err -> Error err
  | Ok json ->
    Masc_tui_keeper_sandbox.decode_for_keeper ~keeper_name
      ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text
      json

let load_keeper_sandbox_name ~(host : string) ~(port : int)
    ~(keeper_name : string) : (Masc_tui_keeper_sandbox.name_report, string) result =
  match Masc_tui_http.fetch_keeper_kata_name_snapshot ~host ~port ~keeper_name with
  | Error err -> Error err
  | Ok json -> Masc_tui_keeper_sandbox.decode_name
      ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text ~keeper_name json

let load_keeper_sandbox_logs ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(tail : int) :
    (Masc_tui_keeper_sandbox.logs, string) result =
  match
    Masc_tui_http.fetch_keeper_sandbox_logs ~host ~port ~keeper_name ~tail
  with
  | Error err -> Error ("keeper sandbox logs load failed: " ^ err)
  | Ok json ->
    Masc_tui_keeper_sandbox.decode_logs
      ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text json

let memo_settings_editor_toml = json_memo ()
let memo_settings_editor_json = json_memo ()

let load_keeper_config_editor ~(host : string) ~(port : int)
    ~(keeper_name : string) ~format : (Yojson.Safe.t * string, string) result =
  match
    Masc_tui_http.fetch_keeper_config_snapshot ~host ~port ~keeper_name
  with
  | Error err -> Error ("keeper config load failed: " ^ err)
  | Ok json ->
      let memo = match format with
        | Masc_tui_keeper_config.Toml -> memo_settings_editor_toml
        | Masc_tui_keeper_config.Json -> memo_settings_editor_json in
      decode_offloaded memo ~name:"keeper.settings_editor.decode_wait"
        (fun json -> Result.map (fun stem -> json, stem)
          (Masc_tui_keeper_config.editor_document ~format json))
        json

let load_keeper_github_identity_view ~(host : string) ~(port : int)
    ~(keeper_name : string) : (string list, string) result =
  match
    Masc_tui_http.fetch_keeper_github_identity ~host ~port ~keeper_name
  with
  | Error err -> Error ("github identity load failed: " ^ err)
  | Ok json ->
    Ok
      (Masc_tui_github_identity.view_lines
         ~sanitize:Masc.Tui_terminal_text.sanitize_terminal_text json)

let memo_keeper_board_quarantines = json_memo ()

let load_keeper_board_quarantines ~(host : string) ~(port : int)
    ~(keeper_name : string) :
    (Masc_tui_board_quarantine.t, string) result =
  match Masc_tui_http.fetch_keeper_board_quarantines ~host ~port ~keeper_name with
  | Error err -> Error ("board quarantines: " ^ err)
  | Ok json ->
      decode_offloaded memo_keeper_board_quarantines
        ~name:"board.quarantine.decode_wait"
        Masc_tui_board_quarantine.decode json

(* What a Keeper can be attached to, and what each of those currently offers
   it. One fetch rather than two: a list of providers and a list of
   attachments cannot disagree if they arrive together. *)
let load_identity_providers ~(host : string) ~(port : int) ~(keeper_name : string) =
  match Masc_tui_http.fetch_attached_tools ~host ~port ~keeper_name with
  | Error err -> Error ("identity providers load failed: " ^ err)
  | Ok json -> Masc_tui_identity_model.decode_identity_providers json

let load_runtime_config_view ~(host : string) ~(port : int) :
    (Masc_tui_runtime_config_view.reading, string) result =
  match Masc_tui_http.fetch_runtime_config_raw ~host ~port with
  | Error err -> Error ("fetch: " ^ err)
  | Ok json ->
      match Masc_tui_runtime_config_view.decode_source json with
      | Error detail -> Error ("decode: " ^ detail)
      | Ok reading -> Ok reading


let memo_config_snapshot = json_memo ()

(* Only the Config observation needs these full source/model projections.
   Specialized activity readers keep their existing document-only read. *)
let load_runtime_config_snapshot ~(host : string) ~(port : int) :
    (Masc_tui_runtime_config_snapshot.t, string) result =
  match Masc_tui_http.fetch_runtime_config_raw ~host ~port with
  | Error detail -> Error ("fetch: " ^ detail)
  | Ok json ->
      decode_offloaded memo_config_snapshot ~name:"runtime.config_snapshot.decode_wait"
        (fun json ->
          Masc_tui_runtime_config_view.decode json
          |> Result.map_error (fun detail -> "decode: " ^ detail)
          |> Result.map Masc_tui_runtime_config_snapshot.of_reading)
        json
