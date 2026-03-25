(** Agent_reputation — Reputation scoring from existing JSONL data

    Computes agent reputation from task transitions, mention inbox,
    board posts/comments, and debate participation.
    No new storage — reads from existing `.masc/` JSONL files.

    @since Phase 3B — Keeper Deliberation Engine
*)

type agent_reputation = {
  agent_name: string;
  tasks_completed: int;
  tasks_claimed: int;
  completion_rate: float;
  mentions_received: int;
  mentions_responded: int;
  response_rate: float;
  board_posts: int;
  board_comments: int;
  debates_participated: int;
  overall_score: float;
}

(** {1 Defaults} *)

let default_reputation ~(agent_name : string) : agent_reputation =
  { agent_name;
    tasks_completed = 0;
    tasks_claimed = 0;
    completion_rate = 0.0;
    mentions_received = 0;
    mentions_responded = 0;
    response_rate = 0.0;
    board_posts = 0;
    board_comments = 0;
    debates_participated = 0;
    overall_score = 0.0;
  }

(** {1 JSON Serialization} *)

let reputation_to_json (r : agent_reputation) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String r.agent_name);
    ("tasks_completed", `Int r.tasks_completed);
    ("tasks_claimed", `Int r.tasks_claimed);
    ("completion_rate", `Float r.completion_rate);
    ("mentions_received", `Int r.mentions_received);
    ("mentions_responded", `Int r.mentions_responded);
    ("response_rate", `Float r.response_rate);
    ("board_posts", `Int r.board_posts);
    ("board_comments", `Int r.board_comments);
    ("debates_participated", `Int r.debates_participated);
    ("overall_score", `Float r.overall_score);
  ]

let reputation_of_json (json : Yojson.Safe.t) : agent_reputation option =
  try
    let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
    if agent_name = "" then None
    else
      Some {
        agent_name;
        tasks_completed = Safe_ops.json_int ~default:0 "tasks_completed" json;
        tasks_claimed = Safe_ops.json_int ~default:0 "tasks_claimed" json;
        completion_rate = Safe_ops.json_float ~default:0.0 "completion_rate" json;
        mentions_received = Safe_ops.json_int ~default:0 "mentions_received" json;
        mentions_responded = Safe_ops.json_int ~default:0 "mentions_responded" json;
        response_rate = Safe_ops.json_float ~default:0.0 "response_rate" json;
        board_posts = Safe_ops.json_int ~default:0 "board_posts" json;
        board_comments = Safe_ops.json_int ~default:0 "board_comments" json;
        debates_participated = Safe_ops.json_int ~default:0 "debates_participated" json;
        overall_score = Safe_ops.json_float ~default:0.0 "overall_score" json;
      }
  with
  | Yojson.Safe.Util.Type_error _ -> None
  | exn ->
      Log.Reputation.warn "agent reputation of_json unexpected: %s" (Printexc.to_string exn);
      None

(** {1 JSONL Helpers} *)

(** Load a JSONL file, filter out malformed lines. *)
let load_jsonl_safe (path : string) : Yojson.Safe.t list =
  if not (Sys.file_exists path) then []
  else
    match Safe_ops.read_file_safe path with
    | Error _ -> []
    | Ok content ->
      String.split_on_char '\n' content
      |> List.filter (fun line -> String.length (String.trim line) > 0)
      |> List.filter_map (fun line ->
          try Some (Yojson.Safe.from_string line)
          with Yojson.Json_error _ -> None)

(** {1 Task Counting from Room State} *)

(** Count tasks claimed and completed by an agent from the room's task list.
    Reads task JSON files from `.masc/tasks/`. *)
let count_tasks_from_room (config : Room.config) ~(agent_name : string)
    : int * int =
  let tasks_dir = Filename.concat (Room.masc_dir config) "tasks" in
  if not (Sys.file_exists tasks_dir) || not (Sys.is_directory tasks_dir) then
    (0, 0)
  else
    let files =
      try Sys.readdir tasks_dir |> Array.to_list
      with Sys_error _ -> []
    in
    let claimed = ref 0 in
    let completed = ref 0 in
    List.iter (fun fname ->
        if Filename.check_suffix fname ".json" then begin
          let path = Filename.concat tasks_dir fname in
          match Safe_ops.read_json_file_safe path with
          | Error e -> Log.Reputation.debug "task file read failed %s: %s" fname e
          | Ok json ->
            let status = Safe_ops.json_string ~default:"" "status" json in
            let assignee = Safe_ops.json_string ~default:"" "assignee" json in
            if assignee = agent_name then begin
              if status = "claimed" || status = "in_progress" || status = "done" then
                incr claimed;
              if status = "done" then
                incr completed
            end
        end)
      files;
    (!claimed, !completed)

