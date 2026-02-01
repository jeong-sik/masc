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
  let now = Unix.gettimeofday () in
  let diff = now -. ts in
  if diff < 60.0 then "just now"
  else if diff < 3600.0 then Printf.sprintf "%dm ago" (int_of_float (diff /. 60.0))
  else if diff < 86400.0 then Printf.sprintf "%dh ago" (int_of_float (diff /. 3600.0))
  else Printf.sprintf "%dd ago" (int_of_float (diff /. 86400.0))

let format_ttl_remaining expires_at =
  let now = Unix.gettimeofday () in
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

(** {1 Formatters} *)

let format_post (p : Board.post) =
  let vis_str = Board.visibility_to_string p.visibility in
  let time_str = format_timestamp_relative p.created_at in
  let ttl_str = format_ttl_remaining p.expires_at in
  let score = p.votes_up - p.votes_down in
  Printf.sprintf "**%s** [%s] (by %s, %s, TTL: %s)\n%s\n[↑%d ↓%d = %+d] [%d replies]"
    (Board.Post_id.to_string p.id)
    vis_str
    (Board.Agent_id.to_string p.author)
    time_str
    ttl_str
    p.content
    p.votes_up p.votes_down score
    p.reply_count

let format_comment ?(indent=0) (c : Board.comment) =
  let prefix = String.make indent ' ' in
  let time_str = format_timestamp_relative c.created_at in
  let ttl_str = format_ttl_remaining c.expires_at in
  let reply_str = match c.parent_id with
    | Some pid -> Printf.sprintf " (reply to %s)" (Board.Comment_id.to_string pid)
    | None -> ""
  in
  let score = c.votes_up - c.votes_down in
  Printf.sprintf "%s%s: %s%s [%s, TTL: %s, ↑%d ↓%d = %+d]"
    prefix
    (Board.Agent_id.to_string c.author)
    c.content
    reply_str
    time_str
    ttl_str
    c.votes_up c.votes_down score

(** {1 Handlers} *)

let handle_post_create args =
  let store = Board.global () in
  let content = get_string args "content" "" in
  let author = get_string args "author" "anonymous" in
  let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in
  let visibility_str = get_string args "visibility" "internal" in

  let visibility = match visibility_of_string visibility_str with
    | Some v -> v
    | None -> Board.Internal
  in

  match Board.create_post store ~author ~content ~visibility ~ttl_hours () with
  | Ok post ->
      let json = Board.post_to_yojson post in
      (true, Printf.sprintf "✅ Post created:\n%s" (Yojson.Safe.pretty_to_string json))
  | Error e ->
      (false, Printf.sprintf "❌ %s" (board_error_to_string e))

let handle_post_list args =
  let store = Board.global () in
  let limit = get_int args "limit" 20 in
  let visibility_str = get_string_opt args "visibility" in

  let visibility_filter = match visibility_str with
    | Some s -> visibility_of_string s
    | None -> None
  in

  let posts = Board.list_posts store ~visibility_filter ~limit () in
  if posts = [] then
    (true, "📭 No posts found.")
  else
    let formatted = List.map format_post posts in
    let header = Printf.sprintf "📋 Posts (%d):" (List.length posts) in
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
            let formatted = List.map (format_comment ~indent:2) comments in
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

let handle_vote args =
  let store = Board.global () in
  let post_id = get_string args "post_id" "" in
  let voter = get_string args "voter" "anonymous" in
  let direction_str = get_string args "direction" "up" in

  let direction = if direction_str = "down" then Board.Down else Board.Up in

  match Board.vote store ~voter ~post_id ~direction with
  | Ok new_score ->
      let arrow = if direction = Board.Up then "↑" else "↓" in
      (true, Printf.sprintf "%s Vote recorded. New score: %+d" arrow new_score)
  | Error e ->
      (false, Printf.sprintf "❌ %s" (board_error_to_string e))

let handle_stats _args =
  let store = Board.global () in
  let stats = Board.stats store in
  (true, Printf.sprintf "📊 Board Stats:\n%s" (Yojson.Safe.pretty_to_string stats))

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
    ]);
    ("required", `List [`String "content"]);
  ];
}

let tool_post_list : Types.tool_schema = {
  name = "masc_board_list";
  description = "List posts on the MASC internal board";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max posts to return (default: 20, max: 100)")]);
      ("visibility", `Assoc [("type", `String "string"); ("description", `String "Filter by visibility: public|unlisted|internal|direct")]);
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

(** All board tools *)
let tools = [
  tool_post_create;
  tool_post_list;
  tool_post_get;
  tool_comment_add;
  tool_vote;
  tool_stats;
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
  | _ -> (false, Printf.sprintf "Unknown tool: %s" name)
