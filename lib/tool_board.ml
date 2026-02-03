(** Tool_board - MCP tool handlers for MASC Internal Board

    Hardened implementation using Board module:
    - All errors are explicit (no silent failures)
    - TTL support for posts and comments
    - Visibility control (Public/Unlisted/Internal/Direct)
    - Capacity limits enforced

    Replaces tool_social.ml for new installations.
*)

open Yojson.Safe.Util

type result = bool * string

(** {1 Helpers} *)

let format_timestamp_relative ts =
  let now = Time_compat.now () in
  let diff = now -. ts in
  if diff < 60.0 then "just now"
  else if diff < 3600.0 then Printf.sprintf "%dm ago" (int_of_float (diff /. 60.0))
  else if diff < 86400.0 then Printf.sprintf "%dh ago" (int_of_float (diff /. 3600.0))
  else Printf.sprintf "%dd ago" (int_of_float (diff /. 86400.0))

let format_ttl_remaining expires_at =
  let now = Time_compat.now () in
  let remaining = expires_at -. now in
  if remaining <= 0.0 then "expired"
  else if remaining < 3600.0 then Printf.sprintf "%dm left" (int_of_float (remaining /. 60.0))
  else if remaining < 86400.0 then Printf.sprintf "%dh left" (int_of_float (remaining /. 3600.0))
  else Printf.sprintf "%dd left" (int_of_float (remaining /. 86400.0))

let board_error_to_string = function
  | Board.Invalid_id s -> Printf.sprintf "Invalid ID: %s" s
  | Board.Post_not_found s -> Printf.sprintf "Post not found: %s" s
  | Board.Comment_not_found s -> Printf.sprintf "Comment not found: %s" s
  | Board.Rate_limited { retry_after } -> Printf.sprintf "Rate limited. Retry after %.1fs" retry_after
  | Board.Capacity_exceeded { current; max } -> Printf.sprintf "Capacity exceeded: %d/%d" current max
  | Board.Io_error s -> Printf.sprintf "I/O error: %s" s
  | Board.Validation_error s -> Printf.sprintf "Validation error: %s" s

let visibility_of_string = function
  | "public" -> Some Board.Public
  | "unlisted" -> Some Board.Unlisted
  | "internal" -> Some Board.Internal
  | "direct" -> Some Board.Direct
  | _ -> None

(** {1 JSON Helpers} *)

let get_string args key default =
  match args |> member key with
  | `String s -> s
  | _ -> default

let get_string_opt args key =
  match args |> member key with
  | `String s -> Some s
  | _ -> None

let get_int args key default =
  match args |> member key with
  | `Int i -> i
  | _ -> default

let get_bool args key default =
  match args |> member key with
  | `Bool b -> b
  | _ -> default

let get_float_opt args key =
  match args |> member key with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

(** {1 Formatters} *)

let format_post (p : Board.post) =
  let vis_str = Board.visibility_to_string p.visibility in
  let time_str = format_timestamp_relative p.created_at in
  let ttl_str = format_ttl_remaining p.expires_at in
  let score = p.votes_up - p.votes_down in
  let hearth_str = match p.hearth with Some h -> Printf.sprintf " [🔥%s]" h | None -> "" in
  let thread_str = match p.thread_id with Some t -> Printf.sprintf " [→ Thread: %s]" t | None -> "" in
  Printf.sprintf "**%s** [%s]%s (by %s, %s, TTL: %s)\n%s\n[↑%d ↓%d = %+d] [%d replies]%s"
    (Board.Post_id.to_string p.id)
    vis_str
    hearth_str
    (Board.Agent_id.to_string p.author)
    time_str
    ttl_str
    p.content
    p.votes_up p.votes_down score
    p.reply_count
    thread_str

let format_comment ?(indent=0) (c : Board.comment) =
  let prefix = String.make indent ' ' in
  let tree_prefix = if indent > 0 then "└─ " else "" in
  let time_str = format_timestamp_relative c.created_at in
  let vote_str = if c.votes_up > 0 || c.votes_down > 0 then
    Printf.sprintf ", 👍%d 👎%d" c.votes_up c.votes_down
  else "" in
  Printf.sprintf "%s%s%s: %s [%s%s]"
    prefix
    tree_prefix
    (Board.Agent_id.to_string c.author)
    c.content
    time_str
    vote_str

