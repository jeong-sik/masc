(** TUI data loading functions — split from masc_tui.ml (#3808) *)

module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_types_support = Masc.Keeper_types_support
module Keeper_types_profile = Masc.Keeper_types_profile
module Keeper_runtime_root_entry = Masc.Keeper_runtime_root_entry
module Keeper_selection = Masc_tui_keeper_selection
module Context_state = Masc_tui_context_state
module Metrics_tail = Masc_tui_metrics_tail
module Render_schedule = Masc_tui_render_schedule

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

let cached_keeper_for name stat =
  match stat, Hashtbl.find_opt keeper_meta_cache name with
  | Some (st : Unix.stats), Some entry
    when st.Unix.st_mtime = entry.cached_mtime
         && st.Unix.st_size = entry.cached_size ->
      Some entry.cached_keeper
  | (Some _ | None), (Some _ | None) -> None

let remember_keeper name stat keeper =
  match stat with
  | None -> ()
  | Some (st : Unix.stats) ->
      Hashtbl.replace keeper_meta_cache name
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
      (* A keeper that is gone keeps nothing behind it. *)
      Hashtbl.filter_map_inplace
        (fun name entry -> if List.mem name names then Some entry else None)
        keeper_meta_cache;
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
      let keepers, errors =
        List.fold_left
          (fun (keepers, errors) name ->
             let path = meta_path name in
             let stat = stat_opt path in
             match cached_keeper_for name stat with
             | Some keeper -> keeper :: keepers, errors
             | None -> (
                 match Keeper_meta_store.read_meta config name with
                 | Ok (Some meta) ->
                     let keeper = Tui_decode.keeper_of_meta meta in
                     remember_keeper name stat keeper;
                     keeper :: keepers, errors
                 | Ok None -> keepers, errors
                 | Error err ->
                     report path err;
                     keepers, (Printf.sprintf "%s: %s" name err :: errors)))
          ([], []) names
      in
      ( List.sort (fun a b -> String.compare a.k_name b.k_name) keepers
      , summarize_errors "keeper metadata read failed" errors )

(** Load tasks from the canonical workspace backlog: the active rows for the
    Overview list, plus the full domain rows the detail view reads. Terminal
    tasks remain available in Planning rollups and the detail view but do not
    occupy the Overview list. *)
let load_active_tasks (base_path : string) :
    task list * Masc_domain.task list * string option =
  let config = Workspace_core.default_config base_path in
  let path = Workspace_backlog.backlog_path config in
  match Workspace_backlog.read_backlog_observation_with_source_r config with
  | Error err ->
      report path err;
      [], [], Some ("task backlog unavailable: " ^ err)
  | Ok observation ->
      let recovery_error =
        match observation.recovered_from with
        | None -> None
        | Some recovery ->
            report path recovery.primary_error;
            Some ("task backlog recovered from backup: " ^ recovery.primary_error)
      in
      (* The backlog says what the tasks are; the goal-task registry says what
         they serve. A task record carries no goal on purpose -- the registry
         is the source of truth -- so reading only the backlog is what left
         every task on this screen unable to name its goal.

         A registry that cannot be read leaves the links empty rather than
         failing the whole load: the tasks are still worth showing, and the
         reason is reported beside them rather than as an absence of links. *)
      let goals_for_task, goal_link_error =
        match Workspace_goal_index.read_goal_task_links_r config with
        | Error err -> (fun _ -> []), Some ("goal links unavailable: " ^ err)
        | Ok goal_task_links ->
          let index =
            Workspace_goal_index.build_task_goal_index ~goal_task_links ()
          in
          ( (fun task_id -> Workspace_goal_index.goals_for_task index ~task_id)
          , None )
      in
      ( Tui_decode.active_tasks_of_domain ~goals_for_task
          observation.observed_backlog.tasks
      , observation.observed_backlog.tasks
      , (match recovery_error, goal_link_error with
         | Some recovery, _ -> Some recovery
         | None, other -> other) )

(** Apply one strict bounded metrics snapshot to the mutable screen state. *)
let apply_keeper_log_snapshot (state : state)
    (snapshot : Metrics_tail.snapshot) =
  state.log_entries <- snapshot.entries;
  state.log_error <- snapshot.error;
  state.log_scroll <-
    min state.log_scroll (max 0 (List.length snapshot.entries - 1))

(** Load the newest physical metrics rows across months and rotations. *)
let load_selected_keeper_logs (state : state) (base_path : string)
    (max_entries : int) (keeper : keeper option) =
  let config = Workspace_core.default_config base_path in
  Metrics_tail.for_selection
    ~load:(fun keeper ->
      Keeper_types_support.keeper_metrics_store config keeper.k_name
      |> fun store ->
      Metrics_tail.load ~store ~expected_keeper:keeper.k_name
        ~limit:max_entries)
    keeper
  |> apply_keeper_log_snapshot state

(** Replace one identity-stamped context snapshot atomically. *)
let apply_live_context_state (state : state) (context_state : Context_state.t) =
  state.live_context <- context_state

(** Load trace-scoped context occupancy from its current TurnRecord SSOT. *)
let load_selected_live_context (state : state) (base_path : string)
    (keeper : keeper option) =
  let config = Workspace_core.default_config base_path in
  Context_state.for_selection ~load:(Context_state.load ~config) keeper
  |> apply_live_context_state state

let load_live_context state base_path keeper =
  load_selected_live_context state base_path (Some keeper)

(** Load state from .masc directory *)
let load_from_masc_dir (state : state) (base_path : string) =
  let masc_dir = Filename.concat base_path Common.masc_dirname in

  (* Load agents *)
  let agents_dir = Filename.concat masc_dir "agents" in
  state.agents <- (
    if Sys.file_exists agents_dir && Sys.is_directory agents_dir then
      Sys.readdir agents_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
           try
             let path = Filename.concat agents_dir f in
             let json = Yojson.Safe.from_file path in
             match Tui_decode.decode_agent json with
             | Ok agent -> Some agent
             | Error err ->
                 report path err;
                 None
           with Yojson.Json_error err ->
             report (Filename.concat agents_dir f) ("invalid JSON: " ^ err);
             None
           | Sys_error err ->
             report (Filename.concat agents_dir f) err;
             None
         )
    else []
  );

  (* Load tasks from their single durable source. The domain rows land first:
     a detail view open across this refresh keeps its row even when the task
     just turned terminal, because the projection below drops exactly those. *)
  let tasks, tasks_domain, tasks_error = load_active_tasks base_path in
  state.tasks_domain <- tasks_domain;
  state.tasks <- tasks;
  state.tasks_error <- tasks_error;

  (* Capture navigation before replacing the roster. Detail and logs are bound
     to the selected row; message mode is bound to its explicit target. *)
  let current_keeper_ids =
    List.map (fun keeper -> keeper.k_name) state.keepers
  in
  let selected_keeper_name =
    if state.keeper_cursor < 0 then None
    else
      List.nth_opt state.keepers state.keeper_cursor
      |> Option.map (fun keeper -> keeper.k_name)
  in
  let current_keeper_mode =
    match state.view with
    | Keepers mode -> Some mode
    | Overview | Acting | Memory | Lanes | Board | Approvals | Planning
    | Schedules | Verification | Harness | Fusion | Repositories | Code
    | Changes | Connectors | Runtime | Config | Resources | Tools
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
               { keeper_name; cursor = state.keeper_cursor }
         | None -> Keeper_selection.List_cursor state.keeper_cursor)
    | Some Keeper_list
    (* The picker rides the list cursor: its own cursor points into the
       runtime catalogue, not the roster. *)
    | Some Keeper_runtime_pick
    | None ->
        Keeper_selection.List_cursor state.keeper_cursor
  in

  (* Load keepers *)
  let loaded_keepers, keepers_error = load_keepers base_path in
  let keepers =
    match keepers_error, current_keeper_mode with
    | Some _, Some (Keeper_detail | Keeper_logs | Keeper_calls
                   | Keeper_runtime_pick) ->
        (* A partial or failed read cannot prove that the focused Keeper was
           deleted. Keep the last complete roster until a reliable refresh can
           reconcile that identity. Message mode instead uses its explicit
           target and can render the unavailable state safely. *)
        state.keepers
    | Some _, Some (Keeper_list | Keeper_message) | Some _, None | None, _ ->
        loaded_keepers
  in
  state.keepers <- keepers;
  state.keepers_error <- keepers_error;

  let next_keeper_ids =
    List.map (fun keeper -> keeper.k_name) state.keepers
  in
  (* A roster change no longer dismisses an action notice: the notice answers
     the operator's last action, and a refresh tick would otherwise wipe it
     before it is read. User actions still clear it. *)
  (match
     Keeper_selection.reconcile ~current_ids:current_keeper_ids
       ~next_ids:next_keeper_ids ~current:current_navigation
   with
   | Keeper_selection.List_cursor cursor ->
       state.keeper_cursor <- cursor;
       (match current_keeper_mode with
        | Some (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message) ->
            state.view <- Keepers Keeper_list;
            state.detail_scroll <- 0;
            state.log_scroll <- 0;
            state.keeper_calls_scroll <- 0
        (* The picker rides the list cursor, so a reconciled cursor is not a
           lost focus: it stays open across refreshes. *)
        | Some Keeper_runtime_pick | Some Keeper_list | None -> ())
   | Keeper_selection.Detail_keeper { cursor; _ } ->
       state.keeper_cursor <- cursor;
       state.view <- Keepers Keeper_detail
   | Keeper_selection.Logs_keeper { cursor; _ } ->
       state.keeper_cursor <- cursor;
       state.view <- Keepers Keeper_logs
   | Keeper_selection.Calls_keeper { cursor; _ } ->
       state.keeper_cursor <- cursor;
       state.view <- Keepers Keeper_calls
   | Keeper_selection.Message_keeper { cursor; _ } ->
       state.keeper_cursor <- cursor;
       state.view <- Keepers Keeper_message);

  let selected_keeper = List.nth_opt state.keepers state.keeper_cursor in

  (* Load live context for the selected keeper. Metadata-only refresh paths do
     not read metrics, but an empty roster must clear any cached log state. *)
  load_selected_live_context state base_path selected_keeper;
  let current_logs : Metrics_tail.snapshot =
    { entries = state.log_entries; error = state.log_error }
  in
  let selected_keeper_name_after_refresh =
    Option.map (fun keeper -> keeper.k_name) selected_keeper
  in
  Metrics_tail.reconcile_selection ~current:current_logs
    ~previous_keeper:selected_keeper_name
    ~selected_keeper:selected_keeper_name_after_refresh
  |> apply_keeper_log_snapshot state;

  state.last_refresh <- Unix.gettimeofday ()

