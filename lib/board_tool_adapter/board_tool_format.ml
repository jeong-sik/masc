open Masc_board_handlers


(** Board_tool_format — formatters, parsers, JSON arg coercion,
    truncated-markdown detector, and the Yojson-error boundary shared
    across the [Board_tool] submodules. Stage 10 split. *)

(** {1 Helpers} *)

(* Board tool payloads are read by an LLM turn, not by a human watching a
   dashboard, so the same post must render to the same bytes on every call.

   The previous [format_timestamp_relative] / [format_ttl_remaining] pair read
   [Time_compat.now ()] inside functions whose signatures promised a pure
   [float -> string]: the clock was a hidden second input. A re-listed post
   therefore drifted "7m ago" -> "8m ago" while nothing about the post changed.
   Measured on one live Keeper turn: 42 [masc_board_list] calls returning the same
   878B of board state split across three distinct byte sequences, purely
   because the minute counter advanced.

   The cost is that "the board did not change" becomes unrepresentable:
   nothing downstream can collapse those calls, and the drift is a candidate
   false "state moved" signal to the reading model.

   Both now render the instant they were given, so output is a function of the
   argument alone. The keeper resolves recency against [session:wall_time],
   which [Masc_context_injector] refreshes per turn. Human-facing relative
   rendering stays in [Dashboard_labels] / [Tempo], which have a human reader
   and no cache or dedup contract. *)
let format_timestamp_absolute ts = Masc_domain.iso8601_of_unix_seconds ts

(* Reports the expiry instant rather than a remaining duration. "permanent" is
   derived from the stored [0.0] sentinel, not from the clock, so it stays
   stable too. Callers label this [expires:] rather than [TTL:] because an
   absolute timestamp must not be misread as a duration. *)
let format_expiry expires_at =
  if Stdlib.Float.compare expires_at 0.0 = 0
  then "permanent"
  else Masc_domain.iso8601_of_unix_seconds expires_at
;;

let board_error_to_string = function
  | Board.Invalid_id s -> Printf.sprintf "Invalid ID: %s" s
  | Board.Post_not_found s ->
    (* The lookup miss is the first place a caller learns the address was made
       up, so it teaches the recovery the same way [Comment_not_found] does. *)
    Printf.sprintf
      "Post not found: %s. Use an id masc_board_list or masc_board_search \
       returns; a guessed id fails here."
      s
  | Board.Comment_not_found s ->
    (* A guessed id can pass the [Comment_id] shape check — all-zero hex is
       valid hex — so this lookup miss is the first place a caller learns the
       address was made up (keeper:polisher voted c-000…0, 2026-08-24). The
       id parsers' [Invalid_id] message already names the two producers of
       real ids; the miss teaches the same recovery, not just the dead id. *)
    Printf.sprintf
      "Comment not found: %s. Use an id the masc_board_post_get comment \
       listing or the masc_board_comment result returns; a guessed id that \
       matches the c-hex shape still fails here."
      s
  | Board.Io_error s -> Printf.sprintf "I/O error: %s" s
  | Board.Validation_error s -> Printf.sprintf "Validation error: %s" s
  | Board.Already_voted s -> Printf.sprintf "Already voted: %s" s
  | Board.Already_exists s -> Printf.sprintf "Already exists: %s" s
  | Board.Unauthorized s -> Printf.sprintf "Unauthorized: %s" s
  | Board.Recipient_lookup_failed s ->
    Printf.sprintf "Recipient lookup failed, nothing was written: %s" s
;;