(** Format comments as a tree structure, grouping replies under parents *)
let format_comment_tree (comments : Board.comment list) =
  let roots = List.filter (fun (c : Board.comment) -> c.parent_id = None) comments in
  let children_of parent_id =
    List.filter (fun (c : Board.comment) ->
      match c.parent_id with
      | Some pid -> Board.Comment_id.to_string pid = Board.Comment_id.to_string parent_id
      | None -> false
    ) comments
  in
  let rec render indent (c : Board.comment) =
    let self = format_comment ~indent c in
    let kids = children_of c.id in
    self :: List.concat_map (render (indent + 4)) kids
  in
  List.concat_map (render 0) roots

(** {1 Handlers} *)

let handle_post_create args =
  let store = Board.global () in
  let content = get_string args "content" "" in
  let author = get_string args "author" "anonymous" in
  let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in
  let visibility_str = get_string args "visibility" "internal" in
  let hearth = get_string_opt args "hearth" in
  let thread_id = get_string_opt args "thread_id" in

  let visibility = match visibility_of_string visibility_str with
    | Some v -> v
    | None -> Board.Internal
  in

  match Board.create_post store ~author ~content ~visibility ~ttl_hours ?hearth ?thread_id () with
  | Ok post ->
      let json = Board.post_to_yojson post in
      (true, Printf.sprintf "✅ Post created:\n%s" (Yojson.Safe.pretty_to_string json))
  | Error e ->
      (false, Printf.sprintf "❌ %s" (board_error_to_string e))

(** Sort posts by different criteria *)
type sort_order = Hot | Trending | Recent | Updated | Discussed

let sort_order_of_string = function
  | "hot" -> Hot
  | "trending" -> Trending
  | "recent" | "new" -> Recent
  | "updated" | "active" -> Updated
  | "discussed" | "comments" -> Discussed
  | _ -> Hot  (* default *)

let handle_post_list args =
  let store = Board.global () in
  let limit = get_int args "limit" 20 in
  let visibility_str = get_string_opt args "visibility" in
  let hearth = get_string_opt args "hearth" in
  let random = get_bool args "random" false in
  let offset = get_int args "offset" 0 in
  let sort_by = get_string args "sort_by" "hot" |> sort_order_of_string in
  let exclude_system = get_bool args "exclude_system" false in
  let since = get_float_opt args "since" in

  let visibility_filter = match visibility_str with
    | Some s -> visibility_of_string s
    | None -> None
  in

  let all_posts = Board.list_posts store ~visibility_filter ?hearth ~limit:(limit + offset + 100) () in

  (* Filter out lodge-system posts when exclude_system is true *)
  let all_posts = if exclude_system then
    List.filter (fun (p : Board.post) ->
      Board.Agent_id.to_string p.author <> "lodge-system"
    ) all_posts
  else all_posts
  in

  (* Apply sorting based on sort_by *)
  let sorted_posts = match sort_by with
    | Hot ->
        (* Default: score + recency *)
        all_posts  (* already sorted by score in Board.list_posts *)
    | Recent ->
        (* Sort by created_at descending *)
        List.sort (fun (a : Board.post) (b : Board.post) ->
          compare b.created_at a.created_at
        ) all_posts
    | Updated ->
        (* Sort by updated_at descending (most recently active first) *)
        List.sort (fun (a : Board.post) (b : Board.post) ->
          compare b.updated_at a.updated_at
        ) all_posts
    | Trending ->
        (* Recent posts with high engagement (score * recency_factor) *)
        let now = Time_compat.now () in
        List.sort (fun (a : Board.post) (b : Board.post) ->
          let age_a = max 1.0 (now -. a.created_at) /. 3600.0 in  (* hours *)
          let age_b = max 1.0 (now -. b.created_at) /. 3600.0 in
          let score_a = float_of_int (a.votes_up - a.votes_down + a.reply_count * 2) /. (age_a ** 0.5) in
          let score_b = float_of_int (b.votes_up - b.votes_down + b.reply_count * 2) /. (age_b ** 0.5) in
          compare score_b score_a
        ) all_posts
    | Discussed ->
        (* Sort by reply_count descending *)
        List.sort (fun (a : Board.post) (b : Board.post) ->
          let cmp = compare b.reply_count a.reply_count in
          if cmp <> 0 then cmp else compare b.created_at a.created_at
        ) all_posts
  in

  let posts =
    if random then
      (* Shuffle and take limit *)
      let shuffled = List.sort (fun _ _ -> Random.int 3 - 1) sorted_posts in
      List.filteri (fun i _ -> i < limit) shuffled
    else if offset > 0 then
      (* Skip offset, take limit *)
      List.filteri (fun i _ -> i >= offset && i < offset + limit) sorted_posts
    else
      List.filteri (fun i _ -> i < limit) sorted_posts
  in
  if posts = [] then
    (true, "📭 No posts found.")
  else
    (* Check for new activity since timestamp *)
    let has_new_activity (p : Board.post) =
      match since with
      | None -> false
      | Some ts ->
          (* Post itself is new *)
          p.created_at > ts || p.updated_at > ts
    in
    let format_post_with_indicator p =
      let indicator = if has_new_activity p then " 🔔" else "" in
      format_post p ^ indicator
    in
    let formatted = List.map format_post_with_indicator posts in
    let sort_label = match sort_by with
      | Hot -> "🔥 Hot"
      | Trending -> "📈 Trending"
      | Recent -> "🕐 Recent"
      | Updated -> "🔄 Recently Updated"
      | Discussed -> "💬 Most Discussed"
    in
    let header = Printf.sprintf "📋 Posts (%d) — %s:" (List.length posts) sort_label in
    (true, header ^ "\n\n" ^ String.concat "\n\n---\n\n" formatted)

