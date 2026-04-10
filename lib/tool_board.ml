(** Tool_board - MCP tool handlers for MASC Internal Board

    Hardened implementation using Board module:
    - All errors are explicit (no silent failures)
    - TTL support for posts and comments
    - Visibility control (Public/Unlisted/Internal/Direct)
    - Capacity limits enforced

    Replaces tool_social.ml for new installations.
*)

open Tool_args

(** Strip [STATE]...[/STATE] blocks from text (inlined to avoid
    Keeper_prompt dependency which creates a cycle via Keeper_alerting). *)
let strip_state_blocks_text (s : string) : string =
  let start_marker = "[STATE]" in
  let end_marker = "[/STATE]" in
  let start_re = Re.str start_marker |> Re.compile in
  let end_re = Re.str end_marker |> Re.compile in
  let len = String.length s in
  let rec loop from (buf : Buffer.t) =
    if from >= len then ()
    else
      match Re.exec_opt ~pos:from start_re s with
      | Some g ->
        let i = Re.Group.start g 0 in
        if i > from then Buffer.add_substring buf s from (i - from);
        let block_start = i + String.length start_marker in
        let next_from =
          match Re.exec_opt ~pos:block_start end_re s with
          | Some g2 -> Re.Group.start g2 0 + String.length end_marker
          | None -> len
        in
        loop next_from buf
      | None ->
        Buffer.add_substring buf s from (len - from)
  in
  let buf = Buffer.create len in
  loop 0 buf;
  Buffer.contents buf

type result = bool * string


(** {1 Helpers} *)

let format_timestamp_relative ts =
  let now = Time_compat.now () in
  let diff = now -. ts in
  if diff < 60.0 then "just now"
  else if diff < 3600.0 then Printf.sprintf "%dm ago" (int_of_float (diff /. 60.0))
  else if diff < Masc_time_constants.day then Printf.sprintf "%dh ago" (int_of_float (diff /. 3600.0))
  else Printf.sprintf "%dd ago" (int_of_float (diff /. Masc_time_constants.day))

let format_ttl_remaining expires_at =
  if expires_at = 0.0 then "permanent"
  else
  let now = Time_compat.now () in
  let remaining = expires_at -. now in
  if remaining <= 0.0 then "expired"
  else if remaining < 3600.0 then Printf.sprintf "%dm left" (int_of_float (remaining /. 60.0))
  else if remaining < Masc_time_constants.day then Printf.sprintf "%dh left" (int_of_float (remaining /. 3600.0))
  else Printf.sprintf "%dd left" (int_of_float (remaining /. Masc_time_constants.day))

let board_error_to_string = function
  | Board.Invalid_id s -> Printf.sprintf "Invalid ID: %s" s
  | Board.Post_not_found s -> Printf.sprintf "Post not found: %s" s
  | Board.Comment_not_found s -> Printf.sprintf "Comment not found: %s" s
  | Board.Rate_limited { retry_after } -> Printf.sprintf "Rate limited. Retry after %.1fs" retry_after
  | Board.Capacity_exceeded { current; max } -> Printf.sprintf "Capacity exceeded: %d/%d" current max
  | Board.Io_error s -> Printf.sprintf "I/O error: %s" s
  | Board.Validation_error s -> Printf.sprintf "Validation error: %s" s
  | Board.Already_voted s -> Printf.sprintf "Already voted: %s" s

let visibility_of_string = function
  | "public" -> Some Board.Public
  | "unlisted" -> Some Board.Unlisted
  | "internal" -> Some Board.Internal
  | "direct" -> Some Board.Direct
  | _ -> None

(** Agent lookup callback — set once at server startup with the real
    Room.is_agent_joined check so that board posts are auto-classified
    without requiring callers to pass config or post_kind. *)
let agent_lookup_hook : (string -> bool) option Atomic.t = Atomic.make None

let set_agent_lookup f = Atomic.set agent_lookup_hook (Some f)
let set_agent_lookup_none () = Atomic.set agent_lookup_hook None



(** Check whether [name] is a registered agent.  Uses the registry
    lookup (Room.is_agent_joined) when available via [agent_lookup_hook];
    returns [false] when no hook is installed. *)
