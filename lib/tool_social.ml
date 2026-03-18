(** Tool_social - MCP tool handlers for social features

    Handles: masc_post_create, masc_post_list, masc_comment_add, masc_vote
*)

type result = bool * string

(* Input validation *)
let max_content_length = 10_000
let max_author_length = 64
let max_id_length = 128

let validate_content s =
  let len = String.length s in
  if len > max_content_length then
    Error (Printf.sprintf "❌ Social: Content too long [len=%d, max=%d]" len max_content_length)
  else
    Ok s

let validate_author s =
  let len = String.length s in
  if len = 0 then
    Error "❌ Social: Author cannot be empty"
  else if len > max_author_length then
    Error (Printf.sprintf "❌ Social: Author too long [len=%d, max=%d]" len max_author_length)
  else if not (Str.string_match (Str.regexp "^[a-zA-Z0-9_-]+$") s 0) then
    Error "❌ Social: Author must contain only alphanumeric, underscore, or dash"
  else
    Ok s

let validate_id ~field s =
  let len = String.length s in
  if len = 0 then
    Error (Printf.sprintf "❌ Social: %s cannot be empty" field)
  else if len > max_id_length then
    Error (Printf.sprintf "❌ Social: %s too long [len=%d, max=%d]" field len max_id_length)
  else if not (Str.string_match (Str.regexp "^[a-zA-Z0-9_-]+$") s 0) then
    Error (Printf.sprintf "❌ Social: %s must contain only alphanumeric, underscore, or dash" field)
  else
    Ok s

type context = {
  config: Room_utils.config;
  agent_name: string;
}

open Tool_args

(* Format timestamp as relative time *)
let format_timestamp_relative ts =
  let now = Time_compat.now () in
  let diff = now -. ts in
  if diff < 60.0 then "just now"
  else if diff < 3600.0 then Printf.sprintf "%dm ago" (int_of_float (diff /. 60.0))
  else if diff < 86400.0 then Printf.sprintf "%dh ago" (int_of_float (diff /. 3600.0))
  else Printf.sprintf "%dd ago" (int_of_float (diff /. 86400.0))

(* Format post for display *)
let format_post (p : Social.post) =
  let submolt_str = match p.submolt with
    | Some s -> Printf.sprintf " [%s]" s
    | None -> ""
  in
  let time_str = format_timestamp_relative p.created_at in
  Printf.sprintf "**%s**%s (by %s, %s)\n%s\n[votes: %d]"
    p.id submolt_str p.author time_str p.content p.votes

(* Format comment for display *)
let format_comment ?(indent=0) (c : Social.comment) =
  let prefix = String.make indent ' ' in
  let time_str = format_timestamp_relative c.created_at in
  let reply_str = match c.parent_id with
    | Some pid -> Printf.sprintf " (reply to %s)" pid
    | None -> ""
  in
  Printf.sprintf "%s%s: %s%s [%s, votes: %d]"
    prefix c.author c.content reply_str time_str c.votes

(* Handlers *)

let handle_post_create ctx args =
  let content = get_string args "content" "" in
  let author = get_string args "author" ctx.agent_name in
  (* Validate inputs *)
  match validate_content content, validate_author author with
  | Error e, _ -> (false, e)
  | _, Error e -> (false, e)
  | Ok content, Ok author ->
      if content = "" then
        (false, "❌ Social: content is required")
      else
        let submolt = get_string_opt args "submolt" in
        match Social.create_post ctx.config ~author ~content ?submolt () with
        | Ok post ->
            let json = Social.post_to_yojson post in
            (true, Printf.sprintf "Post created:\n%s" (Yojson.Safe.pretty_to_string json))
        | Error e ->
            (false, e)

let handle_post_list ctx args =
  let submolt = get_string_opt args "submolt" in
  let limit = get_int args "limit" 20 in
  let posts = Social.list_posts ctx.config ?submolt ~limit () in
  if posts = [] then
    (true, "No posts found.")
  else
    let formatted = List.map format_post posts in
    let header = match submolt with
      | Some s -> Printf.sprintf "Posts in [%s] (%d):" s (List.length posts)
      | None -> Printf.sprintf "All posts (%d):" (List.length posts)
    in
    (true, header ^ "\n\n" ^ String.concat "\n\n---\n\n" formatted)

let handle_post_get ctx args =
  let post_id = get_string args "post_id" "" in
  match validate_id ~field:"post_id" post_id with
  | Error e -> (false, e)
  | Ok post_id ->
    match Social.get_post ctx.config ~post_id with
    | Ok post ->
        let comments = Social.get_comments_threaded ctx.config ~post_id in
        let post_str = format_post post in
        let comments_str = if comments = [] then
          "\n\nNo comments."
        else
          let formatted = List.map (fun (parent, replies) ->
            let parent_str = format_comment parent in
            let replies_str = List.map (format_comment ~indent:4) replies in
            parent_str :: replies_str |> String.concat "\n"
          ) comments in
          Printf.sprintf "\n\n**Comments (%d)**:\n%s"
            (List.length comments)
            (String.concat "\n" formatted)
        in
        (true, post_str ^ comments_str)
    | Error e ->
        (false, e)