let clear_local_workspace (state : state) =
  state.agents <- [];
  state.tasks <- [];
  state.tasks_domain <- [];
  state.tasks_error <- None;
  state.keepers <- [];
  state.keepers_error <- None;
  state.lanes_action_error <- None;
  state.keeper_cursor <- 0;
  state.log_entries <- [];
  state.log_error <- None;
  state.live_context <- Context_state.empty
;;

(** Add event to the event log *)
let add_event (state : state) event_type content =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let ev = { timestamp; event_type; content } in
  let events = ev :: (List.filteri (fun i _ -> i < 10) state.events) in
  state.overview_event_scroll <-
    Render_schedule.overview_event_offset_after_prepend
      ~retained_count:(List.length events)
      state.overview_event_scroll;
  state.events <- events

(* An outcome the operator pressed a key for, rather than something that
   happened on its own. It goes to the event log like any other event, and to
   the footer, because the log is drawn by Overview alone: the operator who
   pressed [a] on Repos stood on the one surface that could not show them
   whether the registration landed, the declaration was refused, or the
   editor never started. *)
let report_action (state : state) event_type content =
  add_event state event_type content;
  state.last_action <- Some (content, Unix.gettimeofday ())

(** HTTP JSON decoding helpers. These intentionally fail closed for the TUI
    dashboard surfaces: an empty list means the API really returned an empty
    list, not that a malformed payload was silently dropped. *)