(** {1 Board Counting} *)

(** Count board posts and comments authored by an agent from JSONL files. *)
let count_board_activity (config : Room.config) ~(agent_name : string)
    : int * int =
  let board_dir = Room.masc_dir config in
  (* Board posts JSONL *)
  let posts_path = Filename.concat board_dir "board_posts.jsonl" in
  let posts_rows = load_jsonl_safe posts_path in
  let post_count =
    posts_rows
    |> List.filter (fun json ->
        let author = Safe_ops.json_string ~default:"" "author" json in
        author = agent_name)
    |> List.length
  in
  (* Board comments JSONL *)
  let comments_path = Filename.concat board_dir "board_comments.jsonl" in
  let comments_rows = load_jsonl_safe comments_path in
  let comment_count =
    comments_rows
    |> List.filter (fun json ->
        let author = Safe_ops.json_string ~default:"" "author" json in
        author = agent_name)
    |> List.length
  in
  (post_count, comment_count)

(** {1 Debate Counting} *)

(** Count debates an agent participated in.
    Debates are stored under `.masc/debates/` as individual JSON files. *)
let count_debate_participation (config : Room.config) ~(agent_name : string) : int =
  let debates_dir = Filename.concat (Room.masc_dir config) "debates" in
  if not (Sys.file_exists debates_dir) || not (Sys.is_directory debates_dir) then 0
  else
    let files =
      try Sys.readdir debates_dir |> Array.to_list
      with Sys_error _ -> []
    in
    files
    |> List.filter (fun fname -> Filename.check_suffix fname ".json")
    |> List.filter (fun fname ->
        let path = Filename.concat debates_dir fname in
        match Safe_ops.read_json_file_safe path with
        | Error _ -> false
        | Ok json ->
          (* Check arguments array for agent participation *)
          (try
             let args_list = Yojson.Safe.Util.member "arguments" json
                             |> Yojson.Safe.Util.to_list in
             List.exists (fun arg_json ->
                 let agent = Safe_ops.json_string ~default:"" "agent" arg_json in
                 agent = agent_name)
               args_list
           with
           | Yojson.Safe.Util.Type_error _ -> false
           | exn ->
               Log.Reputation.warn "dispatch count parse: %s" (Printexc.to_string exn);
               false))
    |> List.length

(** {1 Mention Counting} *)

let count_mention_activity (config : Room.config) ~(agent_name : string)
    : int * int =
  let all = Mention_inbox.read_mentions config ~target_agent:agent_name ~limit:10000 in
  let received = List.length all in
  let responded = List.length (List.filter (fun r -> r.Mention_inbox.read_at > 0.0) all) in
  (received, responded)

(** {1 Overall Score Computation} *)

(** Compute weighted overall score.
    - 0.4 * completion_rate
    - 0.3 * response_rate
    - 0.2 * board_activity_normalized (capped at 20 actions)
    - 0.1 * debate_normalized (capped at 10 debates) *)
let compute_overall_score ~completion_rate ~response_rate
    ~board_posts ~board_comments ~debates_participated : float =
  let board_total = float_of_int (board_posts + board_comments) in
  let board_norm = Float.min 1.0 (board_total /. 20.0) in
  let debate_norm = Float.min 1.0 (float_of_int debates_participated /. 10.0) in
  (0.4 *. completion_rate)
  +. (0.3 *. response_rate)
  +. (0.2 *. board_norm)
  +. (0.1 *. debate_norm)

(** {1 Main Computation} *)

let compute_reputation (config : Room.config) ~(agent_name : string)
    : agent_reputation =
  let (tasks_claimed, tasks_completed) =
    count_tasks_from_room config ~agent_name
  in
  let completion_rate =
    if tasks_claimed > 0 then
      float_of_int tasks_completed /. float_of_int tasks_claimed
    else 0.0
  in
  let (mentions_received, mentions_responded) =
    count_mention_activity config ~agent_name
  in
  let response_rate =
    if mentions_received > 0 then
      float_of_int mentions_responded /. float_of_int mentions_received
    else 0.0
  in
  let (board_posts, board_comments) =
    count_board_activity config ~agent_name
  in
  let debates_participated =
    count_debate_participation config ~agent_name
  in
  let overall_score =
    compute_overall_score ~completion_rate ~response_rate
      ~board_posts ~board_comments ~debates_participated
  in
  { agent_name;
    tasks_completed; tasks_claimed; completion_rate;
    mentions_received; mentions_responded; response_rate;
    board_posts; board_comments;
    debates_participated;
    overall_score;
  }
