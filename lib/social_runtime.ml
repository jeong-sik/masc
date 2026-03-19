open Keeper_types

type strategy = Env_config.SocialRuntime.strategy =
  | Event_driven
  | Periodic_sweep
  | Hybrid

type board_event =
  {
    key : string;
    kind : [ `Board_post | `Board_comment ];
    post_id : string;
    comment_id : string option;
    author : string;
    content : string;
    created_at : float;
  }

type event_queue =
  {
    stream : board_event Eio.Stream.t;
    mutable depth : int;
  }

let queue_ref : event_queue option ref = ref None
let started = ref false
let processed_events = ref 0
let total_checks = ref 0
let total_acted = ref 0
let total_passed = ref 0
let total_skipped = ref 0
let total_failed = ref 0
let last_event_at : float option ref = ref None
let last_social_action_at : string option ref = ref None
let last_pass_reason : string option ref = ref None
let last_system_skip_reason : string option ref = ref None
let last_tick_result : Yojson.Safe.t option ref = ref None
let recent_keys : (string, float) Hashtbl.t = Hashtbl.create 256

let enabled () = Env_config.SocialRuntime.enabled
let strategy () = Env_config.SocialRuntime.strategy
let strategy_to_string = Env_config.SocialRuntime.strategy_to_string

let iso_of_unix = Dashboard_utils.iso_of_unix

let trim_to_option value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let take n xs =
  let rec loop acc n xs =
    if n <= 0 then List.rev acc
    else
      match xs with
      | [] -> List.rev acc
      | x :: tl -> loop (x :: acc) (n - 1) tl
  in
  loop [] n xs

let mention_present ~name content =
  let needle = "@" ^ String.lowercase_ascii name in
  let haystack = String.lowercase_ascii content in
  let rec loop idx =
    if idx + String.length needle > String.length haystack then false
    else if String.sub haystack idx (String.length needle) = needle then true
    else loop (idx + 1)
  in
  String.length needle > 1 && loop 0

let recent_key_seen key =
  Hashtbl.mem recent_keys key

let remember_key key =
  Hashtbl.replace recent_keys key (Time_compat.now ());
  if Hashtbl.length recent_keys > 512 then
    let oldest =
      Hashtbl.fold
        (fun event_key ts best ->
          match best with
          | None -> Some (event_key, ts)
          | Some (_, best_ts) when ts < best_ts -> Some (event_key, ts)
          | _ -> best)
        recent_keys
        None
    in
    match oldest with
    | Some (event_key, _) -> Hashtbl.remove recent_keys event_key
    | None -> ()

let should_ignore_post config (post : Board.post) =
  let author = Board.Agent_id.to_string post.author in
  Board.classify_post_kind post <> Board.Human_post || is_resident_keeper config author

let should_ignore_comment config (comment : Board.comment) =
  let author = Board.Agent_id.to_string comment.author in
  is_resident_keeper config author || author = "lodge-system" || author = "team-session"

let build_post_event (post : Board.post) =
  {
    key = "post:" ^ Board.Post_id.to_string post.id;
    kind = `Board_post;
    post_id = Board.Post_id.to_string post.id;
    comment_id = None;
    author = Board.Agent_id.to_string post.author;
    content = String.trim post.content;
    created_at = post.created_at;
  }

let build_comment_event (comment : Board.comment) =
  {
    key = "comment:" ^ Board.Comment_id.to_string comment.id;
    kind = `Board_comment;
    post_id = Board.Post_id.to_string comment.post_id;
    comment_id = Some (Board.Comment_id.to_string comment.id);
    author = Board.Agent_id.to_string comment.author;
    content = String.trim comment.content;
    created_at = comment.created_at;
  }

let queue_depth () =
  match !queue_ref with
  | Some queue -> queue.depth
  | None -> 0

let active_keeper_count config =
  resident_keeper_names config |> List.length

let result_activity_report checkins =
  let parts =
    checkins
    |> List.map (fun (name, outcome, reason) ->
           Printf.sprintf "%s → %s: %s" name outcome reason)
  in
  if parts = [] then "No social activity processed."
  else String.concat " | " parts