let ( let* ) = Result.bind

let decode_attention_severity raw =
  match String.lowercase_ascii (String.trim raw) with
  | "critical" -> Ok Attention_critical
  | "bad" -> Ok Attention_bad
  | "warn" | "warning" -> Ok Attention_warning
  | "info" -> Ok Attention_info
  | other ->
      Error
        (Printf.sprintf
           "unknown attention severity %S (normalized %S)"
           raw
           other)

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

let decode_attention_item json =
  let* ai_kind = required_string_field json "kind" in
  let* raw_severity = required_string_field json "severity" in
  let* ai_severity = decode_attention_severity raw_severity in
  let* ai_summary = required_string_field json "summary" in
  let* ai_target_type = required_string_field json "target_type" in
  let* ai_target_id = optional_string_field json "target_id" in
  (* Evidence is free-shaped on the wire (each producer writes its own
     object); the one thing this surface reads out of it is the tool-host
     failure timestamp. An absent or non-object evidence, or one without a
     readable [log_ts], means "no age to show" -- not a broken item, so the
     row survives without it. *)
  let* evidence_log_ts =
    match Yojson.Safe.Util.member "evidence" json with
    | `Assoc _ as nested -> optional_string_field nested "log_ts"
    | _ -> Ok None
  in
  let ai_evidence_ts =
    Option.bind evidence_log_ts Masc_domain.parse_iso8601_opt
  in
  Ok
    { ai_kind
    ; ai_severity
    ; ai_summary
    ; ai_target_type
    ; ai_target_id
    ; ai_evidence_ts
    }

let decode_attention_items json_list =
  decode_list "attention_items" decode_attention_item json_list

let decode_board_post ?(require_body = false) json =
  let* bp_id = required_string_field json "id" in
  let* bp_author = required_string_field json "author" in
  let* bp_title = required_string_field json "title" in
  let* bp_body =
    if require_body then required_body_field json else optional_body_field json
  in
  let* bp_votes = required_int_field json "votes" in
  let* bp_comment_count = required_int_field json "comment_count" in
  let* bp_created_at =
    required_display_any_field json [ "created_at_iso"; "created_at" ]
  in
  (* The numeric field, not its ISO twin: the list draws an age, and parsing a
     formatted timestamp back into one would be a second reading of the same
     fact. Absent reads as the creation time, which is what an untouched post's
     [updated_at] holds anyway -- so a server too old to send it degrades to
     "as old as it looks" rather than to a blank column. *)
  let updated_at =
    match Yojson.Safe.Util.member "updated_at" json with
    | `Float value -> Some value
    | `Int value -> Some (Float.of_int value)
    | _ -> None
  in
  let* bp_hearth = optional_string_field json "hearth" in
  let* raw_kind = optional_string_field json "post_kind" in
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
  Ok
    {
      bp_id;
      bp_author;
      bp_title;
      bp_body;
      bp_votes;
      bp_comment_count;
      bp_created_at;
      bp_updated_at =
        (match updated_at with
         | Some updated_at -> updated_at
         | None -> Option.value (float_of_string_opt bp_created_at) ~default:0.);
      bp_hearth;
      bp_kind;
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

(** Load the hearth census from /api/v1/board/hearths. *)
let load_board_hearths ~(host : string) ~(port : int) :
    ((string * int) list, string) result =
  match fetch_board_hearths ~host ~port with
  | Error err -> Error ("board hearths load failed: " ^ err)
  | Ok json -> decode_board_hearths json

let decode_board_posts json_list =
  decode_list "posts" decode_board_post json_list

let decode_board_comment json =
  let* bc_id = required_string_field json "id" in
  (* Optional because a top-level comment has none, not because the field may
     be absent: the wire always carries the key and answers [null] there. *)
  let* bc_parent_id = optional_string_field json "parent_id" in
  let* bc_author = required_string_field json "author" in
  let* bc_content = required_string_field json "content" in
  let* bc_created_at =
    required_display_any_field json [ "created_at_iso"; "created_at" ]
  in
  Ok { bc_id; bc_parent_id; bc_author; bc_content; bc_created_at }

let decode_board_comments json_list =
  decode_list "comments" decode_board_comment json_list

let decode_schedule_actor json field =
  match Yojson.Safe.Util.member field json with
  | `Assoc _ as actor ->
      let* id = required_string_field actor "id" in
      let* kind = required_string_field actor "kind" in
      let* display_name = optional_string_field actor "display_name" in
      let name = Option.value ~default:id display_name in
      Ok (Printf.sprintf "%s (%s)" name kind)
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object: %s" field
           (Yojson.Safe.to_string value))

let optional_nested_string_field json object_field field =
  match Yojson.Safe.Util.member object_field json with
  | `Null -> Ok None
  | `Assoc _ as nested -> optional_string_field nested field
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object or null: %s"
           object_field (Yojson.Safe.to_string value))

(* Whether a step of the wake actually happened, as the reaction ledger
   recorded it. Absent reads as [None] and not as [false]: "the ledger did not
   say" and "the ledger said no" are different answers, and only one of them
   means something went wrong. *)
let optional_nested_bool_field json object_field field =
  match Yojson.Safe.Util.member object_field json with
  | `Null -> Ok None
  | `Assoc _ as nested -> (
      match Yojson.Safe.Util.member field nested with
      | `Null -> Ok None
      | `Bool value -> Ok (Some value)
      | value ->
          Error
            (Printf.sprintf "schedule %s.%s must be a boolean or null: %s"
               object_field field (Yojson.Safe.to_string value)))
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object or null: %s"
           object_field (Yojson.Safe.to_string value))

let optional_nested_int_field json object_field field =
  match Yojson.Safe.Util.member object_field json with
  | `Null -> Ok None
  | `Assoc _ as nested ->
      (match Yojson.Safe.Util.member field nested with
       | `Null -> Ok None
       | `Int value -> Ok (Some value)
       | value ->
           Error
             (Printf.sprintf "schedule %s.%s must be an integer or null: %s"
                object_field field (Yojson.Safe.to_string value)))
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object or null: %s"
           object_field (Yojson.Safe.to_string value))