let board_error_failure_class = function
  | Board.Post_not_found _ | Board.Comment_not_found _
  (* Owner-gated rejection: retrying with the same actor cannot succeed,
     so it is a workflow rejection rather than a transient runtime failure. *)
  | Board.Unauthorized _
  (* The id itself has the wrong shape (a typed id parser refused it), so
     the same call can never succeed; the message names the accepted shape. *)
  | Board.Invalid_id _
  (* The store refused the request itself: empty content, a closed thread, a
     thread at its comment cap, an unsupported broadcast selector. The same
     call cannot succeed, and the message names the correction (other text, a
     successor post). Reporting it as a runtime failure told the model to
     report a fault instead of correcting the call. Server configuration
     failures and store conflicts are [Io_error], never this constructor. *)
  | Board.Validation_error _ ->
    Tool_result.Workflow_rejection
  | Board.Io_error _
  | Board.Already_voted _
  | Board.Already_exists _
  (* The Keeper settings could not be read, or two Keepers claim one alias.
     The author cannot fix that, and the same call can succeed once it is
     fixed, so it is a runtime failure. *)
  | Board.Recipient_lookup_failed _ ->
    Tool_result.Runtime_failure
;;

(* RFC-0189 PR-1b.2 — typed helper. Returns [Tool_result.result] directly
   so the [~class_] decision is committed at the catch boundary. Pre-RFC
   version returned legacy [t] with [?failure_class:option] — the new
   shape collapses two illegal states (None-on-failure, Some-on-success)
   by construction. *)
let error_of_board_error ~tool_name ~start_time e : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:(board_error_failure_class e)
    ~start_time
    (board_error_to_string e)
;;

let type_error_value_max_bytes = 120

let json_type_error_message msg bad_value =
  let value_repr =
    let s = Yojson.Safe.to_string bad_value in
    if String.length s > type_error_value_max_bytes
    then String_util.utf8_prefix ~max_bytes:type_error_value_max_bytes s ^ "…"
    else s
  in
  Printf.sprintf
    "JSON arg type error: %s. Offending value: %s. Likely cause: an \
     optional field (sources / judgment / meta / hearth / title / body) \
     was sent as a non-string JSON type. Send string-typed scalars only."
    msg
    value_repr
;;