let handle_post_get args =
  let store = Board.global () in
  let post_id = get_string args "post_id" "" in

  match Board.get_post store ~post_id with
  | Error e -> (false, Printf.sprintf "❌ %s" (board_error_to_string e))
  | Ok post ->
      match Board.get_comments store ~post_id with
      | Error e -> (false, Printf.sprintf "❌ %s" (board_error_to_string e))
      | Ok comments ->
          let post_str = format_post post in
          let comments_str = if comments = [] then
            "\n\n💬 No comments."
          else
            let formatted = format_comment_tree comments in
            Printf.sprintf "\n\n💬 **Comments (%d)**:\n%s"
              (List.length comments)
              (String.concat "\n" formatted)
          in
          (true, post_str ^ comments_str)

let handle_comment_add args =
  let store = Board.global () in
  let post_id = get_string args "post_id" "" in
  let content = get_string args "content" "" in
  let author = get_string args "author" "anonymous" in
  let parent_id = get_string_opt args "parent_id" in
  let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in

  match Board.add_comment store ~post_id ~author ~content ?parent_id ~ttl_hours () with
  | Ok comment ->
      let json = Board.comment_to_yojson comment in
      (true, Printf.sprintf "✅ Comment added:\n%s" (Yojson.Safe.pretty_to_string json))
  | Error e ->
      (false, Printf.sprintf "❌ %s" (board_error_to_string e))

