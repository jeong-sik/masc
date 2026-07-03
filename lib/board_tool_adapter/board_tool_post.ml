open Masc_board_handlers

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

(** Board_tool_post — post-lifecycle handlers (create / list / get /
    comment_add).

    Stage 10 split of lib/board_tool.ml — sub-domain split out of
    [Board_tool_handlers] so both files stay under the godfile new-file
    cap. *)

open Tool_args

(* RFC-0189 PR-1b.2 — handlers in this module return the typed
   [Tool_result.result] variant directly. *)

let handle_post_create ~tool_name ~start_time args : Tool_result.result =
  let title = get_string_opt args "title" in
  (* Reject empty or whitespace-only titles. *)
  match title with
  | Some t when String.equal (String.trim t) "" ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "Title must not be empty or whitespace-only"
  | _ ->
    let body_arg =
      get_string_opt args "body" |> Option.map Board_tool_format.strip_state_blocks_text
    in
    let raw_content =
      match body_arg with
      | Some value -> value
      | None -> get_string args "content" ""
    in
    let sources = Board_tool_format.source_entries_arg args in
    let content =
      let stripped = Board_tool_format.strip_state_blocks_text raw_content in
      let content =
        match Board_tool_format.detect_truncated_markdown_with_reason stripped with
        | Some reason ->
          let author_label =
            match get_string_opt args "author" |> Option.map String.trim with
            | Some a when not (String.equal a "") -> a
            | _ -> "unknown"
          in
          (* #9777: body_len is the LLM's own output length AFTER state-block
             stripping, not a MASC-imposed limit. The signal name explains
             which structural pattern triggered the marker. *)
          Log.BoardLog.warn
            "board_post: detected truncated markdown (author=%s body_len=%d signal=%s) — \
             appending 잘림 marker"
            author_label
            (String.length stripped)
            (Board_tool_format.truncation_signal_to_string reason);
          stripped ^ "\n\n_…[잘림 — LLM 출력이 중간에 끊겼습니다]_"
        | None -> stripped
      in
      match sources with
      | Some entries when not (String.equal (String.trim content) "") ->
        content ^ Board_tool_format.sources_footer entries
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
    then
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        "title is required"
    else if
      Option.is_none author
      || Option.equal String.equal author (Some "")
      || Option.equal String.equal author (Some "anonymous")
    then
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        "author is required"
    else if String.length content > Board.Limits.max_content_length
    then
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
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
          Board_tool_format.merge_sources_into_meta
            (Board_tool_format.normalize_board_post_meta args)
            entries
        | None -> Board_tool_format.normalize_board_post_meta args
      in
      let visibility =
        match Board_tool_format.visibility_of_string visibility_str with
        | Some v -> v
        | None -> Board.Internal
      in
      match Board_tool_handlers.resolve_board_post_kind ~author raw_post_kind with
      | Error msg ->
        Tool_result.make_err
          ~tool_name
          ~class_:Tool_result.Workflow_rejection
          ~start_time
          msg
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
           (* Use [Tool_result.ok] (not [make_ok ~data:(`String ...)]) so the
              embedded JSON after the "<label>:\n" prefix is parsed into
              structured [data] via [structured_payload_of_message]. Passing a
              raw [`String] double-encodes the JSON: consumers that re-serialize
              the result (e.g. the dashboard's JSON.stringify) escape the inner
              newlines back to literal "\n". The prose prefix is dropped once
              the structure is extracted, matching the board_curation idiom. *)
           Tool_result.ok
             ~tool_name
             ~start_time
             (Printf.sprintf "Post created:\n%s" (Yojson.Safe.pretty_to_string json))
         | Error e ->
           Board_tool_format.error_of_board_error ~tool_name ~start_time e))
;;

let handle_post_edit ~tool_name ~start_time args : Tool_result.result =
  let post_id = get_string args "post_id" "" in
  (* Mirror create's body/content handling: strip [STATE] blocks at the tool
     boundary (an LLM output artifact) and let [body] win over [content]. The
     core then re-normalizes against the existing meta; via this tool path the
     body carries no state block, so meta is preserved. *)
  let body_arg =
    get_string_opt args "body" |> Option.map Board_tool_format.strip_state_blocks_text
  in
  let raw_content =
    match body_arg with
    | Some value -> value
    | None -> get_string args "content" ""
  in
  let content = Board_tool_format.strip_state_blocks_text raw_content in
  let body = Option.map (fun _ -> content) body_arg in
  (* A blank/absent title means "re-derive from the new body"; only a non-empty
     title overrides. *)
  let title =
    match get_string_opt args "title" with
    | Some t when not (String.equal (String.trim t) "") -> Some t
    | _ -> None
  in
  (* Parse [author] into a validated editor string at the boundary instead of
     carrying a [string option] and defaulting at the call site. Owner-gate
     enforcement downstream needs a concrete editor identity, so an absent,
     blank, or "anonymous" author is rejected here; the dispatch then only ever
     receives a non-empty editor (no unreachable default to guess). *)
  let valid_editor =
    match get_string_opt args "author" |> Option.map String.trim with
    | Some editor
      when (not (String.equal editor "")) && not (String.equal editor "anonymous") ->
      Some editor
    | _ -> None
  in
  if String.equal (String.trim post_id) ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "post_id is required"
  else if String.equal (String.trim content) ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "New body content must not be empty (resend the full post body to edit)"
  else (
    match valid_editor with
    | None ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        "author is required"
    | Some editor ->
      if String.length content > Board.Limits.max_content_length
      then
        Tool_result.make_err
          ~tool_name
          ~class_:Tool_result.Workflow_rejection
          ~start_time
          (Printf.sprintf
             "Content exceeds max length (%d > %d chars)"
             (String.length content)
             Board.Limits.max_content_length)
      else (
        let new_author = get_string_opt args "new_author" in
        match Board_dispatch.update_post ~post_id ~editor ~content ?title ?body ?new_author () with
        | Ok post ->
          let json = Board.post_to_yojson post in
          (* Structured result via [Tool_result.ok]; see "Post created" note above. *)
          Tool_result.ok
            ~tool_name
            ~start_time
            (Printf.sprintf "Post updated:\n%s" (Yojson.Safe.pretty_to_string json))
        | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e))
;;

let handle_post_list_uncached ~tool_name ~start_time args : Tool_result.result =
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
  let exclude_author_filter =
    match get_string_opt args "exclude_author" with
    | Some s ->
      let s = String.trim s in
      if String.equal s "" then None else Some s
    | None -> None
  in
  let since = get_float_opt args "since" in
  let visibility_filter =
    match visibility_str with
    | Some s -> Board_tool_format.visibility_of_string s
    | None -> None
  in
  let sort_by_result =
    match sort_arg with
    | None -> Ok Board_tool_format.Hot
    | Some value -> Board_tool_format.parse_sort_order value
  in
  match sort_by_result with
  | Error msg ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      msg
  | Ok sort_by ->
    (* Fetch exactly what we need: offset posts to skip + limit posts to show.
       Board_dispatch.list_posts already applies visibility/hearth/author filters. *)
    let fetch_limit = limit + offset in
    let sorted_posts =
      Board_dispatch.list_posts
        ~visibility_filter
        ?hearth
        ?author_filter
        ?exclude_author_filter
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
    then
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:(`String "No posts found.")
        ()
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
          then Board_tool_format.format_post_compact
          else Board_tool_format.format_post
        in
        fmt p ^ indicator
      in
      let formatted = List.map format_post_with_indicator posts in
      let sort_label =
        match sort_by with
        | Board_tool_format.Hot -> "Hot"
        | Board_tool_format.Trending -> "Trending"
        | Board_tool_format.Recent -> "Recent"
        | Board_tool_format.Updated -> "Recently Updated"
        | Board_tool_format.Discussed -> "Most Discussed"
      in
      let separator = if compact then "\n" else "\n\n---\n\n" in
      let mode_label = if compact then " (compact)" else "" in
      let header =
        Printf.sprintf "Posts (%d) — %s%s:" (List.length posts) sort_label mode_label
      in
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:(`String (header ^ "\n" ^ String.concat separator formatted))
        ())