let error_of_post_publication_failure ~tool_name ~start_time failure =
  let module Failure = Board.Post_publication_failure in
  let class_, message =
    match Failure.cause failure with
    | Failure.Board_error error ->
      board_error_failure_class error, board_error_to_string error
    | Failure.Raised (Yojson.Safe.Util.Type_error (msg, bad_value)) ->
      Tool_result.Workflow_rejection, json_type_error_message msg bad_value
    | Failure.Raised exn ->
      Tool_result.classify_from_exception exn, Printexc.to_string exn
  in
  let data =
    match Failure.committed failure with
    | None -> `Null
    | Some (creation : Board.post_creation) ->
      `Assoc
        [ "committed_post_id", `String (Board.Post_id.to_string creation.post.id) ]
  in
  Tool_result.make_err ~tool_name ~start_time ~class_ ~data
    ~effect_disposition:(Failure.effect_disposition failure)
    message
;;

(* A write answers with the names in its text that look like addresses but no
   Keeper declares, as the author wrote them.  Such a name reaches nobody, and
   this response is the only place the author learns it: the names are not
   stored.  The list is there on every write, empty when every name resolved. *)
let with_unresolved written unresolved =
  let names = `List (List.map (fun name -> `String name) unresolved) in
  match written with
  | `Assoc fields -> `Assoc (fields @ [ "unresolved", names ])
  | other -> `Assoc [ "result", other; "unresolved", names ]
;;

(* The post a write response carries: [with_unresolved] put the list beside the
   post's own fields, and the post decoder accepts an exact set of fields. *)
let post_of_write_data = function
  | `Assoc fields ->
    Board.post_of_yojson (`Assoc (List.remove_assoc "unresolved" fields))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let visibility_of_string = Board.visibility_of_string

(** {1 Formatters} *)

(* The reading agent's own vote, rendered into the listing. The vote tool
   answers a same-direction revote with "Already voted", but that answer lives
   in the turn that made it; the next turn re-reads the board, and the board
   showed no trace of the reader's vote — so the reader decided to vote again.
   Live tool-call logs carry the cost: one keeper received "Already voted"
   131 times in a day across 66 turns (task-839). *)
let viewer_vote_marker = function
  | None -> ""
  | Some Board.Up -> ", 내 투표: 👍"
  | Some Board.Down -> ", 내 투표: 👎"
;;

(* task-1758/#39356 completion criterion 4: masc_board_post_get's actual
   return path is this text formatter, not Board.post_to_yojson (a
   different, JSON-only encoder used by the HTTP/dashboard surface) -- an
   agent reading a closed post through the MCP tool must see that it is
   closed and where the successor is, or the tool's own reader has no way
   to know the thread ended. *)
let format_closed_marker (p : Board.post) =
  match p.closed with
  | None -> ""
  | Some c ->
    let successor_str =
      match c.successor_id with
      | Some sid -> Printf.sprintf " → successor: %s" (Board.Post_id.to_string sid)
      | None -> ""
    in
    Printf.sprintf " [🔒 closed by %s%s]"
      (Board.Agent_id.to_string c.closed_by)
      successor_str
;;

let format_post ?viewer_vote ~replies (p : Board.post) =
  let vis_str = Board.visibility_to_string p.visibility in
  let time_str = format_timestamp_absolute p.created_at in
  let ttl_str = format_expiry p.expires_at in
  let score = p.votes_up - p.votes_down in
  let hearth_str =
    match p.hearth with
    | Some h -> Printf.sprintf " [🔥%s]" h
    | None -> ""
  in
  let thread_str =
    match p.thread_id with
    | Some t -> Printf.sprintf " [→ Thread: %s]" t
    | None -> ""
  in
  let closed_str = format_closed_marker p in
  Printf.sprintf
    "**%s** · %s [%s]%s%s (by %s, %s, expires: %s)\n%s\n[↑%d ↓%d = %+d%s] [%d replies]%s"
    (Board.Post_id.to_string p.id)
    p.title
    vis_str
    hearth_str
    closed_str
    (Board.Agent_id.to_string p.author)
    time_str
    ttl_str
    p.body
    p.votes_up
    p.votes_down
    score
    (viewer_vote_marker viewer_vote)
    replies
    thread_str
;;

(** Compact one-line format: id, title, author, time, score. Omits
    body/TTL/visibility/thread to minimize token usage. *)
let format_post_compact ~replies (p : Board.post) =
  let time_str = format_timestamp_absolute p.created_at in
  let score = p.votes_up - p.votes_down in
  let hearth_str =
    match p.hearth with
    | Some h -> Printf.sprintf " [%s]" h
    | None -> ""
  in
  let closed_str = format_closed_marker p in
  Printf.sprintf
    "%s · %s%s%s (by %s, %s, %+d, %d replies)"
    (Board.Post_id.to_string p.id)
    p.title
    hearth_str
    closed_str
    (Board.Agent_id.to_string p.author)
    time_str
    score
    replies
;;

type search_hit =
  { full : string
  ; one_line : string
  }

let search_hit_separator = "\n---\n"

(* A search with compact=false joins every hit in full. Past the ceiling the
   caller's lane carries inline, that text is stored as a blob and the model
   reads a 200-character preview of the first post. In the 240 hours to
   2026-11-11 10:30 KST, 43 of 3,232 calls were over 16,384 bytes, all with
   compact=false, and none was read back. The first hits whose full text fits
   stay full; the rest shrink to the one-line rows a compact search returns,
   and each row starts with the post_id that masc_board_post_get reads. *)
let join_search_hits ~max_bytes ~header hits =
  let total = List.length hits in
  let full_lengths = Array.of_list (List.map (fun hit -> String.length hit.full) hits) in
  let row_lengths = Array.of_list (List.map (fun hit -> String.length hit.one_line) hits) in
  let separator_length = String.length search_hit_separator in
  let note shown =
    Printf.sprintf
      "(본문은 앞의 %d개만 실었어요. 나머지 %d개는 결과 크기 상한 때문에 한 줄로 줄였어요. \
       본문은 post_id 로 masc_board_post_get 을 불러서 읽어요.)"
      shown
      (total - shown)
  in
  let sum lengths ~from ~until =
    let acc = ref 0 in
    for i = from to until - 1 do
      acc := !acc + lengths.(i)
    done;
    !acc
  in
  (* Bytes of the text that shows the first [shown] hits in full. *)
  let length_with shown =
    let fulls =
      sum full_lengths ~from:0 ~until:shown
      + if shown > 0 then (shown - 1) * separator_length else 0
    in
    if shown = total
    then String.length header + fulls
    else (
      let rows = sum row_lengths ~from:shown ~until:total + (total - shown - 1) in
      let lead = if shown > 0 then separator_length else 0 in
      String.length header + fulls + lead + String.length (note shown) + 1 + rows)
  in
  let rec largest_fitting shown =
    if shown = 0 || length_with shown <= max_bytes then shown else largest_fitting (shown - 1)
  in
  let shown = largest_fitting total in
  let fulls = List.filteri (fun i _ -> i < shown) hits |> List.map (fun hit -> hit.full) in
  let rows = List.filteri (fun i _ -> i >= shown) hits |> List.map (fun hit -> hit.one_line) in
  match rows with
  | [] -> header ^ String.concat search_hit_separator fulls
  | _ :: _ ->
    let lead =
      match fulls with
      | [] -> ""
      | _ :: _ -> String.concat search_hit_separator fulls ^ search_hit_separator
    in
    String.concat "" [ header; lead; note shown; "\n"; String.concat "\n" rows ]
;;

let format_comment ?(indent = 0) ?viewer_vote ?reply_to (c : Board.comment) =
  let prefix = String.make indent ' ' in
  let tree_prefix = if indent > 0 then "└─ " else "" in
  let time_str = format_timestamp_absolute c.created_at in
  let reply_to_str =
    match reply_to with
    | Some parent_id -> ", reply to " ^ Board.Comment_id.to_string parent_id
    | None -> ""
  in
  let vote_str =
    (if c.votes_up > 0 || c.votes_down > 0
     then Printf.sprintf ", 👍%d 👎%d" c.votes_up c.votes_down
     else "")
    ^ viewer_vote_marker viewer_vote
  in
  (* The id is what [masc_board_comment_vote] and a threaded
     [masc_board_comment] take, and this listing is where the rejection tells a
     caller to look for it ("the id masc_board_post_get and masc_board_comment
     return"). It was not in the line. Live tool-call logs carry the cost:
     [masc_board_comment_vote] failed 160 times out of 239, and the ids sent
     were c-placeholder, c-b1, c-???, and in 28 calls the comment's own text in
     place of an id. *)
  Printf.sprintf
    "%s%s%s: %s [%s%s, %s%s]"
    prefix
    tree_prefix
    (Board.Agent_id.to_string c.author)
    c.content
    (Board.Comment_id.to_string c.id)
    reply_to_str
    time_str
    vote_str
;;

(* Indentation per nesting level, and the deepest level that still indents
   further. Only the indentation stops there: a deeper reply is drawn at the
   cap, because the page counts every comment it holds and a reader who sees
   fewer lines than that count reads it as comments gone missing. Replies run
   deeper than the cap in live threads (one post, measured 2026-09-15, has six
   comments at depth 6 to 8).

   Past the cap a reply sits at the same indentation as its parent, and a reply
   whose parent is on another page starts at the left edge like a new comment.
   Both lines name the parent's id, so neither reads as something it is not. *)
let comment_indent_width = 4
let max_comment_indent_depth = 5

module Comment_key_set = Set.Make (String)
module Comment_key_map = Map.Make (String)

let format_comment_tree
      ?(viewer_vote_of = fun (_ : Board.Comment_id.t) -> None)
      (comments : Board.comment list)
  =
  let comment_key (comment : Board.comment) = Board.Comment_id.to_string comment.id in
  let listed =
    List.fold_left
      (fun acc comment -> Comment_key_set.add (comment_key comment) acc)
      Comment_key_set.empty
      comments
  in
  let children_map =
    List.fold_left
      (fun acc (comment : Board.comment) ->
         match comment.parent_id with
         | Some parent_id ->
           let parent_key = Board.Comment_id.to_string parent_id in
           if Comment_key_set.mem parent_key listed
           then (
             let siblings =
               Comment_key_map.find_opt parent_key acc |> Option.value ~default:[]
             in
             Comment_key_map.add parent_key (comment :: siblings) acc)
           else acc
         | None -> acc)
      Comment_key_map.empty
      comments
  in
  let children_of comment =
    match Comment_key_map.find_opt (comment_key comment) children_map with
    | Some children -> List.rev children
    | None -> []
  in
  (* [under_parent] is true when the line is drawn right below its parent's
     subtree; the indentation then shows the parent up to the cap. *)
  let rec render ~under_parent depth drawn (comment : Board.comment) =
    let key = comment_key comment in
    if Comment_key_set.mem key drawn
    then drawn, []
    else (
      let drawn = Comment_key_set.add key drawn in
      let indent = comment_indent_width * min depth max_comment_indent_depth in
      let reply_to =
        match comment.parent_id, under_parent with
        | None, (true | false) -> None
        | Some _, true when depth <= max_comment_indent_depth -> None
        | Some parent_id, (true | false) -> Some parent_id
      in
      let self =
        format_comment
          ~indent
          ?viewer_vote:(viewer_vote_of comment.id)
          ?reply_to
          comment
      in
      let drawn, child_lines_rev =
        List.fold_left
          (fun (drawn, acc) child ->
             let drawn, lines = render ~under_parent:true (depth + 1) drawn child in
             drawn, List.rev_append lines acc)
          (drawn, [])
          (children_of comment)
      in
      drawn, self :: List.rev child_lines_rev)
  in
  let is_root (comment : Board.comment) =
    match comment.parent_id with
    | None -> true
    | Some parent_id ->
      not (Comment_key_set.mem (Board.Comment_id.to_string parent_id) listed)
  in
  let drawn, from_roots_rev =
    List.fold_left
      (fun (drawn, acc) comment ->
         if is_root comment
         then (
           let drawn, lines = render ~under_parent:false 0 drawn comment in
           drawn, List.rev_append lines acc)
         else drawn, acc)
      (Comment_key_set.empty, [])
      comments
  in
  (* Every listed comment is drawn exactly once. A comment reachable from no
     root (a parent chain that loops back on itself) is drawn here instead of
     disappearing; [render] skips everything the root walk already drew. *)
  let _drawn, all_lines_rev =
    List.fold_left
      (fun (drawn, acc) comment ->
         let drawn, lines = render ~under_parent:false 0 drawn comment in
         drawn, List.rev_append lines acc)
      (drawn, from_roots_rev)
      comments
  in
  List.rev all_lines_rev
;;

(** {1 Source-entry rendering} *)

let normalize_source_string s =
  s
  |> String.trim
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun part -> not (String.equal part ""))
  |> String.concat " "
;;

let sources_footer sources =
  let line_of_source = function
    | `Assoc fields ->
      (match List.assoc_opt "url" fields with
       | Some (`String url) ->
         let quote =
           match List.assoc_opt "quote" fields with
           | Some (`String value) when not (String.equal value "") ->
             " - \"" ^ value ^ "\""
           | _ -> ""
         in
         Some ("- <" ^ url ^ ">" ^ quote)
       | _ -> None)
    | _ -> None
  in
  match List.filter_map line_of_source sources with
  | [] -> ""
  | lines -> "\n\n---\n## Sources\n" ^ String.concat "\n" lines
;;

(** {1 Sort order}

    Issue #8449 PR B: [sort_order] re-exports [Board_dispatch.sort_order]
    (type-alias with definition equality). Constructors are
    interchangeable across modules — no conversion needed.
    [parse_sort_order] delegates to
    [Board_dispatch.sort_order_of_string_opt] for canonical sort names;
    error message derives from
    [Board_dispatch.valid_sort_order_strings] so adding a constructor
    automatically updates the user-facing list. *)
type sort_order = Board_dispatch.sort_order =
  | Hot
  | Trending
  | Recent
  | Updated
  | Discussed

let parse_sort_order value =
  match Board_dispatch.sort_order_of_string_opt value with
  | Some s -> Ok s
  | None ->
    Error
      (Printf.sprintf
         "invalid sort. Valid: %s"
         (String.concat ", " Board_dispatch.valid_sort_order_strings))
;;

(** {1 JSON argument coercion}

    Normalize incoming Yojson payloads before handlers run; keeps
    handler bodies focused on [Board_dispatch] calls. *)

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> not (String.equal name key)) fields
;;

let judgment_arg args =
  let value_of key =
    match Option.value ~default:(`Null) (Json_util.assoc_member_opt key args) with
    | `Null -> None
    | `String value when String.equal (String.trim value) "" -> None
    | `String _ as value -> Some value
    | `Assoc _ as value -> Some value
    | `List _ as value -> Some value
    | (`Bool _ | `Int _ | `Intlit _ | `Float _) as other ->
      (* RFC-0093 Phase B Step 4: coerce scalar types to string instead of
         silently dropping them.  LLMs occasionally send judgment: 42 or
         judgment: true; coercing preserves the data. *)
      let coerced = Yojson.Safe.to_string other in
      Log.BoardLog.warn
        "judgment_arg: coerced non-string judgment %s to string for key %S"
        (Yojson.Safe.to_string other) key;
      Some (`String coerced)
  in
  match value_of "judgment" with
  | Some _ as value -> value
  | None -> value_of "judgement"
;;

let normalize_board_post_meta ?(attachments = []) args =
  let base_fields =
    match Option.value ~default:(`Null) (Json_util.assoc_member_opt "meta" args) with
    | `Assoc fields ->
      List.filter (fun (key, _) -> not (String.equal key "attachments")) fields
    | `Null -> []
    | other ->
      (* RFC-0093 Phase B Step 3: split permissive `_ -> []` into typed
         arms.  `Null` is the legitimate "meta field absent" path; any
         other JSON type means the caller passed a wrong-typed meta and
         should be surfaced rather than silently dropped. *)
      Log.BoardLog.warn
        "normalize_board_post_meta: ignoring non-object meta argument: %s"
        (Yojson.Safe.to_string other);
      []
  in
  let base_fields =
    match Tool_args.get_string_opt args "classification_reason" with
    | Some reason -> assoc_replace "classification_reason" (`String reason) base_fields
    | None -> base_fields
  in
  let base_fields =
    match judgment_arg args with
    | Some judgment -> assoc_replace "judgment" judgment base_fields
    | None -> base_fields
  in
  let base_fields =
    match attachments with
    | [] -> base_fields
    | entries ->
      assoc_replace
        "attachments"
        (`List (List.map Board_tool_attachment.to_json entries))
        base_fields
  in
  if Stdlib.List.length base_fields = 0 then None else Some (`Assoc base_fields)
;;

let source_entries_arg args =
  let source_entry = function
    | `Assoc fields ->
      (match List.assoc_opt "url" fields with
       | Some (`String raw_url) ->
         let url = String.trim raw_url in
         if String.equal url ""
         then None
         else (
           let quote =
             match List.assoc_opt "quote" fields with
             | Some (`String value) ->
               let normalized = normalize_source_string value in
               if String.equal normalized "" then None else Some normalized
             | _ -> None
           in
           Some
             (`Assoc
                 (("url", `String url)
                  ::
                  (match quote with
                   | Some value -> [ "quote", `String value ]
                   | None -> []))))
       | _ -> None)
    | _ -> None
  in
  match Json_util.assoc_member_opt "sources" args with
  | None | Some `Null -> None
  | Some (`List values) ->
    (match List.filter_map source_entry values with
     | [] -> None
     | entries -> Some entries)
  | Some (`Assoc fields) ->
    (* Single Assoc sent instead of a List — wrap it. *)
    (match source_entry (`Assoc fields) with
     | Some entry ->
       Log.BoardLog.warn
         "source_entries_arg: wrapped single Assoc into List for sources";
       Some [ entry ]
     | None -> None)
  | Some other ->
    Log.BoardLog.warn
      "source_entries_arg: ignoring non-List/non-Object sources: %s"
      (Json_util.kind_name other);
    None
