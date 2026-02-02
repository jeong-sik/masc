(** Tool_social - MCP tool handlers for social features

    Handles: masc_post_create, masc_post_list, masc_comment_add, masc_vote
*)

open Yojson.Safe.Util

type result = bool * string

(* Input validation *)
let max_content_length = 10_000
let max_author_length = 64
let max_id_length = 128

let validate_content s =
  let len = String.length s in
  if len > max_content_length then
    Error (Printf.sprintf "Content too long: %d chars (max %d)" len max_content_length)
  else
    Ok s

let validate_author s =
  let len = String.length s in
  if len = 0 then
    Error "Author cannot be empty"
  else if len > max_author_length then
    Error (Printf.sprintf "Author too long: %d chars (max %d)" len max_author_length)
  else if not (Str.string_match (Str.regexp "^[a-zA-Z0-9_-]+$") s 0) then
    Error "Author must contain only alphanumeric, underscore, or dash"
  else
    Ok s

let validate_id ~field s =
  let len = String.length s in
  if len = 0 then
    Error (Printf.sprintf "%s cannot be empty" field)
  else if len > max_id_length then
    Error (Printf.sprintf "%s too long: %d chars (max %d)" field len max_id_length)
  else if not (Str.string_match (Str.regexp "^[a-zA-Z0-9_-]+$") s 0) then
    Error (Printf.sprintf "%s must contain only alphanumeric, underscore, or dash" field)
  else
    Ok s

type context = {
  config: Room_utils.config;
  agent_name: string;
}

(* JSON helpers *)
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
  | Error e, _ -> (false, Printf.sprintf "Error: %s" e)
  | _, Error e -> (false, Printf.sprintf "Error: %s" e)
  | Ok content, Ok author ->
      if content = "" then
        (false, "Error: content is required")
      else
        let submolt = get_string_opt args "submolt" in
        match Social.create_post ctx.config ~author ~content ?submolt () with
        | Ok post ->
            let json = Social.post_to_yojson post in
            (true, Printf.sprintf "Post created:\n%s" (Yojson.Safe.pretty_to_string json))
        | Error e ->
            (false, Printf.sprintf "Error: %s" e)

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
  | Error e -> (false, Printf.sprintf "Error: %s" e)
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
        (false, Printf.sprintf "Error: %s" e)

let handle_comment_add ctx args =
  let post_id = get_string args "post_id" "" in
  let content = get_string args "content" "" in
  let author = get_string args "author" ctx.agent_name in
  let parent_id = get_string_opt args "parent_id" in
  (* Validate inputs *)
  match validate_id ~field:"post_id" post_id, validate_content content, validate_author author with
  | Error e, _, _ -> (false, Printf.sprintf "Error: %s" e)
  | _, Error e, _ -> (false, Printf.sprintf "Error: %s" e)
  | _, _, Error e -> (false, Printf.sprintf "Error: %s" e)
  | Ok post_id, Ok content, Ok author ->
      (* Validate parent_id if provided *)
      let parent_valid = match parent_id with
        | None -> Ok None
        | Some pid -> match validate_id ~field:"parent_id" pid with
            | Ok pid -> Ok (Some pid)
            | Error e -> Error e
      in
      match parent_valid with
      | Error e -> (false, Printf.sprintf "Error: %s" e)
      | Ok parent_id ->
          if content = "" then
            (false, "Error: content is required")
          else
            match Social.add_comment ctx.config ~post_id ~author ~content ?parent_id () with
            | Ok comment ->
                let json = Social.comment_to_yojson comment in
                (true, Printf.sprintf "Comment added:\n%s" (Yojson.Safe.pretty_to_string json))
            | Error e ->
                (false, Printf.sprintf "Error: %s" e)

let handle_comment_list ctx args =
  let post_id = get_string args "post_id" "" in
  match validate_id ~field:"post_id" post_id with
  | Error e -> (false, Printf.sprintf "Error: %s" e)
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
  | Error e, _ -> (false, Printf.sprintf "Error: %s" e)
  | _, Error e -> (false, Printf.sprintf "Error: %s" e)
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
          (false, Printf.sprintf "Error: %s" e)

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
