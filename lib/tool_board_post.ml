module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_board_post — post-lifecycle handlers (create / list / get /
    comment_add).

    Stage 10 split of lib/tool_board.ml — sub-domain split out of
    [Tool_board_handlers] so both files stay under the godfile new-file
    cap. *)

open Tool_args

let handle_post_create ~tool_name ~start_time args =
  let title = get_string_opt args "title" in
  (* Reject empty or whitespace-only titles. *)
  match title with
  | Some t when String.equal (String.trim t) "" ->
    Tool_result.error ~tool_name ~start_time "Title must not be empty or whitespace-only"
  | _ ->
    let body_arg =
      get_string_opt args "body" |> Option.map Tool_board_format.strip_state_blocks_text
    in
    let raw_content =
      match body_arg with
      | Some value -> value
      | None -> get_string args "content" ""
    in
    let sources = Tool_board_format.source_entries_arg args in
    let content =
      let stripped = Tool_board_format.strip_state_blocks_text raw_content in
      let content =
        match Tool_board_format.detect_truncated_markdown_with_reason stripped with
        | Some reason ->
          let author_label =
            match get_string_opt args "author" |> Option.map String.trim with
            | Some a when not (String.equal a "") -> a
            | _ -> "unknown"
          in
          Prometheus.inc_counter
            Prometheus.metric_board_truncated_posts
            ~labels:[ "author", author_label ]
            ();
          (* #9777: body_len is the LLM's own output length AFTER state-block
             stripping, not a MASC-imposed limit. The signal name explains
             which structural pattern triggered the marker. *)
          Log.BoardLog.warn
            "board_post: detected truncated markdown (author=%s body_len=%d signal=%s) — \
             appending 잘림 marker"
            author_label
            (String.length stripped)
            (Tool_board_format.truncation_signal_to_string reason);
          stripped ^ "\n\n_…[잘림 — LLM 출력이 중간에 끊겼습니다]_"
        | None -> stripped
      in
      match sources with
      | Some entries when not (String.equal (String.trim content) "") ->
        content ^ Tool_board_format.sources_footer entries
      | _ -> content
    in
    let body = Option.map (fun _ -> content) body_arg in
    let author = get_string_opt args "author" |> Option.map String.trim in
    let title_is_empty =
      match title with
      | Some value -> String.equal (String.trim value) ""
      | None -> false
    in
    if title_is_empty
    then Tool_result.error ~tool_name ~start_time "title is required"
    else if
      Option.is_none author
      || Option.equal String.equal author (Some "")
      || Option.equal String.equal author (Some "anonymous")
    then Tool_result.error ~tool_name ~start_time "author is required"
    else if String.length content > Board.Limits.max_content_length
    then
      Tool_result.error
        ~tool_name
        ~start_time
        (Printf.sprintf
           "Content exceeds max length (%d > %d chars)"
           (String.length content)
           Board.Limits.max_content_length)
    else (
      let author = Option.value author ~default:"" in
      let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in
      let visibility_str = get_string args "visibility" "internal" in
      let hearth = get_string_opt args "hearth" in
      let thread_id = get_string_opt args "thread_id" in
      let raw_post_kind = get_string_opt args "post_kind" in
      let meta_json =
        match sources with
        | Some entries ->
          Tool_board_format.merge_sources_into_meta
            (Tool_board_format.normalize_board_post_meta args)
            entries
        | None -> Tool_board_format.normalize_board_post_meta args
      in
      let visibility =
        match Tool_board_format.visibility_of_string visibility_str with
        | Some v -> v
        | None -> Board.Internal
      in
      match Tool_board_handlers.resolve_board_post_kind ~author raw_post_kind with
      | Error msg -> Tool_result.error ~tool_name ~start_time ("" ^ msg)
      | Ok post_kind ->
        (match
           Board_dispatch.create_post
             ~author
             ~content
             ?title
             ?body
             ~post_kind
             ?meta_json
             ~visibility
             ~ttl_hours
             ?hearth
             ?thread_id
             ()
         with
         | Ok post ->
           let json = Board.post_to_yojson post in
           Tool_result.ok
             ~tool_name
             ~start_time
             (Printf.sprintf "Post created:\n%s" (Yojson.Safe.pretty_to_string json))
         | Error e ->
           Tool_result.error
             ~tool_name
             ~start_time
             (Printf.sprintf "%s" (Tool_board_format.board_error_to_string e))))
;;