let required_schedule_json_field json field =
  match Yojson.Safe.Util.member field json with
  | `Null -> Error (Printf.sprintf "schedule %s is required" field)
  | value -> Ok value

let decode_schedule_row json =
  let* sch_schedule_instance_id =
    required_string_field json "schedule_instance_id"
  in
  let* sch_schedule_id = required_string_field json "schedule_id" in
  let* sch_status = required_string_field json "status" in
  let* sch_source = required_string_field json "source" in
  let* sch_requested_by = decode_schedule_actor json "requested_by" in
  let* sch_scheduled_by = decode_schedule_actor json "scheduled_by" in
  let* sch_requested_at_iso = required_string_field json "requested_at_iso" in
  let* sch_due_at_iso = optional_string_field json "due_at_iso" in
  let* sch_next_due_at_iso = optional_string_field json "next_due_at_iso" in
  let* sch_expires_at_iso = optional_string_field json "expires_at_iso" in
  let* sch_recurrence_summary =
    required_string_field json "recurrence_summary"
  in
  let* sch_recurrence = required_schedule_json_field json "recurrence" in
  let* sch_payload_digest = required_string_field json "payload_digest" in
  let* sch_payload = required_schedule_json_field json "payload" in
  let* sch_payload_kind = optional_string_field json "payload_kind" in
  let* sch_payload_support = required_string_field json "payload_support" in
  let* sch_payload_dispatch_tool =
    optional_string_field json "payload_dispatch_tool"
  in
  let* sch_payload_target = optional_string_field json "payload_target" in
  let* sch_payload_summary = optional_string_field json "payload_summary" in
  let* sch_last_wake_status =
    optional_nested_string_field json "last_wake" "status"
  in
  let* sch_last_wake_started_at_iso =
    optional_nested_string_field json "last_wake" "started_at_iso"
  in
  let* sch_last_wake_error =
    optional_nested_string_field json "last_wake" "error"
  in
  let* sch_queue_projection_status =
    optional_nested_string_field json "keeper_queue_evidence" "projection_status"
  in
  let* sch_queue_pending_count =
    optional_nested_int_field json "keeper_queue_evidence" "pending_count"
  in
  let* sch_reaction_projection_status =
    optional_nested_string_field json "keeper_reaction_evidence"
      "projection_status"
  in
  let* sch_reaction_latest_at_iso =
    optional_nested_string_field json "keeper_reaction_evidence"
      "latest_recorded_at_iso"
  in
  (* What became of the wake, step by step, as the reaction ledger recorded
     it. [projection_status] above is the verdict on all four at once; these
     are the four, and they are what tells a stalled wake from a delivered
     one that nobody acted on. *)
  let* sch_reaction_kind =
    optional_nested_string_field json "keeper_reaction_evidence" "reaction_kind"
  in
  let* sch_wake_seen =
    optional_nested_bool_field json "keeper_reaction_evidence" "stimulus_seen"
  in
  let* sch_turn_started =
    optional_nested_bool_field json "keeper_reaction_evidence"
      "turn_started_seen"
  in
  let* sch_queue_ack_seen =
    optional_nested_bool_field json "keeper_reaction_evidence"
      "event_queue_ack_seen"
  in
  let* sch_wake_cancelled =
    optional_nested_bool_field json "keeper_reaction_evidence"
      "event_queue_cancelled_seen"
  in
  let* sch_reaction_quarantined =
    optional_nested_int_field json "keeper_reaction_evidence"
      "quarantined_record_count"
  in
  Ok
    { sch_schedule_instance_id
    ; sch_schedule_id
    ; sch_status
    ; sch_source
    ; sch_requested_by
    ; sch_scheduled_by
    ; sch_requested_at_iso
    ; sch_due_at_iso
    ; sch_next_due_at_iso
    ; sch_expires_at_iso
    ; sch_recurrence_summary
    ; sch_recurrence
    ; sch_payload_digest
    ; sch_payload
    ; sch_payload_kind
    ; sch_payload_support
    ; sch_payload_dispatch_tool
    ; sch_payload_target
    ; sch_payload_summary
    ; sch_last_wake_status
    ; sch_last_wake_started_at_iso
    ; sch_last_wake_error
    ; sch_queue_projection_status
    ; sch_queue_pending_count
    ; sch_reaction_projection_status
    ; sch_reaction_kind
    ; sch_wake_seen
    ; sch_turn_started
    ; sch_queue_ack_seen
    ; sch_wake_cancelled
    ; sch_reaction_quarantined
    ; sch_reaction_latest_at_iso
    }

let decode_schedule_rows json_list =
  decode_list "requests" decode_schedule_row json_list

(* The snapshot keeps the server's ok/unknown split: on a store read failure
   the route reports [status = "unknown"] with a null [request_count] and an
   empty row list, and the pane must not draw that as "no schedules". *)
let decode_schedule_snapshot json =
  let* scs_status = required_string_field json "status" in
  let* scs_read_error =
    optional_string_field json "schedule_store_read_error"
  in
  let* scs_request_count =
    match Yojson.Safe.Util.member "request_count" json with
    | `Int value -> Ok (Some value)
    | `Null -> Ok None
    | other ->
        Error
          (Printf.sprintf "schedules request_count must be an integer: %s"
             (Yojson.Safe.to_string other))
  in
  let* scs_truncated =
    match Yojson.Safe.Util.member "truncated" json with
    | `Bool value -> Ok value
    | other ->
        Error
          (Printf.sprintf "schedules truncated must be a boolean: %s"
             (Yojson.Safe.to_string other))
  in
  let* scs_next_due_iso =
    match Yojson.Safe.Util.member "fsm" json with
    | `Assoc fields ->
        (match List.assoc_opt "next_due_at_iso" fields with
         | Some (`String value) -> Ok (Some value)
         | Some `Null | None -> Ok None
         | Some other ->
             Error
               (Printf.sprintf
                  "schedules fsm next_due_at_iso must be a string: %s"
                  (Yojson.Safe.to_string other)))
    | other ->
        Error
          (Printf.sprintf "schedules fsm must be an object: %s"
             (Yojson.Safe.to_string other))
  in
  let* rows = required_list_field json "requests" in
  let* scs_rows = decode_schedule_rows rows in
  Ok
    { scs_status
    ; scs_read_error
    ; scs_request_count
    ; scs_truncated
    ; scs_next_due_iso
    ; scs_rows
    }

(** Load the schedule list from /api/v1/dashboard/scheduled-automation. *)
let load_schedules ~(host : string) ~(port : int) :
    (schedule_snapshot, string) result =
  match fetch_schedules ~host ~port with
  | Error err -> Error ("schedule load failed: " ^ err)
  | Ok json -> decode_schedule_snapshot json

(** Load board post list from /api/v1/board *)
let load_board_list ~(host : string) ~(port : int)
    ~(sort_by : string) ~(hearth : string option) :
    (board_post list, string) result =
  match fetch_board ~host ~port ~sort_by ~hearth with
  | Error err -> Error ("board load failed: " ^ err)
  | Ok json ->
      let* posts = required_list_field json "posts" in
      decode_board_posts posts

(** Load board post detail from /api/v1/board/<postId> *)
let load_board_post ~(host : string) ~(port : int) ~(post_id : string) :
    (board_post * board_comment list, string) result =
  match fetch_board_post ~host ~port ~post_id with
  | Error err -> Error (Printf.sprintf "board post load failed: %s" err)
  | Ok json ->
      let post_json =
        match Yojson.Safe.Util.member "post" json with
        | `Null -> json
        | value -> value
      in
      let* post = decode_board_post ~require_body:true post_json in
      let* comments_json = optional_list_field json "comments" in
      let* comments = decode_board_comments comments_json in
      Ok (post, comments)