let row_json ~checked_at ~(allowed_tool_names : string list)
    ~(used_tool_names : string list) ~agent_name ~outcome ~summary ~reason
    ~action_kind ~decision_reason ~failure_reason =
  let reason_code =
    match outcome, action_kind, failure_reason with
    | "failed", _, Some _ -> "tool_or_runtime_error"
    | "acted", "comment", _ -> "commented"
    | "acted", "post", _ -> "posted"
    | "acted", "vote", _ -> "voted"
    | "passed", _, _ -> "passed"
    | "skipped", _, _ -> "skipped"
    | _ -> "none"
  in
  `Assoc
    [
      ("agent_name", `String agent_name);
      ("trigger", `String "board_event");
      ("outcome", `String outcome);
      ("summary", Option.fold ~none:`Null ~some:(fun value -> `String value) summary);
      ("reason", Option.fold ~none:`Null ~some:(fun value -> `String value) reason);
      ("reason_code", `String reason_code);
      ("allowed_tool_names", `List (List.map (fun value -> `String value) allowed_tool_names));
      ("used_tool_names", `List (List.map (fun value -> `String value) used_tool_names));
      ("used_tool_call_count", `Int (List.length used_tool_names));
      ("action_kind", `String action_kind);
      ("tool_audit_source", `String "social_runtime");
      ("tool_audit_at", `String checked_at);
      ("checked_at", `String checked_at);
      ("decision_reason", Option.fold ~none:`Null ~some:(fun value -> `String value) decision_reason);
      ("worker_name", `Null);
      ("failure_reason", Option.fold ~none:`Null ~some:(fun value -> `String value) failure_reason);
    ]

let eligible_keepers config (event : board_event) : keeper_meta list =
  resident_keeper_names config
  |> List.filter_map (fun name ->
         match read_meta config name with
         | Ok (Some meta) ->
             (* Board events are reactive — initiative_enabled gates proactive
                behavior only, not responses to board posts/comments.
                policy_action_budget="board" is the relevant check here. *)
             if
               canonical_policy_action_budget meta.policy_action_budget = "board"
               && List.mem (canonical_policy_mode meta.policy_mode)
                    [ "learned_offline_v1"; "explicit_event_v1"; "llm_deliberation" ]
               && meta.name <> event.author
             then Some meta
             else None
         | _ -> None)

let select_target_keepers config event =
  let eligible : keeper_meta list = eligible_keepers config event in
  let mentioned : keeper_meta list =
    eligible
    |> List.filter (fun (meta : keeper_meta) -> mention_present ~name:meta.name event.content)
  in
  let candidates : keeper_meta list = if mentioned <> [] then mentioned else eligible in
  let sort_key (meta : keeper_meta) =
    match trim_to_option meta.last_autonomous_action_at with
    | Some value -> (
        match Resilience.Time.parse_iso8601_opt value with
        | Some ts -> ts
        | None -> 0.0)
    | None -> 0.0
  in
  candidates
  |> List.sort (fun (left : keeper_meta) (right : keeper_meta) ->
         let by_ts = Float.compare (sort_key left) (sort_key right) in
         if by_ts <> 0 then by_ts else String.compare left.name right.name)
  |> take 1

let update_totals rows =
  List.iter
    (fun row ->
      total_checks := !total_checks + 1;
      match row with
      | `Assoc fields -> (
          match List.assoc_opt "outcome" fields with
          | Some (`String "acted") -> total_acted := !total_acted + 1
          | Some (`String "passed") -> total_passed := !total_passed + 1
          | Some (`String "skipped") -> total_skipped := !total_skipped + 1
          | Some (`String "failed") -> total_failed := !total_failed + 1
          | _ -> ())
      | _ -> ())
    rows

let set_last_result summary rows =
  last_tick_result :=
    Some
      (`Assoc
         [
           ("checked", `Int (List.length rows));
           ("acted", `Int (List.length (List.filter (fun row -> Yojson.Safe.Util.(member "outcome" row = `String "acted")) rows)));
           ("passed", `Int (List.length (List.filter (fun row -> Yojson.Safe.Util.(member "outcome" row = `String "passed")) rows)));
           ("skipped", `Int (List.length (List.filter (fun row -> Yojson.Safe.Util.(member "outcome" row = `String "skipped")) rows)));
           ("failed", `Int (List.length (List.filter (fun row -> Yojson.Safe.Util.(member "outcome" row = `String "failed")) rows)));
           ("last_tick_at", `String (Types.now_iso ()));
           ("last_pass_reason", Option.fold ~none:`Null ~some:(fun value -> `String value) !last_pass_reason);
           ("last_system_skip_reason", Option.fold ~none:`Null ~some:(fun value -> `String value) !last_system_skip_reason);
           ("activity_report", `String summary);
           ("checkins", `List rows);
         ])

let process_event ~sw ~clock ~config (event : board_event) =
  last_event_at := Some event.created_at;
  if recent_key_seen event.key then ()
  else begin
    remember_key event.key;
    let checked_at = Types.now_iso () in
    let keepers = select_target_keepers config event in
    if keepers = [] then begin
      last_system_skip_reason := Some "no eligible resident keeper for board event";
      let summary = "system skipped: no eligible resident keeper for board event" in
      set_last_result summary [];
      total_skipped := !total_skipped + 1
    end else begin
      let ctx : _ Tool_keeper.context =
        {
          config;
          agent_name = "social-runtime";
          sw;
          clock;
          proc_mgr = None;
        }
      in
      let row_pairs =
        keepers
        |> List.map (fun meta ->
               let keeper_event : Keeper_execution.social_board_event =
                 {
                   kind = event.kind;
                   post_id = event.post_id;
                   comment_id = event.comment_id;
                   author = event.author;
                   content = event.content;
                   created_at = event.created_at;
                 }
               in
               match Keeper_execution.run_social_board_event_turn ctx ~meta ~event:keeper_event with
               | Ok (updated_meta, result) ->
                   (match write_meta config updated_meta with
                    | Ok () -> ()
                    | Error msg ->
                        Log.Social.error "write_meta failed for %s: %s"
                          updated_meta.name msg);
                   let outcome =
                     match result.outcome with
                     | `Acted ->
                         last_social_action_at := Some checked_at;
                         "acted"
                     | `Passed ->
                         last_pass_reason := Some result.reason;
                         "passed"
                   in
                   let row =
                     let allowed_tool_names =
                       Keeper_exec_tools.keeper_allowed_tool_names meta
                     in
                     row_json
                       ~checked_at
                       ~allowed_tool_names
                       ~used_tool_names:result.tools_used
                       ~agent_name:meta.name
                       ~outcome
                       ~summary:(Some result.summary)
                       ~reason:(Some result.reason)
                       ~action_kind:result.action_kind
                       ~decision_reason:result.decision_reason
                       ~failure_reason:result.failure_reason
                   in
                   (row, (meta.name, outcome, result.reason))
               | Error err ->
                   let row =
                     let allowed_tool_names =
                       Keeper_exec_tools.keeper_allowed_tool_names meta
                     in
                     row_json
                       ~checked_at
                       ~allowed_tool_names
                       ~used_tool_names:[]
                       ~agent_name:meta.name
                       ~outcome:"failed"
                       ~summary:None
                       ~reason:(Some err)
                       ~action_kind:"none"
                       ~decision_reason:None
                       ~failure_reason:(Some err)
                   in
                   (row, (meta.name, "failed", err)))
      in
      let rows, report_parts = List.split row_pairs in
      let summary = result_activity_report report_parts in
      update_totals rows;
      set_last_result summary rows
    end;
    processed_events := !processed_events + 1
  end

let enqueue_event event =
  if not (enabled ()) then ()
  else
    match !queue_ref with
    | None -> ()
    | Some queue ->
        queue.depth <- queue.depth + 1;
        Eio.Stream.add queue.stream event

let notify_post_created ~config (post : Board.post) =
  if should_ignore_post config post then ()
  else enqueue_event (build_post_event post)

let notify_comment_created ~config (comment : Board.comment) =
  if should_ignore_comment config comment then ()
  else enqueue_event (build_comment_event comment)

let run_periodic_sweep ~config =
  let posts =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:10 ()
    |> List.filter (fun post -> not (should_ignore_post config post))
  in
  List.iter (fun post -> enqueue_event (build_post_event post)) posts

let status_json ~config =
  `Assoc
    [
      ("enabled", `Bool (enabled ()));
      ("strategy", `String (strategy () |> strategy_to_string));
      ("queue_depth", `Int (queue_depth ()));
      ("processed_events", `Int !processed_events);
      ("active_keepers", `Int (active_keeper_count config));
      ("last_event_at",
       Option.fold ~none:`Null ~some:(fun ts -> `String (iso_of_unix ts)) !last_event_at);
      ("last_social_action_at",
       Option.fold ~none:`Null ~some:(fun value -> `String value) !last_social_action_at);
      ("last_pass_reason",
       Option.fold ~none:`Null ~some:(fun value -> `String value) !last_pass_reason);
      ("last_system_skip_reason",
       Option.fold ~none:`Null ~some:(fun value -> `String value) !last_system_skip_reason);
      ("total_checks", `Int !total_checks);
      ("total_acted", `Int !total_acted);
      ("total_passed", `Int !total_passed);
      ("total_skipped", `Int !total_skipped);
      ("total_failed", `Int !total_failed);
      ("last_result", Option.value ~default:`Null !last_tick_result);
    ]

let execution_json ~config:_ =
  let summary =
    `Assoc
      [
        ("checked", `Int !total_checks);
        ("acted", `Int !total_acted);
        ("passed", `Int !total_passed);
        ("skipped", `Int !total_skipped);
        ("failed", `Int !total_failed);
        ("last_tick_at",
         Option.fold ~none:`Null ~some:(fun ts -> `String (iso_of_unix ts)) !last_event_at);
        ("last_pass_reason",
         Option.fold ~none:`Null ~some:(fun value -> `String value) !last_pass_reason);
        ("last_system_skip_reason",
         Option.fold ~none:`Null ~some:(fun value -> `String value) !last_system_skip_reason);
        ("strategy", `String (strategy () |> strategy_to_string));
        ("queue_depth", `Int (queue_depth ()));
      ]
  in
  let rows =
    match !last_tick_result with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "checkins" fields with
        | Some (`List items) -> items
        | _ -> [])
    | _ -> []
  in
  (`Assoc [ ("summary", summary); ("checkins", `List rows) ], rows)

let start ~sw ~clock ~config =
  if !started then ()
  else begin
    started := true;
    Tool_board.register_board_event_callback
      {
        on_post_created = notify_post_created ~config;
        on_comment_created = notify_comment_created ~config;
      };
    if enabled () then begin
      let queue = { stream = Eio.Stream.create 128; depth = 0 } in
      queue_ref := Some queue;
      Eio.Fiber.fork ~sw (fun () ->
          let rec loop () =
            match !queue_ref with
            | None -> ()
            | Some active_queue ->
                let event = Eio.Stream.take active_queue.stream in
                active_queue.depth <- max 0 (active_queue.depth - 1);
                process_event ~sw ~clock ~config event;
                loop ()
          in
          loop ());
      if strategy () = Periodic_sweep || strategy () = Hybrid then
        Eio.Fiber.fork ~sw (fun () ->
            let rec sweep_loop () =
              Eio.Time.sleep clock 300.0;
              run_periodic_sweep ~config;
              sweep_loop ()
            in
            sweep_loop ())
    end
  end

let manual_sweep ~sw:_ ~clock ~config =
  run_periodic_sweep ~config;
  (match !queue_ref with
   | Some queue when queue.depth > 0 ->
       Eio.Time.sleep clock 0.05
   | _ -> ());
  execution_json ~config