let handle_post_list_uncached ~tool_name ~start_time args =
  let limit = get_int args "limit" 20 |> max 1 |> min 100 in
  let compact = get_bool args "compact" true in
  let visibility_str = get_string_opt args "visibility" in
  let hearth = get_string_opt args "hearth" in
  let random = get_bool args "random" false in
  let offset = get_int args "offset" 0 in
  let sort_arg =
    match get_string_opt args "sort_by" with
    | Some _ as value -> value
    | None -> get_string_opt args "sort"
  in
  let exclude_system = get_bool args "exclude_system" false in
  let exclude_automation = get_bool args "exclude_automation" false in
  let author_filter =
    match get_string_opt args "author" with
    | Some s ->
      let s = String.trim s in
      if String.equal s "" then None else Some s
    | None -> None
  in
  let since = get_float_opt args "since" in
  let visibility_filter =
    match visibility_str with
    | Some s -> Tool_board_format.visibility_of_string s
    | None -> None
  in
  let sort_by_result =
    match sort_arg with
    | None -> Ok Tool_board_format.Hot
    | Some value -> Tool_board_format.parse_sort_order value
  in
  match sort_by_result with
  | Error msg -> Tool_result.error ~tool_name ~start_time (Printf.sprintf "%s" msg)
  | Ok sort_by ->
    (* Fetch exactly what we need: offset posts to skip + limit posts to show.
       Board_dispatch.list_posts already applies visibility/hearth/author filters. *)
    let fetch_limit = limit + offset in
    let sorted_posts =
      Board_dispatch.list_posts
        ~visibility_filter
        ?hearth
        ?author_filter
        ~exclude_system
        ~exclude_automation
        ~sort_by
        ~limit:fetch_limit
        ()
    in
    let posts =
      if random
      then (
        (* Shuffle via random-key sort (unbiased, unlike comparator trick). *)
        let shuffled =
          List.map (fun p -> Random.bits (), p) sorted_posts
          |> List.sort (fun (a, _) (b, _) -> compare a b)
          |> List.map snd
        in
        List.filteri (fun i _ -> i < limit) shuffled)
      else if offset > 0
      then
        (* Skip offset, take limit. *)
        List.filteri (fun i _ -> i >= offset && i < offset + limit) sorted_posts
      else List.filteri (fun i _ -> i < limit) sorted_posts
    in
    if Stdlib.List.length posts = 0
    then Tool_result.ok ~tool_name ~start_time "No posts found."
    else (
      (* Check for new activity since timestamp. *)
      let has_new_activity (p : Board.post) =
        match since with
        | None -> false
        | Some ts ->
          (* Post itself is new. *)
          Stdlib.Float.compare p.created_at ts > 0
          || Stdlib.Float.compare p.updated_at ts > 0
      in
      let format_post_with_indicator p =
        let indicator = if has_new_activity p then " 🔔" else "" in
        let fmt =
          if compact
          then Tool_board_format.format_post_compact
          else Tool_board_format.format_post
        in
        fmt p ^ indicator
      in
      let formatted = List.map format_post_with_indicator posts in
      let sort_label =
        match sort_by with
        | Tool_board_format.Hot -> "Hot"
        | Tool_board_format.Trending -> "Trending"
        | Tool_board_format.Recent -> "Recent"
        | Tool_board_format.Updated -> "Recently Updated"
        | Tool_board_format.Discussed -> "Most Discussed"
      in
      let separator = if compact then "\n" else "\n\n---\n\n" in
      let mode_label = if compact then " (compact)" else "" in
      let header =
        Printf.sprintf "Posts (%d) — %s%s:" (List.length posts) sort_label mode_label
      in
      Tool_result.ok
        ~tool_name
        ~start_time
        (header ^ "\n" ^ String.concat separator formatted))
;;

let handle_post_list ~tool_name ~start_time args =
  (* Skip cache for random=true — non-deterministic by definition. *)
  let random = get_bool args "random" false in
  if random
  then handle_post_list_uncached ~tool_name ~start_time args
  else (
    let key = Tool_board_cache.board_list_cache_key args in
    Tool_board_cache.cached_board_list ~key ~tool_name ~start_time (fun () ->
      handle_post_list_uncached ~tool_name ~start_time args))
;;

let handle_post_get ~tool_name ~start_time args =
  let post_id = get_string args "post_id" "" in
  match Board_dispatch.get_post_and_comments ~post_id with
  | Error (Board.Post_not_found _) ->
    (* Idempotent: post no longer exists (deleted/expired/TTL).
       Return success so keeper tool metrics don't count this as failure.
       The LLM still sees a clear message that the post is gone. *)
    Tool_result.ok
      ~tool_name
      ~start_time
      (Printf.sprintf "Post %s no longer exists (deleted or expired)." post_id)
  | Error e ->
    Tool_result.error
      ~tool_name
      ~start_time
      (Printf.sprintf "%s" (Tool_board_format.board_error_to_string e))
  | Ok (post, comments) ->
    let post_str = Tool_board_format.format_post post in
    let comments_str =
      if Stdlib.List.length comments = 0
      then "\n\nNo comments."
      else (
        let formatted = Tool_board_format.format_comment_tree comments in
        Printf.sprintf
          "\n\n**Comments (%d)**:\n%s"
          (List.length comments)
          (String.concat "\n" formatted))
    in
    Tool_result.ok ~tool_name ~start_time (post_str ^ comments_str)
;;

let handle_comment_add ~tool_name ~start_time args =
  let post_id = get_string args "post_id" "" in
  let content = get_string args "content" "" in
  let author = get_string_opt args "author" |> Option.map String.trim in
  let parent_id = get_string_opt args "parent_id" in
  let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in
  if String.equal (String.trim post_id) ""
  then Tool_result.error ~tool_name ~start_time "post_id is required"
  else if String.equal (String.trim content) ""
  then Tool_result.error ~tool_name ~start_time "Content must not be empty"
  else if
    Option.is_none author
    || Option.equal String.equal author (Some "")
    || Option.equal String.equal author (Some "anonymous")
  then Tool_result.error ~tool_name ~start_time "author is required"
  else if String.length content > Board.Limits.max_content_length
  then
    Tool_result.error
      ~tool_name
      ~start_time
      (Printf.sprintf
         "Content exceeds max length (%d > %d chars)"
         (String.length content)
         Board.Limits.max_content_length)
  else (
    match
      Board_dispatch.add_comment
        ~post_id
        ~author:(Option.value author ~default:"")
        ~content
        ?parent_id
        ~ttl_hours
        ()
    with
    | Ok comment ->
      let json = Board.comment_to_yojson comment in
      Tool_result.ok
        ~tool_name
        ~start_time
        (Printf.sprintf "Comment added:\n%s" (Yojson.Safe.pretty_to_string json))
    | Error e ->
      Tool_result.error
        ~tool_name
        ~start_time
        (Printf.sprintf "%s" (Tool_board_format.board_error_to_string e)))
;;