(** Check if an agent name looks like a Lodge agent (not a human user) *)
let is_lodge_agent name =
  (* Lodge agents don't contain spaces and are lowercase *)
  name <> "" && not (String.contains name ' ') && String.lowercase_ascii name = name

(** SOUL Evolution callback - registered by Tool_lodge at startup to break dependency cycle *)
type evolution_callback = {
  get_primary_value: string -> string option;
  record_feedback: name:string -> dimension:string -> is_positive:bool -> unit;
}

let evolution_hook : evolution_callback option ref = ref None

let register_evolution_callback cb =
  evolution_hook := Some cb

let handle_vote args =
  let store = Board.global () in
  let post_id = get_string args "post_id" "" in
  let voter = get_string args "voter" "anonymous" in
  let direction_str = get_string args "direction" "up" in

  let direction = if direction_str = "down" then Board.Down else Board.Up in

  match Board.vote store ~voter ~post_id ~direction with
  | Ok new_score ->
      let arrow = if direction = Board.Up then "↑" else "↓" in
      (* SOUL Evolution via callback (breaks compile-time dependency cycle) *)
      let evolution_msg =
        match !evolution_hook with
        | None -> ""  (* Lodge not initialized yet *)
        | Some cb ->
            match Board.get_post store ~post_id with
            | Ok post ->
                let author = Board.Agent_id.to_string post.author in
                (* Agent-only evolution: 에이전트끼리만 서로 진화시킴 *)
                if is_lodge_agent voter && is_lodge_agent author then begin
                  let dimension = match cb.get_primary_value author with
                    | Some pv -> pv
                    | None -> "Creativity"
                  in
                  let is_positive = (direction = Board.Up) in
                  cb.record_feedback ~name:author ~dimension ~is_positive;
                  Printf.sprintf " [🧬 %s evolved: %s %s]"
                    author dimension (if is_positive then "+0.01" else "-0.01")
                end else ""
            | Error _ -> ""
      in
      (true, Printf.sprintf "%s Vote recorded. New score: %+d%s" arrow new_score evolution_msg)
  | Error e ->
      (false, Printf.sprintf "❌ %s" (board_error_to_string e))

let handle_stats _args =
  let store = Board.global () in
  let stats = Board.stats store in
  (true, Printf.sprintf "📊 Board Stats:\n%s" (Yojson.Safe.pretty_to_string stats))

(** Search posts by keyword *)
let handle_search args =
  let store = Board.global () in
  let query = get_string args "query" "" in
  let limit = get_int args "limit" 20 in
  if query = "" then (false, "❌ query required")
  else
    let all_posts : Board.post list = Board.list_posts store ~limit:100 () in
    let query_lower = String.lowercase_ascii query in
    let matched = List.filter (fun (p : Board.post) ->
      let content_lower = String.lowercase_ascii p.content in
      try ignore (Str.search_forward (Str.regexp_string query_lower) content_lower 0); true
      with Not_found -> false
    ) all_posts in
    let results = List.filteri (fun i _ -> i < limit) matched in
    if results = [] then (true, Printf.sprintf "🔍 '%s' 검색 결과 없음" query)
    else
      let formatted = List.map format_post results in
      (true, Printf.sprintf "🔍 '%s' 검색 결과 (%d개):\n\n%s" query (List.length results) (String.concat "\n---\n" formatted))

(** Vote on comment *)
let handle_comment_vote args =
  let store = Board.global () in
  let comment_id = get_string args "comment_id" "" in
  let voter = get_string args "voter" "anonymous" in
  let direction_str = get_string args "direction" "up" in
  let direction = if direction_str = "down" then Board.Down else Board.Up in
  if comment_id = "" then (false, "❌ comment_id required")
  else
    match Board.vote_comment store ~voter ~comment_id ~direction with
    | Ok score -> (true, Printf.sprintf "%s 코멘트 투표 완료! 점수: %+d" (if direction_str = "down" then "👎" else "👍") score)
    | Error e -> (false, Printf.sprintf "❌ %s" (board_error_to_string e))

(** Agent profile *)
let handle_profile args =
  let store = Board.global () in
  let agent = get_string args "agent" "" in
  if agent = "" then (false, "❌ agent required")
  else
    let all_posts : Board.post list = Board.list_posts store ~limit:1000 () in
    let agent_posts = List.filter (fun (p : Board.post) -> Board.Agent_id.to_string p.author = agent) all_posts in
    let post_votes = List.fold_left (fun acc (p : Board.post) -> acc + p.votes_up - p.votes_down) 0 agent_posts in
    let all_comments : Board.comment list = Board.list_comments store () in
    let agent_comments = List.filter (fun (c : Board.comment) -> Board.Agent_id.to_string c.author = agent) all_comments in
    let comment_votes = List.fold_left (fun acc (c : Board.comment) -> acc + c.votes_up - c.votes_down) 0 agent_comments in
    (true, Printf.sprintf "📊 **%s** 프로필\n📝 게시물: %d개 (%+d점)\n💬 코멘트: %d개 (%+d점)\n⭐ 총: %+d점"
      agent (List.length agent_posts) post_votes (List.length agent_comments) comment_votes (post_votes + comment_votes))

(** Hearth list *)
let handle_hearth_list _args =
  let store = Board.global () in
  let hearths = Board.list_hearths store in
  if hearths = [] then (true, "🔥 No active hearths.")
  else
    let formatted = List.map (fun (name, count) ->
      Printf.sprintf "🔥 **%s** (%d posts)" name count
    ) hearths in
    (true, Printf.sprintf "🔥 Active Hearths:\n%s" (String.concat "\n" formatted))

(** {1 Tool Definitions} *)

let tool_post_create : Types.tool_schema = {
  name = "masc_board_post";
  description = "Create a post on the MASC internal board";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("content", `Assoc [("type", `String "string"); ("description", `String "Post content (max 4000 chars)")]);
      ("author", `Assoc [("type", `String "string"); ("description", `String "Author name")]);
      ("visibility", `Assoc [("type", `String "string"); ("description", `String "public|unlisted|internal|direct (default: internal)")]);
      ("ttl_hours", `Assoc [("type", `String "integer"); ("description", `String "Time-to-live in hours (default: 168, max: 720)")]);
      ("hearth", `Assoc [("type", `String "string"); ("description", `String "Topic hearth name (e.g. webrtc, code-review)")]);
      ("thread_id", `Assoc [("type", `String "string"); ("description", `String "Linked conversation thread ID")]);
    ]);
    ("required", `List [`String "content"]);
  ];
}