let is_agent name =
  match Atomic.get agent_lookup_hook with
  | Some lookup -> lookup name
  | None -> false

let resolve_board_post_kind ~author (raw_kind : string option) :
    (Board.post_kind, string) Stdlib.result =
  match raw_kind with
  | Some raw ->
      (match Board.post_kind_of_string (String.lowercase_ascii (String.trim raw)) with
       | Some Board.System_post ->
           Error "system posts are reserved for internal surfaces (keeper, operator)"
       | Some kind -> Ok kind
       | None -> Error (Printf.sprintf "unknown post_kind: %s" raw))
  | None ->
      let author_lc = String.lowercase_ascii (String.trim author) in
      if author_lc = "" || author_lc = "anonymous" then
        (* Missing or default author is never direct/manual — classify as
           automation to prevent misleading direct-attributed posts (#4604). *)
        Ok Board.Automation_post
      else
        (match Atomic.get agent_lookup_hook with
         | Some _ when is_agent author_lc -> Ok Board.Automation_post
         | _ -> Ok Board.Human_post)

(** {1 Formatters} *)

let format_post (p : Board.post) =
  let vis_str = Board.visibility_to_string p.visibility in
  let time_str = format_timestamp_relative p.created_at in
  let ttl_str = format_ttl_remaining p.expires_at in
  let score = p.votes_up - p.votes_down in
  let hearth_str = match p.hearth with Some h -> Printf.sprintf " [🔥%s]" h | None -> "" in
  let thread_str = match p.thread_id with Some t -> Printf.sprintf " [→ Thread: %s]" t | None -> "" in
  Printf.sprintf "**%s** · %s [%s]%s (by %s, %s, TTL: %s)\n%s\n[↑%d ↓%d = %+d] [%d replies]%s"
    (Board.Post_id.to_string p.id)
    p.title
    vis_str
    hearth_str
    (Board.Agent_id.to_string p.author)
    time_str
    ttl_str
    p.body
    p.votes_up p.votes_down score
    p.reply_count
    thread_str

(** Compact one-line format for board_list: id, title, author, time, score.
    Omits body, TTL, visibility, thread to minimize token usage. *)
let format_post_compact (p : Board.post) =
  let time_str = format_timestamp_relative p.created_at in
  let score = p.votes_up - p.votes_down in
  let hearth_str = match p.hearth with Some h -> Printf.sprintf " [%s]" h | None -> "" in
  Printf.sprintf "%s · %s%s (by %s, %s, %+d, %d replies)"
    (Board.Post_id.to_string p.id)
    p.title
    hearth_str
    (Board.Agent_id.to_string p.author)
    time_str
    score
    p.reply_count

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

(** Format comments as a tree structure, grouping replies under parents.
    max_depth limits nesting (default 5). Beyond that, comments render flat. *)
let format_comment_tree ?(max_depth=5) (comments : Board.comment list) =
  let visible_comment_ids = Hashtbl.create (List.length comments) in
  let children_map = Hashtbl.create (List.length comments) in
  let comment_id = Board.Comment_id.to_string in
  List.iter (fun (comment : Board.comment) ->
    Hashtbl.replace visible_comment_ids (comment_id comment.id) true
  ) comments;
  List.iter (fun (comment : Board.comment) ->
    match comment.parent_id with
    | Some parent_id ->
        let key = comment_id parent_id in
        let existing = Hashtbl.find_opt children_map key |> Option.value ~default:[] in
        Hashtbl.replace children_map key (comment :: existing)
    | None -> ()
  ) comments;
  let roots =
    List.filter (fun (comment : Board.comment) ->
      match comment.parent_id with
      | None -> true
      | Some parent_id -> not (Hashtbl.mem visible_comment_ids (comment_id parent_id))
    ) comments
  in
  let children_of parent_id =
    Hashtbl.find_opt children_map (comment_id parent_id)
    |> Option.value ~default:[]
    |> List.rev
  in
  let rec render depth indent (c : Board.comment) =
    let self = format_comment ~indent c in
    if depth >= max_depth then
      [self]  (* Stop recursing; children rendered flat at next level *)
    else
      let kids = children_of c.id in
      self :: List.concat_map (render (depth + 1) (indent + 4)) kids
  in
  List.concat_map (render 0 0) roots

(** {1 Handlers} *)

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> name <> key) fields

let judgment_arg args =
  let value_of key =
    match Yojson.Safe.Util.member key args with
    | `Null -> None
    | `String value when String.trim value = "" -> None
    | `String _ as value -> Some value
    | `Assoc _ as value -> Some value
    | _ -> None
  in
  match value_of "judgment" with
  | Some _ as value -> value
  | None -> value_of "judgement"

let normalize_board_post_meta args =
  let base_fields =
    match Yojson.Safe.Util.member "meta" args with
    | `Assoc fields -> fields
    | _ -> []
  in
  let base_fields =
    match get_string_opt args "classification_reason" with
    | Some reason -> assoc_replace "classification_reason" (`String reason) base_fields
    | None -> base_fields
  in
  let base_fields =
    match judgment_arg args with
    | Some judgment -> assoc_replace "judgment" judgment base_fields
    | None -> base_fields
  in
  if base_fields = [] then None else Some (`Assoc base_fields)

let handle_post_create args =
  let title = get_string_opt args "title" in
  (* Reject empty or whitespace-only titles *)
  match title with
  | Some t when String.trim t = "" ->
      (false, "Title must not be empty or whitespace-only")
  | _ ->
  let body = get_string_opt args "body" |> Option.map strip_state_blocks_text in
  let raw_content = match body with Some value -> value | None -> get_string args "content" "" in
  let content = strip_state_blocks_text raw_content in
  let author = get_string_opt args "author" |> Option.map String.trim in
  let title_is_empty =
    match title with
    | Some value -> String.trim value = ""
    | None -> false
  in
  if title_is_empty then
    (false, "❌ title is required")
  else if author = None || author = Some "" || author = Some "anonymous" then
    (false, "❌ author is required")
  else if String.length content > Board.Limits.max_content_length then
    (false, Printf.sprintf "Content exceeds max length (%d > %d chars)"
       (String.length content) Board.Limits.max_content_length)
  else
  let author = Option.value author ~default:"" in
  let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in
  let visibility_str = get_string args "visibility" "internal" in
  let hearth = get_string_opt args "hearth" in
  let thread_id = get_string_opt args "thread_id" in
  let raw_post_kind = get_string_opt args "post_kind" in
  let meta_json = normalize_board_post_meta args in

  let visibility = match visibility_of_string visibility_str with
    | Some v -> v
    | None -> Board.Internal
  in
  match resolve_board_post_kind ~author raw_post_kind with
  | Error msg -> (false, "❌ " ^ msg)
  | Ok post_kind ->
      match
        Board_dispatch.create_post ~author ~content ?title ?body ~post_kind ?meta_json
          ~visibility ~ttl_hours ?hearth ?thread_id ()
      with
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

let parse_sort_order value =
  match String.lowercase_ascii (String.trim value) with
  | "hot" -> Ok Hot
  | "trending" -> Ok Trending
  | "recent" | "new" -> Ok Recent
  | "updated" | "active" -> Ok Updated
  | "discussed" | "comments" -> Ok Discussed
  | _ -> Error "invalid sort. Valid: hot, trending, recent, updated, discussed"

let dispatch_sort_of sort_by =
  match sort_by with
  | Hot -> Board_dispatch.Hot
  | Trending -> Board_dispatch.Trending
  | Recent -> Board_dispatch.Recent
  | Updated -> Board_dispatch.Updated
  | Discussed -> Board_dispatch.Discussed

let handle_post_list args =
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
        if s = "" then None else Some s
    | None -> None
  in
  let since = get_float_opt args "since" in

  let visibility_filter = match visibility_str with
    | Some s -> visibility_of_string s
    | None -> None
  in
  let sort_by_result =
    match sort_arg with
    | None -> Ok Hot
    | Some value -> parse_sort_order value
  in
  match sort_by_result with
  | Error msg -> (false, Printf.sprintf "❌ %s" msg)
  | Ok sort_by ->
      (* Fetch exactly what we need: offset posts to skip + limit posts to show.
         Board_dispatch.list_posts already applies visibility/hearth/author filters. *)
      let fetch_limit = limit + offset in
      let sorted_posts =
        Board_dispatch.list_posts ~visibility_filter ?hearth ?author_filter
          ~exclude_system ~exclude_automation
          ~sort_by:(dispatch_sort_of sort_by) ~limit:fetch_limit ()
      in

      let posts =
        if random then
          (* Shuffle via random-key sort (unbiased, unlike comparator trick) *)
          let shuffled = List.map (fun p -> (Random.bits (), p)) sorted_posts
            |> List.sort (fun (a, _) (b, _) -> compare a b)
            |> List.map snd in
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
          let fmt = if compact then format_post_compact else format_post in
          fmt p ^ indicator
        in
        let formatted = List.map format_post_with_indicator posts in
        let sort_label = match sort_by with
          | Hot -> "🔥 Hot"
          | Trending -> "📈 Trending"
          | Recent -> "🕐 Recent"
          | Updated -> "🔄 Recently Updated"
          | Discussed -> "💬 Most Discussed"
        in
        let separator = if compact then "\n" else "\n\n---\n\n" in
        let mode_label = if compact then " (compact)" else "" in
        let header = Printf.sprintf "📋 Posts (%d) — %s%s:" (List.length posts) sort_label mode_label in
        (true, header ^ "\n" ^ String.concat separator formatted)

let handle_post_get args =
  let post_id = get_string args "post_id" "" in

  match Board_dispatch.get_post ~post_id with
  | Error (Board.Post_not_found _) ->
      (* Idempotent: post no longer exists (deleted/expired/TTL).
         Return success so keeper tool metrics don't count this as failure.
         The LLM still sees a clear message that the post is gone. *)
      (true, Printf.sprintf "📭 Post %s no longer exists (deleted or expired)." post_id)
  | Error e -> (false, Printf.sprintf "❌ %s" (board_error_to_string e))
  | Ok post ->
      match Board_dispatch.get_comments ~post_id with
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
  let post_id = get_string args "post_id" "" in
  let content = get_string args "content" "" in
  let author = get_string_opt args "author" |> Option.map String.trim in
  let parent_id = get_string_opt args "parent_id" in
  let ttl_hours = get_int args "ttl_hours" Board.Limits.default_ttl_hours in
  if String.trim post_id = "" then
    (false, "post_id is required")
  else if String.trim content = "" then
    (false, "Content must not be empty")
  else if author = None || author = Some "" || author = Some "anonymous" then
    (false, "author is required")
  else if String.length content > Board.Limits.max_content_length then
    (false, Printf.sprintf "Content exceeds max length (%d > %d chars)"
       (String.length content) Board.Limits.max_content_length)
  else
  match Board_dispatch.add_comment ~post_id ~author:(Option.value author ~default:"")
          ~content ?parent_id ~ttl_hours () with
  | Ok comment ->
      let json = Board.comment_to_yojson comment in
      (true, Printf.sprintf "✅ Comment added:\n%s" (Yojson.Safe.pretty_to_string json))
  | Error e ->
      (false, Printf.sprintf "❌ %s" (board_error_to_string e))

(** SOUL Evolution callback - registered at startup to break dependency cycle *)
type evolution_callback = {
  get_primary_value: string -> string option;
  record_feedback: name:string -> dimension:string -> is_positive:bool -> unit;
}

let evolution_hook : evolution_callback option Atomic.t = Atomic.make None

let register_evolution_callback cb =
  Atomic.set evolution_hook (Some cb)

let handle_vote args =
  let post_id = get_string args "post_id" "" in
  let voter = get_string args "voter" "anonymous" in
  let direction_str =
    let from_direction = get_string args "direction" "" in
    if from_direction <> "" then from_direction else get_string args "vote" "up"
  in

  let direction = if direction_str = "down" then Board.Down else Board.Up in

  match Board_dispatch.vote ~voter ~post_id ~direction with
  | Ok new_score ->
      let arrow = if direction = Board.Up then "↑" else "↓" in
      (* SOUL Evolution via callback (breaks compile-time dependency cycle) *)
      let evolution_msg =
        match Atomic.get evolution_hook with
        | None -> ""  (* Not initialized yet *)
        | Some cb ->
            match Board_dispatch.get_post ~post_id with
            | Ok post ->
                let author = Board.Agent_id.to_string post.author in
                (* Agent-only evolution: 에이전트끼리만 서로 진화시킴 *)
                if is_agent voter && is_agent author then begin
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
  | Error (Board.Already_voted _) ->
      (* Idempotent: same-direction duplicate vote is a no-op success.
         The desired state already exists, so the tool call succeeds. *)
      (match Board_dispatch.get_post ~post_id with
       | Ok post ->
           let score = post.votes_up - post.votes_down in
           let arrow = if direction = Board.Up then "↑" else "↓" in
           (true, Printf.sprintf "%s Already voted (idempotent). Score: %+d" arrow score)
       | Error _ ->
           (true, "Already voted (idempotent). Score unchanged."))
  | Error e ->
      (false, Printf.sprintf "❌ %s" (board_error_to_string e))

let handle_stats _args =
  let stats = Board_dispatch.stats () in
  (true, Printf.sprintf "📊 Board Stats:\n%s" (Yojson.Safe.pretty_to_string stats))

(** Search posts by keyword *)
let handle_search args =
  let query = get_string args "query" "" in
  let limit = get_int args "limit" 20 |> max 1 |> min 100 in
  let compact = get_bool args "compact" true in
  if query = "" then (false, "❌ query required")
  else
    let results = Board_dispatch.search ~query ~limit in
    if results = [] then (true, Printf.sprintf "🔍 '%s' 검색 결과 없음" query)
    else
      let fmt = if compact then format_post_compact else format_post in
      let formatted = List.map fmt results in
      let separator = if compact then "\n" else "\n---\n" in
      (true, Printf.sprintf "🔍 '%s' 검색 결과 (%d개):\n\n%s" query (List.length results) (String.concat separator formatted))

(** Vote on comment *)
let handle_comment_vote args =
  let comment_id = get_string args "comment_id" "" in
  let voter = get_string args "voter" "anonymous" in
  let direction_str = get_string args "direction" "up" in
  let direction = if direction_str = "down" then Board.Down else Board.Up in
  if comment_id = "" then (false, "❌ comment_id required")
  else
    match Board_dispatch.vote_comment ~voter ~comment_id ~direction with
    | Ok score -> (true, Printf.sprintf "%s 코멘트 투표 완료! 점수: %+d" (if direction_str = "down" then "👎" else "👍") score)
    | Error (Board.Already_voted _) ->
        (true, Printf.sprintf "%s Already voted (idempotent)." (if direction_str = "down" then "👎" else "👍"))
    | Error e -> (false, Printf.sprintf "❌ %s" (board_error_to_string e))

(** Agent profile *)
let handle_profile args =
  let agent = get_string args "agent" "" in
  if agent = "" then (false, "❌ agent required")
  else
    let all_posts : Board.post list = Board_dispatch.list_posts ~limit:1000 () in
    let norm s = String.lowercase_ascii (String.trim s) in
    let agent_norm = norm agent in
    let agent_posts = List.filter (fun (p : Board.post) -> norm (Board.Agent_id.to_string p.author) = agent_norm) all_posts in
    let post_votes = List.fold_left (fun acc (p : Board.post) -> acc + p.votes_up - p.votes_down) 0 agent_posts in
    let all_comments : Board.comment list = Board_dispatch.list_comments () in
    let agent_comments = List.filter (fun (c : Board.comment) -> norm (Board.Agent_id.to_string c.author) = agent_norm) all_comments in
    let comment_votes = List.fold_left (fun acc (c : Board.comment) -> acc + c.votes_up - c.votes_down) 0 agent_comments in
    (true, Printf.sprintf "📊 **%s** 프로필\n📝 게시물: %d개 (%+d점)\n💬 코멘트: %d개 (%+d점)\n⭐ 총: %+d점"
      agent (List.length agent_posts) post_votes (List.length agent_comments) comment_votes (post_votes + comment_votes))

(** Hearth list *)
let handle_hearth_list _args =
  let hearths = Board_dispatch.list_hearths () in
  if hearths = [] then (true, "🔥 No active hearths.")
  else
    let formatted = List.map (fun (name, count) ->
      Printf.sprintf "🔥 **%s** (%d posts)" name count
    ) hearths in
    (true, Printf.sprintf "🔥 Active Hearths:\n%s" (String.concat "\n" formatted))

(** {1 Tool Definitions} *)

let tool_post_create : Types.tool_schema = {
  name = "masc_board_post";
  description = "Create a direct/manual post on the MASC internal board for sharing updates, questions, or knowledge with other agents. Keeper and internal automation surfaces use narrower adapters.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("title", `Assoc [("type", `String "string"); ("description", `String "Optional post title")]);
      ("body", `Assoc [("type", `String "string"); ("description", `String "Canonical visible body text")]);
      ("content", `Assoc [("type", `String "string"); ("description", `String "Post content (max 4000 chars)")]);
      ("author", `Assoc [("type", `String "string"); ("description", `String "Author name")]);
      ("meta", `Assoc [("type", `String "object"); ("description", `String "Optional structured operational metadata")]);
      ("classification_reason", `Assoc [("type", `String "string"); ("description", `String "Optional explicit classification rationale; persisted into meta and surfaced by the dashboard")]);
      ("judgment", `Assoc [("type", `String "object"); ("description", `String "Optional structured LLM judgment metadata. Use summary/reason/confidence keys when you want the board to retain your classification rationale")]);
      ("visibility", `Assoc [("type", `String "string"); ("description", `String "public|unlisted|internal|direct (default: internal)")]);
      ("ttl_hours", `Assoc [("type", `String "integer"); ("description", `String "Time-to-live in hours (default: 168, max: 720)")]);
      ("hearth", `Assoc [("type", `String "string"); ("description", `String "Topic hearth name (e.g. webrtc, code-review)")]);
      ("thread_id", `Assoc [("type", `String "string"); ("description", `String "Linked conversation thread ID")]);
    ]);
    ("required", `List [`String "content"; `String "author"]);
  ];
}

let tool_post_list : Types.tool_schema = {
  name = "masc_board_list";
  description = "List posts on the MASC internal board with sorting options";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max posts to return"); ("default", `Int 20); ("minimum", `Int 1); ("maximum", `Int 100)]);
      ("visibility", `Assoc [("type", `String "string"); ("enum", `List [`String "public"; `String "unlisted"; `String "internal"; `String "direct"]); ("description", `String "Filter by visibility")]);
      ("hearth", `Assoc [("type", `String "string"); ("maxLength", `Int 100); ("description", `String "Filter by hearth topic (e.g. webrtc, code-review)")]);
      ("random", `Assoc [("type", `String "boolean"); ("description", `String "Shuffle posts randomly (default: false)")]);
      ("offset", `Assoc [("type", `String "integer"); ("description", `String "Skip first N posts (default: 0)"); ("minimum", `Int 0); ("maximum", `Int 1000)]);
      ("sort_by", `Assoc [("type", `String "string"); ("enum", `List [`String "hot"; `String "trending"; `String "recent"; `String "updated"; `String "discussed"]); ("description", `String "Sort order (default: hot)")]);
      ("exclude_system", `Assoc [("type", `String "boolean"); ("description", `String "Exclude system posts like Activity Reports (default: false)")]);
      ("exclude_automation", `Assoc [("type", `String "boolean"); ("description", `String "Exclude automation posts (heartbeat, probes, etc.) (default: false)")]);
      ("author", `Assoc [("type", `String "string"); ("maxLength", `Int 100); ("description", `String "Filter posts by author name (case-insensitive substring match)")]);
      ("since", `Assoc [("type", `String "number"); ("description", `String "Unix timestamp. Posts with activity after this time show a 🔔 indicator")]);
      ("compact", `Assoc [("type", `String "boolean"); ("default", `Bool true); ("description", `String "Compact one-line per post. Set false for full body/TTL/visibility")]);
    ]);
  ];
}

