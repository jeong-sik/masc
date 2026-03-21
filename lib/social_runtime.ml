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
    post_author : string option;
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
    post_author = None;
    content = String.trim post.content;
    created_at = post.created_at;
  }

let build_comment_event (comment : Board.comment) =
  let post_id_str = Board.Post_id.to_string comment.post_id in
  let post_author =
    match Board_dispatch.get_post ~post_id:post_id_str with
    | Ok post -> Some (Board.Agent_id.to_string post.author)
    | Error _ -> None
  in
  {
    key = "comment:" ^ Board.Comment_id.to_string comment.id;
    kind = `Board_comment;
    post_id = post_id_str;
    comment_id = Some (Board.Comment_id.to_string comment.id);
    author = Board.Agent_id.to_string comment.author;
    post_author;
    content = String.trim comment.content;
    created_at = comment.created_at;
  }

let queue_depth () =
  match !queue_ref with
  | Some queue -> queue.depth
  | None -> 0

let active_keeper_count config =
  resident_keeper_names config |> List.length

let event_to_message (event : board_event) : string =
  let kind_str = match event.kind with
    | `Board_post -> "board_post"
    | `Board_comment -> "board_comment"
  in
  let comment_part = match event.comment_id with
    | Some id -> Printf.sprintf "\nComment ID: %s" id
    | None -> ""
  in
  Printf.sprintf
    "Board event: %s\nPost ID: %s%s\nAuthor: %s\nContent: %s"
    kind_str event.post_id comment_part event.author event.content

let deliver_to_keepers ~config (event : board_event) =
  let keepers = resident_keeper_names config in
  List.iter (fun keeper_name ->
    if keeper_name = event.author then ()  (* don't deliver own events *)
    else
      match read_meta config keeper_name with
      | Ok (Some meta) ->
          let base_dir = session_base_dir config in
          let session = Keeper_working_context.create_session
            ~session_id:meta.trace_id ~base_dir in
          let msg = Agent_sdk.Types.user_msg (event_to_message event) in
          Keeper_working_context.persist_message session msg;
          Log.Keeper.info "board event delivered to %s: %s" keeper_name event.key
      | _ -> ()
  ) keepers

let process_event ~sw:_ ~clock:_ ~config (event : board_event) =
  last_event_at := Some event.created_at;
  if recent_key_seen event.key then ()
  else begin
    remember_key event.key;
    deliver_to_keepers ~config event;
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