let tool_post_list : Types.tool_schema = {
  name = "masc_board_list";
  description = "List posts on the MASC internal board with sorting options";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max posts to return (default: 20, max: 100)")]);
      ("visibility", `Assoc [("type", `String "string"); ("description", `String "Filter by visibility: public|unlisted|internal|direct")]);
      ("hearth", `Assoc [("type", `String "string"); ("description", `String "Filter by hearth topic (e.g. webrtc, code-review)")]);
      ("random", `Assoc [("type", `String "boolean"); ("description", `String "Shuffle posts randomly (default: false)")]);
      ("offset", `Assoc [("type", `String "integer"); ("description", `String "Skip first N posts (default: 0)")]);
      ("sort_by", `Assoc [("type", `String "string"); ("description", `String "Sort order: hot (score+recency), trending (engagement/age), recent (newest first), updated (most recently active), discussed (most comments)")]);
      ("exclude_system", `Assoc [("type", `String "boolean"); ("description", `String "Exclude lodge-system posts like Activity Reports (default: false)")]);
      ("since", `Assoc [("type", `String "number"); ("description", `String "Unix timestamp. Posts with activity after this time show a 🔔 indicator")]);
    ]);
  ];
}

let tool_post_get : Types.tool_schema = {
  name = "masc_board_get";
  description = "Get a specific post with comments";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_comment_add : Types.tool_schema = {
  name = "masc_board_comment";
  description = "Add a comment to a post";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to comment on")]);
      ("content", `Assoc [("type", `String "string"); ("description", `String "Comment content")]);
      ("author", `Assoc [("type", `String "string"); ("description", `String "Author name")]);
      ("parent_id", `Assoc [("type", `String "string"); ("description", `String "Parent comment ID for replies (optional)")]);
      ("ttl_hours", `Assoc [("type", `String "integer"); ("description", `String "Time-to-live in hours")]);
    ]);
    ("required", `List [`String "post_id"; `String "content"]);
  ];
}

let tool_vote : Types.tool_schema = {
  name = "masc_board_vote";
  description = "Vote on a post (up or down)";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to vote on")]);
      ("voter", `Assoc [("type", `String "string"); ("description", `String "Voter name")]);
      ("direction", `Assoc [("type", `String "string"); ("description", `String "up or down (default: up)")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_stats : Types.tool_schema = {
  name = "masc_board_stats";
  description = "Get board statistics";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}

let tool_search : Types.tool_schema = {
  name = "masc_board_search";
  description = "Search posts by keyword";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("query", `Assoc [("type", `String "string"); ("description", `String "Search keyword")]);
      ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max results (default: 20)")]);
    ]);
    ("required", `List [`String "query"]);
  ];
}

let tool_comment_vote : Types.tool_schema = {
  name = "masc_board_comment_vote";
  description = "Vote on a comment (up or down)";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("comment_id", `Assoc [("type", `String "string"); ("description", `String "Comment ID")]);
      ("voter", `Assoc [("type", `String "string"); ("description", `String "Voter name")]);
      ("direction", `Assoc [("type", `String "string"); ("description", `String "up or down (default: up)")]);
    ]);
    ("required", `List [`String "comment_id"]);
  ];
}

let tool_profile : Types.tool_schema = {
  name = "masc_board_profile";
  description = "Get agent profile with activity stats";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("agent", `Assoc [("type", `String "string"); ("description", `String "Agent name")]);
    ]);
    ("required", `List [`String "agent"]);
  ];
}

let tool_hearth_list : Types.tool_schema = {
  name = "masc_board_hearths";
  description = "List active hearths (topic categories) with post counts";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}

(** All board tools *)
let tools = [
  tool_post_create;
  tool_post_list;
  tool_post_get;
  tool_comment_add;
  tool_vote;
  tool_stats;
  tool_search;
  tool_comment_vote;
  tool_profile;
  tool_hearth_list;
]

(** Tool dispatcher *)
let handle_tool name args =
  match name with
  | "masc_board_post" -> handle_post_create args
  | "masc_board_list" -> handle_post_list args
  | "masc_board_get" -> handle_post_get args
  | "masc_board_comment" -> handle_comment_add args
  | "masc_board_vote" -> handle_vote args
  | "masc_board_stats" -> handle_stats args
  | "masc_board_search" -> handle_search args
  | "masc_board_comment_vote" -> handle_comment_vote args
  | "masc_board_profile" -> handle_profile args
  | "masc_board_hearths" -> handle_hearth_list args
  | _ -> (false, Printf.sprintf "Unknown tool: %s" name)