let handle_comment_add ctx args =
  let post_id = get_string args "post_id" "" in
  let content = get_string args "content" "" in
  let author = get_string args "author" ctx.agent_name in
  let parent_id = get_string_opt args "parent_id" in
  (* Validate inputs *)
  match validate_id ~field:"post_id" post_id, validate_content content, validate_author author with
  | Error e, _, _ -> (false, e)
  | _, Error e, _ -> (false, e)
  | _, _, Error e -> (false, e)
  | Ok post_id, Ok content, Ok author ->
      (* Validate parent_id if provided *)
      let parent_valid = match parent_id with
        | None -> Ok None
        | Some pid -> match validate_id ~field:"parent_id" pid with
            | Ok pid -> Ok (Some pid)
            | Error e -> Error e
      in
      match parent_valid with
      | Error e -> (false, e)
      | Ok parent_id ->
          if content = "" then
            (false, "❌ Social: content is required")
          else
            match Social.add_comment ctx.config ~post_id ~author ~content ?parent_id () with
            | Ok comment ->
                let json = Social.comment_to_yojson comment in
                (true, Printf.sprintf "Comment added:\n%s" (Yojson.Safe.pretty_to_string json))
            | Error e ->
                (false, e)

let handle_comment_list ctx args =
  let post_id = get_string args "post_id" "" in
  match validate_id ~field:"post_id" post_id with
  | Error e -> (false, e)
  | Ok post_id ->
    let comments = Social.get_comments ctx.config ~post_id in
    if comments = [] then
      (true, Printf.sprintf "No comments for post %s" post_id)
    else
      let formatted = List.map format_comment comments in
      (true, Printf.sprintf "Comments for %s (%d):\n%s"
        post_id (List.length comments) (String.concat "\n" formatted))

let handle_vote ctx args =
  let target_id = get_string args "target_id" "" in
  let target_type_str = get_string args "target_type" "post" in
  let direction_str = get_string args "direction" "up" in
  let voter = get_string args "voter" ctx.agent_name in
  (* Validate inputs *)
  match validate_id ~field:"target_id" target_id, validate_author voter with
  | Error e, _ -> (false, e)
  | _, Error e -> (false, e)
  | Ok target_id, Ok voter ->
      let target_type = match target_type_str with
        | "comment" -> `Comment
        | _ -> `Post
      in
      let direction = match direction_str with
        | "down" -> Social.Down
        | _ -> Social.Up
      in
      match Social.vote ctx.config ~voter ~target_type ~target_id ~direction with
      | Ok new_score ->
          let emoji = match direction with Social.Up -> "+" | Social.Down -> "-" in
          (true, Printf.sprintf "%s1 vote on %s %s (new score: %d)"
            emoji target_type_str target_id new_score)
      | Error e ->
          (false, e)

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_post_create" -> Some (handle_post_create ctx args)
  | "masc_post_list" -> Some (handle_post_list ctx args)
  | "masc_post_get" -> Some (handle_post_get ctx args)
  | "masc_comment_add" -> Some (handle_comment_add ctx args)
  | "masc_comment_list" -> Some (handle_comment_list ctx args)
  | "masc_vote" -> Some (handle_vote ctx args)
  | _ -> None

let schemas : Types.tool_schema list = [
  (* masc_post_create *)
  {
    name = "masc_post_create";
    description = "Create a post in the social board feed, optionally organized by submolt (topic channel). \
Use when sharing discoveries, ideas, questions, or session-end summaries with other agents. \
Pair with masc_comment_add for discussion and masc_vote for prioritization.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Post content (text, markdown supported)");
        ]);
        ("author", `Assoc [
          ("type", `String "string");
          ("description", `String "Author name (defaults to your agent name)");
        ]);
        ("submolt", `Assoc [
          ("type", `String "string");
          ("description", `String "Topic channel (e.g., 'ideas', 'bugs', 'questions')");
        ]);
      ]);
      ("required", `List [`String "content"]);
    ];
  };

  (* masc_post_list *)
  {
    name = "masc_post_list";
    description = "List posts in the social board feed, sorted by votes (highest first), with optional submolt filter. \
Use when browsing recent activity, checking for unanswered questions, or finding top-voted ideas. \
Pair with masc_post_get to read a specific post with its threaded comments.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("submolt", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by topic channel (optional)");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max posts to return (default: 20)");
        ]);
      ]);
    ];
  };

  (* masc_post_get *)
  {
    name = "masc_post_get";
    description = "Retrieve a specific post with its full threaded comment tree. \
Use when you need to read an ongoing discussion or check replies before commenting. \
Pair with masc_post_list to find the post_id, then masc_comment_add to reply.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID");
        ]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };

  (* masc_comment_add *)
  {
    name = "masc_comment_add";
    description = "Add a comment to a board post, with optional threaded reply via parent_id. \
Use when responding to a post or continuing a comment thread. \
Pair with masc_post_get to read existing comments before replying.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID to comment on");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Comment content");
        ]);
        ("author", `Assoc [
          ("type", `String "string");
          ("description", `String "Author name (defaults to your agent name)");
        ]);
        ("parent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Parent comment ID for threaded reply (optional)");
        ]);
      ]);
      ("required", `List [`String "post_id"; `String "content"]);
    ];
  };

  (* masc_comment_list *)
  {
    name = "masc_comment_list";
    description = "List all comments for a post as a flat time-sorted list. \
Use when you need a quick scan of all replies without the threaded structure. \
Pair with masc_post_get for the threaded view, or masc_comment_add to contribute.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID");
        ]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };

  (* masc_vote *)
  {
    name = "masc_vote";
    description = "Cast an upvote or downvote on a post or comment (one vote per agent per target). \
Use when signaling agreement/disagreement; votes affect sort order in masc_post_list. \
Pair with masc_post_list to find posts worth voting on.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post or comment ID to vote on");
        ]);
        ("target_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "post"; `String "comment"]);
          ("description", `String "Target type: 'post' or 'comment' (default: post)");
        ]);
        ("direction", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "up"; `String "down"]);
          ("description", `String "Vote direction: 'up' or 'down' (default: up)");
        ]);
        ("voter", `Assoc [
          ("type", `String "string");
          ("description", `String "Voter name (defaults to your agent name)");
        ]);
      ]);
      ("required", `List [`String "target_id"]);
    ];
  };

]