;;

let merge_sources_into_meta meta_json sources =
  let fields =
    match meta_json with
    | Some (`Assoc fields) -> fields
    | _ -> []
  in
  let fields = assoc_replace "sources" (`List sources) fields in
  let fields = assoc_replace "has_external_sources" (`Bool true) fields in
  Some (`Assoc fields)
;;

let assoc_field fields key = List.assoc_opt key fields

let string_field fields key default =
  match assoc_field fields key with
  | Some (`String value) -> String.trim value
  | _ -> default
;;

let float_field fields key default =
  match assoc_field fields key with
  | Some (`Float value) when Float.is_finite value -> value
  | Some (`Int value) -> float_of_int value
  | Some (`String value) ->
    (match Float.of_string_opt (String.trim value) with
     | Some parsed when Float.is_finite parsed -> parsed
     | _ -> default)
  | _ -> default
;;

let string_list_field fields key =
  match assoc_field fields key with
  | Some (`List values) ->
    values
    |> List.filter_map (function
      | `String value ->
        let trimmed = String.trim value in
        if String.equal trimmed "" then None else Some trimmed
      | _ -> None)
  | _ -> []
;;

let trim_nonempty_string = String_util.trim_nonempty

let string_opt_arg args key =
  Option.bind (Tool_args.get_string_opt args key) trim_nonempty_string