;;

let handle_post_list ~tool_name ~start_time args =
  (* Skip cache for random=true — non-deterministic by definition. *)
  let random = get_bool args "random" false in
  if random
  then handle_post_list_uncached ~tool_name ~start_time args
  else (
    let key = Board_tool_cache.board_list_cache_key args in
    Board_tool_cache.cached_board_list ~key ~tool_name ~start_time (fun () ->
      handle_post_list_uncached ~tool_name ~start_time args))
;;

let handle_post_get ~tool_name ~start_time args : Tool_result.result =
  let post_id = get_string args "post_id" "" in
  match Board_dispatch.get_post_and_comments ~post_id with
  | Error (Board.Post_not_found _) ->
    (* Idempotent: post no longer exists (deleted/expired/TTL).
       Return success so agent tool metrics don't count this as failure.
       The LLM still sees a clear message that the post is gone. *)
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`String
           (Printf.sprintf "Post %s no longer exists (deleted or expired)." post_id))
      ()
  | Error e ->
    Board_tool_format.error_of_board_error ~tool_name ~start_time e
  | Ok (post, comments) ->
    let post_str = Board_tool_format.format_post post in
    let total_comments = List.length comments in
    let comment_offset = get_int args "comment_offset" 0 in
    let comment_limit = max 1 (min (get_int args "comment_limit" 50) 100) in
    let clamped_offset = max 0 (min comment_offset total_comments) in
    let sliced =
      List.filteri
        (fun i _ -> i >= clamped_offset && i < clamped_offset + comment_limit)
        comments
    in
    let has_more = clamped_offset + comment_limit < total_comments in
    let comments_str =
      if total_comments = 0
      then "\n\nNo comments."
      else (
        let shown_count = List.length sliced in
        let formatted = Board_tool_format.format_comment_tree sliced in
        let pagination =
          if has_more
          then
            Printf.sprintf
              "\n[Showing comments %d-%d of %d. Use comment_offset=%d to \
               see more.]"
              (clamped_offset + 1)
              (clamped_offset + shown_count)
              total_comments
              (clamped_offset + comment_limit)
          else if clamped_offset = 0 && shown_count = total_comments
          then Printf.sprintf "\n[Showing all %d comments.]" total_comments
          else if shown_count = 0
          then
            Printf.sprintf
              "\n[Showing comments 0 of %d. No more comments.]"
              total_comments
          else
            Printf.sprintf
              "\n[Showing comments %d-%d of %d. No more comments.]"
              (clamped_offset + 1)
              (clamped_offset + shown_count)
              total_comments
        in
        Printf.sprintf
          "\n\n**Comments (%d of %d)**:\n%s%s"
          shown_count
          total_comments
          (String.concat "\n" formatted)
          pagination)
    in
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:(`String (post_str ^ comments_str))
      ()
;;

let handle_comment_add ~tool_name ~start_time args : Tool_result.result =
  let post_id = get_string args "post_id" "" in
  let content = get_string args "content" "" in
  let author = get_string_opt args "author" |> Option.map String.trim in
  let parent_id = get_string_opt args "parent_id" in
  let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in
  if String.equal (String.trim post_id) ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "post_id is required"
  else if String.equal (String.trim content) ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "Content must not be empty"
  else if
    Option.is_none author
    || Option.equal String.equal author (Some "")
    || Option.equal String.equal author (Some "anonymous")
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "author is required"
  else if String.length content > Board.Limits.max_content_length
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
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
      (* Structured result via [Tool_result.ok]; see "Post created" note above. *)
      Tool_result.ok
        ~tool_name
        ~start_time
        (Printf.sprintf "Comment added:\n%s" (Yojson.Safe.pretty_to_string json))
    | Error e ->
      Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;