(** Load the actor-scoped pending confirmation envelope from the operator
    surface. Missing or malformed envelopes remain explicit errors. *)
let load_approvals ~(host : string) ~(port : int) :
    (approval_snapshot, string) result =
  match fetch_operator_snapshot ~host ~port with
  | Error err -> Error ("approvals load failed: " ^ err)
  | Ok json -> Masc_tui_operator_projection.decode_snapshot json

(** Load the runtime catalogue and keeper assignments for the picker. *)
let load_runtime_resolved ~(host : string) ~(port : int) :
    ( Tui_decode.runtime_option list * Tui_decode.runtime_assignment list,
      string )
    result =
  match fetch_runtime_resolved ~host ~port with
  | Error err -> Error ("runtime catalogue load failed: " ^ err)
  | Ok json -> Tui_decode.decode_runtime_resolved json

type runtime_surface_load = {
  rsl_resolved : Tui_decode.runtime_resolved_snapshot;
  rsl_probe : (Tui_decode.runtime_probe_snapshot, string) result;
}

(** Load the Runtime operator surface from its identity projection and optional
    probe observation. The requests run together when an Eio switch is
    available. A resolved failure rejects the load; a probe failure remains an
    inner result so lane identity can still be drawn as unobserved. *)
let load_runtime_surface ~(host : string) ~(port : int) ~(force : bool) :
    (runtime_surface_load, string) result =
  let requests =
    [ (fun () -> fetch_runtime_probe ~host ~port ~force)
    ; (fun () -> fetch_runtime_resolved ~host ~port)
    ]
  in
  let results =
    match Eio_context.get_switch_opt () with
    | Some _ -> Eio.Fiber.List.map ~max_fibers:2 (fun request -> request ()) requests
    | None -> List.map (fun request -> request ()) requests
  in
  match results with
  | [ _; Error detail ] -> Error ("runtime resolved load failed: " ^ detail)
  | [ probe_result; Ok resolved_json ] ->
      (match Tui_decode.decode_runtime_resolved_snapshot resolved_json with
       | Error detail -> Error ("runtime resolved decode failed: " ^ detail)
       | Ok rsl_resolved ->
           let rsl_probe =
             match probe_result with
             | Error detail -> Error ("runtime probe load failed: " ^ detail)
             | Ok probe_json ->
                 (match Tui_decode.decode_runtime_probe_snapshot probe_json with
                  | Ok probe -> Ok probe
                  | Error detail ->
                      Error ("runtime probe decode failed: " ^ detail))
           in
           Ok { rsl_resolved; rsl_probe })
  | _ -> Error "runtime surface loader lost one of its two projection reads"

(** Load the tool calls keepers are holding, for the Approvals surface. *)
let load_keeper_tool_approvals ~(host : string) ~(port : int) :
    (Tui_decode.keeper_tool_approval list, string) result =
  match fetch_keeper_tool_approvals ~host ~port with
  | Error err -> Error ("tool approvals load failed: " ^ err)
  | Ok json -> Tui_decode.decode_keeper_tool_approvals json

(** Load which keepers are mid-turn right now (the "answering now" badge). *)
let load_keeper_turns ~(host : string) ~(port : int) :
    (Tui_decode.keeper_turn_row list, string) result =
  match fetch_keeper_turns ~host ~port with
  | Error err -> Error ("keeper turns load failed: " ^ err)
  | Ok json -> Tui_decode.decode_keeper_turns json

(** Load the durable Gate: pending approvals and both lane modes. *)
let load_dashboard_gate ~(host : string) ~(port : int) :
    (Tui_decode.gate_snapshot, string) result =
  match fetch_dashboard_gate ~host ~port with
  | Error err -> Error ("gate load failed: " ^ err)
  | Ok json -> Tui_decode.decode_gate_snapshot json

(** Load the durable per-keeper Gate settings. *)
let load_keeper_gate_settings ~(host : string) ~(port : int) :
    ((string * string) list * (string * string) list, string) result =
  match fetch_keeper_gate_settings ~host ~port with
  | Error err -> Error ("keeper Gate settings load failed: " ^ err)
  | Ok json -> Tui_decode.decode_keeper_gate_settings json