;;

let string_list_arg args key =
  Tool_args.get_string_list args key |> List.filter_map trim_nonempty_string
;;

let object_list_arg args key =
  match args with
  | `Assoc fields ->
    (match assoc_field fields key with
     | Some (`List values) ->
       values
       |> List.filter_map (function
         | `Assoc fields -> Some fields
         | _ -> None)
     | _ -> [])
  | _ -> []
;;

let provenance_arg args =
  match args with
  | `Assoc fields ->
    (match assoc_field fields "provenance" with
     | Some (`Assoc _ as json) -> Ok json
     | Some other ->
       Error
         (Printf.sprintf
            "provenance must be an object (received %s)"
            (Json_util.kind_name other))
     | _ -> Ok (`Assoc []))
  | _ -> Ok (`Assoc [])
;;

(** {1 Yojson-error boundary}

    Convert a stray [Yojson.Safe.Util.Type_error] from a board-tool
    handler into a structured [Tool_result.error] so the MCP transport
    sees a typed message rather than an opaque exception payload (cf.
    task-213 board post p-1efba4b2311478dff37fff9fdbfea483, example-keeper
    broadcast 2026-05-15T10:51:20Z). Diagnostic, not a workaround: the
    offending value field points the next triager at the failing
    field. *)
let with_yojson_boundary ~tool_name ~start_time handler : Tool_result.result =
  try handler () with
  | Yojson.Safe.Util.Type_error (msg, bad_value) ->
    (* RFC-0189 — JSON type error is caller-input shape violation.
       Workflow_rejection (not Runtime_failure) because the request itself
       was malformed at the JSON layer; retrying with the same args won't
       succeed. *)
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      (json_type_error_message msg bad_value)
;;