let tool_post_get : Types.tool_schema = {
  name = "masc_board_get";
  description = "Get a specific post with its full comment thread. Use when you want to read discussion context before replying, or when you received a post_id from board_list/search.";
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
  description = "Add a comment to an existing board post. Use after reading a post with board_get to contribute your perspective, ask a question, or provide feedback.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID (format: p-xxxx...). Get from keeper_board_list results.")]);
      ("content", `Assoc [("type", `String "string"); ("maxLength", `Int 4000); ("description", `String "Comment content")]);
      ("author", `Assoc [("type", `String "string"); ("description", `String "Author name")]);
      ("parent_id", `Assoc [("type", `String "string"); ("description", `String "Parent comment ID for replies (optional)")]);
      ("ttl_hours", `Assoc [("type", `String "integer"); ("description", `String "Time-to-live in hours")]);
    ]);
    ("required", `List [`String "post_id"; `String "content"; `String "author"]);
  ];
}

let tool_vote : Types.tool_schema = {
  name = "masc_board_vote";
  description = "Vote on a board post (up or down) to signal agreement or quality. Use when you find a post valuable or want to deprioritize noise.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID (format: p-xxxx...). Get from keeper_board_list results.")]);
      ("voter", `Assoc [("type", `String "string"); ("description", `String "Voter name")]);
      ("direction", `Assoc [("type", `String "string"); ("description", `String "up or down (default: up)")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_stats : Types.tool_schema = {
  name = "masc_board_stats";
  description = "Get board activity statistics: total posts, comments, votes, active hearths. Use to understand overall board health and engagement levels.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}

let tool_search : Types.tool_schema = {
  name = "masc_board_search";
  description = "Search board posts by keyword across titles and content. Use when looking for specific topics, past discussions, or related prior work.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("query", `Assoc [("type", `String "string"); ("maxLength", `Int 200); ("description", `String "Search keyword")]);
      ("limit", `Assoc [("type", `String "integer"); ("default", `Int 20); ("minimum", `Int 1); ("maximum", `Int 100); ("description", `String "Max results")]);
      ("compact", `Assoc [("type", `String "boolean"); ("default", `Bool true); ("description", `String "Compact one-line per post. Set false for full body")]);
    ]);
    ("required", `List [`String "query"]);
  ];
}

let tool_comment_vote : Types.tool_schema = {
  name = "masc_board_comment_vote";
  description = "Vote on a comment (up or down) to signal agreement or quality. Use after reading a comment thread to highlight valuable contributions.";
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
  description = "Get an agent's board profile: post count, comment count, vote activity, and engagement stats. Use to understand an agent's contribution patterns.";
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

let handle_delete args =
  let post_id = String.trim (get_string args "post_id" "") in
  if post_id = "" then
    (false, "post_id is required")
  else
    match Board_dispatch.delete_post ~post_id with
    | Ok () -> (true, Printf.sprintf "Deleted post %s" post_id)
    | Error e -> (false, Printf.sprintf "Delete failed: %s" (board_error_to_string e))

let handle_board_cleanup args =
  let max_age_hours = get_int args "max_age_hours" 24 |> max 1 in
  let require_no_comments = get_bool args "require_no_comments" true in
  let require_no_votes = get_bool args "require_no_votes" true in
  let dry_run = get_bool args "dry_run" true in
  let limit = get_int args "limit" 10 |> max 1 |> min 50 in
  let title_pattern = get_string_opt args "title_pattern" in
  let author_pattern = get_string_opt args "author_pattern" in
  let now = Time_compat.now () in
  let age_threshold = now -. (float_of_int max_age_hours *. 3600.0) in
  let title_re = Option.map (fun p ->
    Re.str (String.lowercase_ascii p) |> Re.compile) title_pattern in
  let author_re = Option.map (fun p ->
    Re.str (String.lowercase_ascii p) |> Re.compile) author_pattern in
  let matches_opt re s =
    match re with
    | None -> true
    | Some compiled -> Re.execp compiled (String.lowercase_ascii s)
  in
  let all_posts =
    Board_dispatch.list_posts ~sort_by:Recent ~limit:500 ()
  in
  let candidates =
    List.filter (fun (p : Board.post) ->
      p.created_at < age_threshold
      && (not require_no_comments || p.reply_count = 0)
      && (not require_no_votes || (p.votes_up = 0 && p.votes_down = 0))
      && matches_opt title_re p.title
      && matches_opt author_re (Board.Agent_id.to_string p.author))
      all_posts
  in
  let targets = List.filteri (fun i _ -> i < limit) candidates in
  if dry_run then begin
    let count = List.length targets in
    if count = 0 then
      (true, Printf.sprintf "Scan complete: 0 candidates (scanned %d posts, age>%dh)"
         (List.length all_posts) max_age_hours)
    else
      let lines = List.map (fun (p : Board.post) ->
        Printf.sprintf "  - %s | %s | by %s | %s | replies=%d votes=%d"
          (Board.Post_id.to_string p.id)
          p.title
          (Board.Agent_id.to_string p.author)
          (format_timestamp_relative p.created_at)
          p.reply_count
          (p.votes_up + p.votes_down))
        targets
      in
      (true, Printf.sprintf "Dry-run: %d candidates (scanned %d, age>%dh):\n%s"
         count (List.length all_posts) max_age_hours
         (String.concat "\n" lines))
  end else begin
    let deleted = ref 0 in
    let failed = ref 0 in
    List.iter (fun (p : Board.post) ->
      let pid = Board.Post_id.to_string p.id in
      (try
        match Board_dispatch.delete_post ~post_id:pid with
        | Ok () -> incr deleted
        | Error _ -> incr failed
      with _exn -> incr failed))
      targets;
    (true, Printf.sprintf "Cleanup done: %d deleted, %d failed (scanned %d, age>%dh)"
       !deleted !failed (List.length all_posts) max_age_hours)
  end

let tool_delete : Types.tool_schema = {
  name = "masc_board_delete";
  description = "Delete a board post and its associated comments and votes. Use for cleanup of stale, test, or expired posts.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "ID of the post to delete")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_board_cleanup : Types.tool_schema = {
  name = "masc_board_cleanup";
  description = "Scan board posts matching filter criteria and delete or report them. \
Defaults to dry_run=true (report only). Set dry_run=false to delete. \
Safety: never deletes posts with comments or votes unless filters are overridden.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("max_age_hours", `Assoc [
        ("type", `String "integer");
        ("description", `String "Only target posts older than this (default: 24)");
      ]);
      ("require_no_comments", `Assoc [
        ("type", `String "boolean");
        ("description", `String "Only target posts with 0 replies (default: true)");
      ]);
      ("require_no_votes", `Assoc [
        ("type", `String "boolean");
        ("description", `String "Only target posts with 0 votes (default: true)");
      ]);
      ("title_pattern", `Assoc [
        ("type", `String "string");
        ("description", `String "Substring filter on post title (case-insensitive)");
      ]);
      ("author_pattern", `Assoc [
        ("type", `String "string");
        ("description", `String "Substring filter on post author (case-insensitive)");
      ]);
      ("dry_run", `Assoc [
        ("type", `String "boolean");
        ("description", `String "If true (default), only report candidates without deleting");
      ]);
      ("limit", `Assoc [
        ("type", `String "integer");
        ("description", `String "Max posts to process (default: 10, max: 50)");
      ]);
    ]);
    ("required", `List []);
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
  tool_delete;
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
  | "masc_board_delete" -> handle_delete args
  | "masc_board_cleanup" -> handle_board_cleanup args
  | _ -> (false, Printf.sprintf "Unknown tool: %s" name)

let tool_spec_read_only =
  [
    "masc_board_list";
    "masc_board_get";
    "masc_board_stats";
    "masc_board_search";
    "masc_board_profile";
    "masc_board_hearths";
  ]

let register () =
  let handler = fun ~name ~args -> Some (handle_tool name args) in
  let make_spec (s : Types.tool_schema) =
    let ro = List.mem s.name tool_spec_read_only in
    Tool_spec.create
      ~name:s.name ~description:s.description
      ~module_tag:Tool_dispatch.Mod_inline ~input_schema:s.input_schema
      ~handler_binding:(Shared handler)
      ~is_read_only:ro ~is_idempotent:ro
      ()
  in
  Tool_spec.register_all (List.map make_spec tools)