(** Load the Runtime_params registry rows. *)
let load_runtime_params ~(host : string) ~(port : int) :
    (Tui_decode.runtime_param_row list, string) result =
  match fetch_runtime_params ~host ~port with
  | Error err -> Error ("runtime params load failed: " ^ err)
  | Ok json -> Tui_decode.decode_runtime_params json

(** Load the keepers whose approval gate is moved off [auto]. *)
let load_keeper_tool_approval_modes ~(host : string) ~(port : int) :
    ((string * string) list, string) result =
  match fetch_keeper_tool_approval_modes ~host ~port with
  | Error err -> Error ("tool approval modes load failed: " ^ err)
  | Ok json -> Tui_decode.decode_tool_approval_mode_overrides json

(** Load the delivery-path summary from /api/v1/dashboard/transport-health. *)
let load_transport_health ~(host : string) ~(port : int) :
    (Tui_decode.transport_health, string) result =
  match fetch_transport_health ~host ~port with
  | Error err -> Error ("transport health load failed: " ^ err)
  | Ok json -> Tui_decode.decode_transport_health json

(** Load overview snapshot from /api/v1/dashboard/briefing *)
let load_overview ~(host : string) ~(port : int) :
    (overview_snapshot, string) result =
  match fetch_dashboard_briefing ~host ~port with
  | Error err -> Error ("overview load failed: " ^ err)
  | Ok json ->
      let* summary = required_object_field json "summary" in
      let* command_focus = optional_object_field json "command_focus" in
      let* incidents =
        let* items = optional_list_field json "incidents" in
        decode_attention_items items
      in
      let* attention_queue =
        let* items = optional_list_field json "attention_queue" in
        decode_attention_items items
      in
      let* attention_items =
        let* items = optional_list_field json "attention_items" in
        decode_attention_items items
      in
      let* agent_briefs = optional_list_field json "agent_briefs" in
      let* keeper_briefs = optional_list_field json "keeper_briefs" in
      let* top_attention =
        let fallback =
          match incidents with
          | first :: _ -> Some first
          | [] -> None
        in
        match command_focus with
        | None -> Ok fallback
        | Some command_focus -> (
            match Yojson.Safe.Util.member "top_attention" command_focus with
            | `Null -> Ok fallback
            | value ->
                Result.map (fun item -> Some item) (decode_attention_item value))
      in
      let* ov_workspace_health =
        let* workspace_health = required_string_field summary "workspace_health" in
        decode_workspace_health workspace_health
      in
      let* ov_cluster = required_string_field summary "cluster" in
      let* ov_project = required_string_field summary "project" in
      (* Counted from the lists the briefing carries. The summary object
         holds workspace_health, cluster, and project and nothing else --
         [lib/dashboard/dashboard_briefing.ml] writes no count into it -- so
         a count read from there was a default dressed as a reading. *)
      let ov_keepers = List.length keeper_briefs in
      let ov_mcp_agents = List.length agent_briefs in
      let ov_incident_count = List.length incidents in
      let* ov_generated_at = required_string_field json "generated_at" in
      Ok
        {
          ov_workspace_health;
          ov_cluster;
          ov_project;
          ov_keepers;
          ov_mcp_agents;
          ov_incident_count;
          (* The briefing projects one fact onto two lists: an incident is
             also queued for operator attention, as the same JSON row. On the
             live runtime all three incidents came back on both lists and the
             panel drew each twice. One fact, one row: a later item
             structurally equal to an earlier one is the same projection
             again, not a second fact. Items that differ in any field keep
             both rows. *)
          ov_attention_items =
            (incidents @ attention_queue @ attention_items
            |> List.fold_left
                 (fun kept item ->
                   if List.mem item kept then kept else item :: kept)
                 []
            |> List.rev);
          ov_top_attention = top_attention;
          ov_generated_at;
        }

(** Load the system log page from /api/v1/dashboard/logs *)
let load_system_logs ~(host : string) ~(port : int) ~(limit : int) :
    (system_log_snapshot, string) result =
  match fetch_dashboard_logs ~host ~port ~limit with
  | Error err -> Error ("system logs load failed: " ^ err)
  | Ok json -> Tui_decode.decode_system_log_snapshot json

(** Load the registered tool inventory and, when selected, one Keeper's exact
    effective turn surface from /api/v1/dashboard/tools. *)
let load_tools ~(host : string) ~(port : int) ?keeper () :
    (Tui_decode.tool_snapshot, string) result =
  match fetch_dashboard_tools ~host ~port ?keeper () with
  | Error err -> Error ("tool inventory load failed: " ^ err)
  | Ok json -> Tui_decode.decode_tool_snapshot json

(** Load the workspace skills catalog for the Tools screen tracking views. *)
let load_skills_catalog ~(host : string) ~(port : int) :
    (Tui_decode.skills_catalog, string) result =
  match fetch_skills_catalog ~host ~port with
  | Error err -> Error ("skills catalog load failed: " ^ err)
  | Ok json -> Tui_decode.decode_skills_catalog json

(** Load connector status from /api/v1/gate/connectors *)
let load_connectors ~(host : string) ~(port : int) :
    (Tui_decode.connector_snapshot, string) result =
  match fetch_connectors ~host ~port with
  | Error err -> Error ("connector load failed: " ^ err)
  | Ok json -> Tui_decode.decode_connector_snapshot json

(** Load the light Lanes projection from /api/v1/keepers/composite, together
    with the secret projection the same body carries.

    One fetch, two readings. The endpoint serves several screens and the
    Secrets tab reads a different part of the same snapshots than the Lanes
    table does; asking twice would double the request for one body. *)
let load_keeper_lanes ~(host : string) ~(port : int) :
    ( Tui_decode.keeper_lanes_snapshot
      * Tui_decode.keeper_secret_projection list,
      string )
    result =
  match fetch_keeper_lanes ~host ~port with
  | Error err -> Error ("keeper lanes load failed: " ^ err)
  | Ok json ->
    (match Tui_decode.decode_keeper_lanes_snapshot json with
     | Error err -> Error err
     | Ok lanes ->
       (match Tui_decode.decode_keeper_secret_projections json with
        | Error err -> Error err
        | Ok projections -> Ok (lanes, projections)))

(** Load the standalone lane matrix independently from Keeper lane rows so a
    failure on either observation does not erase the last good other one. *)
let load_standalone_lanes ~(host : string) ~(port : int) :
    (Tui_decode.standalone_lanes_snapshot, string) result =
  match fetch_standalone_lanes ~host ~port with
  | Error err -> Error ("standalone lanes load failed: " ^ err)
  | Ok json -> Tui_decode.decode_standalone_lanes_snapshot json

(** Load the repository list from /api/v1/repositories *)
let load_repositories ~(host : string) ~(port : int) :
    (Tui_decode.repository_snapshot, string) result =
  match fetch_repositories ~host ~port with
  | Error err -> Error ("repository load failed: " ^ err)
  | Ok json -> Tui_decode.decode_repository_snapshot json

(** Load one repository's current Git working-tree changes. *)
let load_repository_changes ~(host : string) ~(port : int)
    ~(repository_id : string) :
    (Tui_decode.repository_change_snapshot, string) result =
  match fetch_repository_changes ~host ~port ~repository_id with
  | Error err -> Error ("repository changes load failed: " ^ err)
  | Ok json -> Tui_decode.decode_repository_change_snapshot json

let load_memory_health ~(host : string) ~(port : int) :
    (Tui_decode.memory_health_snapshot, string) result =
  match fetch_keeper_memory_health ~host ~port with
  | Error err -> Error ("memory health load failed: " ^ err)
  | Ok json -> Tui_decode.decode_memory_health_snapshot json

(** Load the current project's Git working-tree changes. *)
let load_project_changes ~(host : string) ~(port : int) :
    (Tui_decode.repository_change_snapshot, string) result =
  match fetch_project_changes ~host ~port with
  | Error err -> Error ("project changes load failed: " ^ err)
  | Ok json -> Tui_decode.decode_repository_change_snapshot json

(** Load a keeper's file changes from /api/v1/keepers/:name/file-changes. *)
let load_keeper_file_changes ~(host : string) ~(port : int)
    ~(keeper_name : string) ~(window_hours : float) :
    (Tui_decode.file_change_snapshot, string) result =
  match fetch_keeper_file_changes ~host ~port ~keeper_name ~window_hours with
  | Error err -> Error ("file change load failed: " ^ err)
  | Ok snapshot -> Ok snapshot

(** Load what the working tree holds for one file, from /api/v1/git/diff. *)
let load_git_diff ?repo ~(host : string) ~(port : int)
    ~(keeper : string option) ~(path : string) ~(base_ref : string) () :
    (Tui_decode.git_diff, string) result =
  match fetch_git_diff ?repo ~host ~port ~keeper ~path ~base_ref () with
  | Error err -> Error ("git diff load failed: " ^ err)
  | Ok diff -> Ok diff

(** Load the harness snapshot from /api/v1/dashboard/harness-health *)
let load_harness ~(host : string) ~(port : int) :
    (Tui_decode.harness_snapshot, string) result =
  match fetch_harness_health ~host ~port with
  | Error err -> Error ("harness load failed: " ^ err)
  | Ok json -> Tui_decode.decode_harness_snapshot json

(** Load the retained Fusion registry list. *)
let load_fusion_runs ~(host : string) ~(port : int) :
    (Tui_decode.fusion_snapshot, string) result =
  match fetch_fusion_runs ~host ~port with
  | Error err -> Error ("fusion runs load failed: " ^ err)
  | Ok json -> Tui_decode.decode_fusion_snapshot json

(** Load one exact Fusion run/evidence projection. *)
let load_fusion_detail ~(host : string) ~(port : int) ~(run_id : string) :
    (Tui_decode.fusion_detail, string) result =
  match fetch_fusion_detail ~host ~port ~run_id with
  | Error err -> Error ("fusion detail load failed: " ^ err)
  | Ok json -> Tui_decode.decode_fusion_detail json

(** Load the verification queue from /api/v1/verification/requests *)
let load_verification ~(host : string) ~(port : int) ~(limit : int) :
    (Tui_decode.verification_snapshot, string) result =
  match fetch_verification_requests ~host ~port ~limit with
  | Error err -> Error ("verification load failed: " ^ err)
  | Ok json -> Tui_decode.decode_verification_snapshot json

(** Load planning snapshot from /api/v1/dashboard/planning *)
let load_planning ~(host : string) ~(port : int) :
    (planning_snapshot, string) result =
  match fetch_dashboard_planning ~host ~port with
  | Error err -> Error ("planning load failed: " ^ err)
  | Ok json -> Tui_decode.decode_planning_snapshot json

(* Which server this is. [/health] is the compact probe, and the caller asks on
   every refresh because another process may bind the same endpoint without a
   failed request reaching this TUI. *)
let load_server_identity ~(host : string) ~(port : int) :
    (Tui_decode.server_identity, string) result =
  match fetch_server_identity ~host ~port with
  | Error err -> Error ("server identity load failed: " ^ err)
  | Ok json -> Tui_decode.decode_server_identity json

(** Load the prompt registry from /api/v1/prompts. *)
let load_prompts ~(host : string) ~(port : int) :
    (Tui_decode.prompts_snapshot, string) result =
  match fetch_prompts ~host ~port with
  | Error err -> Error ("prompts load failed: " ^ err)
  | Ok json -> Tui_decode.decode_prompts json

(* The fleet reading answers what the keeper list cannot: a keeper that never
   started has no row, so the roster shows nine keepers whether the tenth is
   absent by design or blocked. *)
let load_fleet_safety ~(host : string) ~(port : int) :
    (Tui_decode.fleet_safety, string) result =
  match fetch_fleet_safety ~host ~port with
  | Error err -> Error ("fleet safety load failed: " ^ err)
  | Ok json -> Tui_decode.decode_fleet_safety json

(** Load the live keeper roster. Truncation is carried into the typed roster
    rather than dropped: a clamped list cannot answer whether a keeper the TUI
    knows from disk has a running fiber, and the lifecycle actions depend on
    that answer. *)
let load_keeper_roster ~(host : string) ~(port : int) :
    (Masc_tui_keeper_control.roster, Masc_tui_keeper_control.roster_failure)
    result =
  match fetch_keeper_runtimes ~host ~port with
  | Error transport ->
      Error (Masc_tui_keeper_control.Roster_unreachable transport)
  | Ok (status, body) when not (Tui_decode.is_success_http_status status) ->
      Error (Masc_tui_keeper_control.roster_failure_of_status ~status ~body)
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error detail ->
          Error (Masc_tui_keeper_control.Roster_malformed detail)
      | json -> (
          match Tui_decode.decode_keeper_runtime_list json with
          | Error detail ->
              Error (Masc_tui_keeper_control.Roster_malformed detail)
          | Ok (rows, truncated, total) ->
              Ok (Masc_tui_keeper_control.roster_of_reading ~rows ~truncated ~total)))

(* The two detail-pane tab reads. Lines are built here so the renderer draws
   what one place formatted; a decode that only feeds a read-only pane keeps
   the JSON generic instead of growing a typed mirror of the config shape. *)
(* Every line these views hand the renderer goes through the terminal
   sanitizer: a CR, a tab, or a stray OSC in fetched text is data to show
   escaped, not a control to replay into the frame. *)
let sanitize_view_lines lines =
  List.map Masc.Tui_decode.sanitize_terminal_text lines

let json_block_lines (json : Yojson.Safe.t) =
  Yojson.Safe.pretty_to_string json |> String.split_on_char '\n'

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
         ~sanitize:Masc.Tui_decode.sanitize_terminal_text json)

let load_keeper_sandbox_view ~(host : string) ~(port : int)
    ~(keeper_name : string) : (Masc_tui_keeper_sandbox.t, string) result =
  match
    Masc_tui_http.fetch_keeper_status_snapshot ~host ~port ~keeper_name
  with
  | Error err -> Error ("keeper sandbox status load failed: " ^ err)
  | Ok json ->
    Masc_tui_keeper_sandbox.decode
      ~sanitize:Masc.Tui_decode.sanitize_terminal_text
      json

let load_keeper_config_editor ~(host : string) ~(port : int)
    ~(keeper_name : string) : (Yojson.Safe.t * string, string) result =
  match
    Masc_tui_http.fetch_keeper_config_snapshot ~host ~port ~keeper_name
  with
  | Error err -> Error ("keeper config load failed: " ^ err)
  | Ok json -> Ok (json, Masc_tui_keeper_config.editor_stem json)

let load_keeper_github_identity_view ~(host : string) ~(port : int)
    ~(keeper_name : string) : (string list, string) result =
  match
    Masc_tui_http.fetch_keeper_github_identity ~host ~port ~keeper_name
  with
  | Error err -> Error ("github identity load failed: " ^ err)
  | Ok json -> Ok (sanitize_view_lines (json_block_lines json))

(* What a Keeper can be attached to, and what each of those currently offers
   it. One fetch rather than two: a list of providers and a list of
   attachments cannot disagree if they arrive together. *)
let load_identity_providers ~(host : string) ~(port : int) ~(keeper_name : string)
  : (Masc_tui_types.identity_provider list, string) result
  =
  match Masc_tui_http.fetch_attached_tools ~host ~port ~keeper_name with
  | Error err -> Error ("identity providers load failed: " ^ err)
  | Ok json ->
    let rows =
      match json with
      | `Assoc fields -> (
        match List.assoc_opt "providers" fields with
        | Some (`List rows) -> Some rows
        | Some _ | None -> None)
      | _ -> None
    in
    (match rows with
     | None -> Error "identity providers response carries no providers list"
     | Some rows ->
       Ok
         (List.filter_map
            (fun row ->
              let field key =
                match row with
                | `Assoc fields -> List.assoc_opt key fields
                | _ -> None
              in
              let string_field key =
                match field key with
                | Some (`String value) -> Some value
                | Some _ | None -> None
              in
              match string_field "provider", string_field "problem" with
              | Some idp_id, Some idp_problem ->
                Some (Masc_tui_types.Identity_unreadable { idp_id; idp_problem })
              | Some idp_id, None ->
                let idp_label =
                  Option.value ~default:idp_id (string_field "provider_label")
                in
                let idp_tools =
                  match field "tools" with
                  | Some (`List names) ->
                    Some
                      (List.filter_map
                         (function `String name -> Some name | _ -> None)
                         names)
                  (* No tools key means the server said this one is not
                     attached; an empty list would mean attached and
                     offering nothing. *)
                  | Some _ | None -> None
                in
                let idp_also_on =
                  match field "also_on" with
                  | Some (`List names) ->
                    List.filter_map
                      (function `String name -> Some name | _ -> None)
                      names
                  | Some _ | None -> []
                in
                let idp_enabled =
                  match field "enabled" with
                  | Some (`Bool value) -> Some value
                  | Some _ | None -> None
                in
                let idp_switch_problem = string_field "switch_problem" in
                Some
                  (Masc_tui_types.Identity_declared
                     { idp_id; idp_label; idp_tools; idp_also_on
                     ; idp_enabled; idp_switch_problem })
              | None, _ -> None)
            rows))

let load_runtime_config_view ~(host : string) ~(port : int) :
    (string * string list, string) result =
  match Masc_tui_http.fetch_runtime_config_raw ~host ~port with
  | Error err -> Error ("runtime config load failed: " ^ err)
  | Ok json ->
    let member key =
      match json with
      | `Assoc fields -> List.assoc_opt key fields
      | _ -> None
    in
    (match member "path", member "source_text" with
     | Some (`String path), Some (`String text) ->
       Ok (path, sanitize_view_lines (String.split_on_char '\n' text))
     | _ -> Error "runtime config response missing path/source_text")
