open Masc_board_handlers


(** Board_tool_post — post-lifecycle handlers (create / list / get /
    comment_add).

    Stage 10 split of lib/board_tool_adapter/board_tool.ml — sub-domain split out of
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
    let body_arg = get_string_opt args "body" in
    let raw_content =
      match body_arg with
      | Some value -> value
      | None -> get_string args "content" ""
    in
    let sources = Board_tool_format.source_entries_arg args in
    let content =
      match sources with
      | Some entries when not (String.equal (String.trim raw_content) "") ->
        raw_content ^ Board_tool_format.sources_footer entries
      | _ -> raw_content
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
    else
      match author with
      | None ->
        Tool_result.make_err
          ~tool_name
          ~class_:Tool_result.Workflow_rejection
          ~start_time
          "author is required"
      | Some author ->
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
      match Board_tool_handlers.resolve_board_post_kind raw_post_kind with
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
              Tool_result.make_ok ~tool_name ~start_time ~data:json ()
         | Error e ->
           Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;

let handle_post_edit ~tool_name ~start_time args : Tool_result.result =
  let post_id = get_string args "post_id" "" in
  (* Mirror create's body/content handling and let [body] win over [content]. *)
  let body_arg = get_string_opt args "body" in
  let raw_content =
    match body_arg with
    | Some value -> value
    | None -> get_string args "content" ""
  in
  let content = raw_content in
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
      let new_author = get_string_opt args "new_author" in
      (match Board_dispatch.update_post ~post_id ~editor ~content ?title ?body ?new_author () with
       | Ok post ->
         let json = Board.post_to_yojson post in
         Tool_result.make_ok ~tool_name ~start_time ~data:json ()
       | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e))
;;

let handle_post_list ~tool_name ~start_time args : Tool_result.result =
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
        (* A listing does not read threads; the stored count is its only
           source for how many replies each post has. *)
        let fmt (post : Board.post) =
          if compact
          then Board_tool_format.format_post_compact ~replies:post.reply_count post
          else Board_tool_format.format_post ~replies:post.reply_count post
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

(* A thread read is cut into pages, and a page is as large as the reader of
   this call carries inline. A Keeper call names the projection its lane
   resolved: the official-client lane stores a result above
   [Common.max_tool_result_wire_bytes] as a blob, the agent-core lane only
   above [Common.max_agent_core_inline_result_bytes]. A count alone cannot
   promise either: a live comment runs about 1.4KB (median of 6,847, measured
   2026-09-15), so 50 of them are several times the lower ceiling, and a
   result over it becomes a blob the Keeper has to fetch back with
   keeper_artifact_read before it can read the thread.

   A caller outside a Keeper turn (an MCP client, an HTTP route) is bounded by
   the same wire ceiling: MASC stores nothing for it, and the client that
   reads threads is a CLI harness that spills a larger result to a file.

   What the model reads is the thread as text. A result whose data is a JSON
   object reaches the model as that object serialized on one line
   ([Tool_result.message]), which is how a page of comments became
   [{"pagination":{...},"thread":"**p-…**\n\n…"}] — the escaped wrapper a
   Keeper cannot read a thread through. The page's position rides the result's
   metadata instead, so a caller continuing the read never parses the text.
   The size is measured on that text, the same bytes the boundary compares.
   [comment_limit] stays an upper bound a caller can ask for. *)
let render_thread ~post_block ~total ~comment_lines =
  match comment_lines, total with
  | [], 0 -> Printf.sprintf "%s\n\nNo comments." post_block
  (* The end of a thread that has comments: the position line already says
     none are newer and where they will start. *)
  | [], _ -> post_block
  | _ :: _, _ ->
    Printf.sprintf "%s\n\n**Comments**:\n%s" post_block (String.concat "\n" comment_lines)
;;

let handle_post_get ~result_boundary ~tool_name ~start_time args : Tool_result.result =
  let post_id = get_string args "post_id" "" in
  (* Injected by the MCP dispatch from the caller's own identity, never
     model-supplied (same rewrite as vote's [voter]). Absent on paths with no
     caller identity, which render no marker. *)
  let viewer = get_string_opt args "viewer" in
  (* A vote-store read error degrades to "no marker" rather than failing the
     whole read: the listing's tallies are still current, and the marker is a
     projection of the reader's own durable vote, not a gate. *)
  let viewer_vote_of_comment comment_id =
    Option.bind viewer (fun voter ->
      match
        Board_dispatch.current_vote_for_comment
          ~voter
          ~comment_id:(Board.Comment_id.to_string comment_id)
      with
      | Ok vote -> vote
      | Error _ -> None)
  in
  let viewer_vote_of_post post_id =
    Option.bind viewer (fun voter ->
      match
        Board_dispatch.current_vote_for_post
          ~voter
          ~post_id:(Board.Post_id.to_string post_id)
      with
      | Ok vote -> vote
      | Error _ -> None)
  in
  match Board.Comment_page.request_of_args args with
  | Error error ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      (Board.Comment_page.request_error_to_string error)
  | Ok request ->
    (match Board_dispatch.get_post_and_comments ~post_id with
     | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e
     | Ok (post, comments) ->
       let total = List.length comments in
       (* The reply count in the header is the length of the list this read
          pages through, not the stored [reply_count], so the header and the
          page's [total] cannot disagree. The body travels on the first page;
          a continuation page names the post in one line. *)
       let requested_offset = request.Board.Comment_page.offset in
       let post_block =
         match requested_offset with
         | 0 ->
           Board_tool_format.format_post
             ?viewer_vote:(viewer_vote_of_post post.id)
             ~replies:total
             post
         | _ -> Board_tool_format.format_post_compact ~replies:total post
       in
       (* Each vote is read once; the page is re-rendered while it grows. *)
       let votes = Hashtbl.create (List.length comments) in
       let viewer_vote_of comment_id =
         let key = Board.Comment_id.to_string comment_id in
         match Hashtbl.find_opt votes key with
         | Some vote -> vote
         | None ->
           let vote = viewer_vote_of_comment comment_id in
           Hashtbl.replace votes key vote;
           vote
       in
       (* The position leads the page so a reader that sees only the head of a
          stored result still learns where the next page starts. *)
       let page_text (page : Board.comment Board.Comment_page.page) =
         let position = Board.Comment_page.Position.of_page page in
         Printf.sprintf
           "%s\n%s"
           (Board.Comment_page.Position.line position)
           (render_thread
              ~post_block
              ~total:page.Board.Comment_page.total
              ~comment_lines:
                (Board_tool_format.format_comment_tree
                   ~viewer_vote_of
                   page.Board.Comment_page.items))
       in
       let ceiling = Tool_output.result_ceiling_bytes result_boundary in
       let fits page = String.length (page_text page) <= ceiling in
       (match Board.Comment_page.select ~fits request comments with
        | Board.Comment_page.Offset_out_of_range { requested; total } ->
          Tool_result.make_err
            ~tool_name
            ~class_:Tool_result.Workflow_rejection
            ~start_time
            (match total with
             | 0 ->
               Printf.sprintf
                 "comment_offset %d names no comment of %s: the thread has no \
                  comments. Read it with comment_offset=0."
                 requested
                 (Board.Post_id.to_string post.id)
             | _ ->
               Printf.sprintf
                 "comment_offset %d names no comment of %s: the thread now has %d \
                  comments, at offsets 0-%d. Start again from comment_offset=0."
                 requested
                 (Board.Post_id.to_string post.id)
                 total
                 (total - 1))
        | Board.Comment_page.Page page ->
          Tool_result.make_ok
            ~tool_name
            ~start_time
            ~data:(`String (page_text page))
            ~metadata:
              (Board.Comment_page.Position.to_metadata
                 (Board.Comment_page.Position.of_page page))
            ()))
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
  else
    match author with
    | None ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        "author is required"
    | Some author ->
      (match
         Board_dispatch.add_comment
           ~post_id
           ~author
           ~content
           ?parent_id
           ~ttl_hours
           ()
       with
       | Ok comment ->
         let json = Board.comment_to_yojson comment in
         Tool_result.make_ok ~tool_name ~start_time ~data:json ()
       | Error e ->
         Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;
