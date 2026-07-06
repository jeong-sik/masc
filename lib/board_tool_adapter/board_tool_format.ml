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

(** Board_tool_format — formatters, parsers, JSON arg coercion,
    truncated-markdown detector, and the Yojson-error boundary shared
    across the [Board_tool] submodules. Stage 10 split. *)

(** Strip [STATE]...[/STATE] blocks. Inlined to avoid the
    Keeper_prompt dependency cycle via Keeper_alerting. *)
let strip_state_blocks_text (s : string) : string =
  let start_marker = "[STATE]" in
  let end_marker = "[/STATE]" in
  let start_re = Re.str start_marker |> Re.compile in
  let end_re = Re.str end_marker |> Re.compile in
  let len = String.length s in
  let rec loop from (buf : Buffer.t) =
    if from >= len
    then ()
    else (
      match Re.exec_opt ~pos:from start_re s with
      | Some g ->
        let i = Re.Group.start g 0 in
        if i > from then Stdlib.Buffer.add_substring buf s from (i - from);
        let block_start = i + String.length start_marker in
        let next_from =
          match Re.exec_opt ~pos:block_start end_re s with
          | Some g2 -> Re.Group.start g2 0 + String.length end_marker
          | None -> len
        in
        loop next_from buf
      | None -> Stdlib.Buffer.add_substring buf s from (len - from))
  in
  let buf = Buffer.create len in
  loop 0 buf;
  Buffer.contents buf
;;

(** {1 Helpers} *)

let raw_agent_name_meta_key ~field = field ^ "_raw_agent_name"
let author_raw_agent_name_meta_key = raw_agent_name_meta_key ~field:"author"

let format_timestamp_relative ts =
  let now = Time_compat.now () in
  let diff = now -. ts in
  if Stdlib.Float.compare diff 60.0 < 0
  then "just now"
  else if Stdlib.Float.compare diff Masc_time_constants.hour < 0
  then Printf.sprintf "%dm ago" (Stdlib.Int.of_float (diff /. 60.0))
  else if Stdlib.Float.compare diff Masc_time_constants.day < 0
  then Printf.sprintf "%dh ago" (Stdlib.Int.of_float (diff /. Masc_time_constants.hour))
  else Printf.sprintf "%dd ago" (Stdlib.Int.of_float (diff /. Masc_time_constants.day))
;;

let format_ttl_remaining expires_at =
  if Stdlib.Float.compare expires_at 0.0 = 0
  then "permanent"
  else (
    let now = Time_compat.now () in
    let remaining = expires_at -. now in
    if Stdlib.Float.compare remaining 0.0 <= 0
    then "expired"
    else if Stdlib.Float.compare remaining Masc_time_constants.hour < 0
    then Printf.sprintf "%dm left" (Stdlib.Int.of_float (remaining /. 60.0))
    else if Stdlib.Float.compare remaining Masc_time_constants.day < 0
    then Printf.sprintf "%dh left" (Stdlib.Int.of_float (remaining /. Masc_time_constants.hour))
    else
      Printf.sprintf
        "%dd left"
        (Stdlib.Int.of_float (remaining /. Masc_time_constants.day)))
;;

let board_error_to_string = function
  | Board.Invalid_id s -> Printf.sprintf "Invalid ID: %s" s
  | Board.Post_not_found s -> Printf.sprintf "Post not found: %s" s
  | Board.Comment_not_found s -> Printf.sprintf "Comment not found: %s" s
  | Board.Rate_limited { retry_after } ->
    Printf.sprintf "Rate limited. Retry after %.1fs" retry_after
  | Board.Capacity_exceeded { current; max } ->
    Printf.sprintf "Capacity exceeded: %d/%d" current max
  | Board.Io_error s -> Printf.sprintf "I/O error: %s" s
  | Board.Validation_error s -> Printf.sprintf "Validation error: %s" s
  | Board.Already_voted s -> Printf.sprintf "Already voted: %s" s
  | Board.Already_exists s -> Printf.sprintf "Already exists: %s" s
  | Board.Unauthorized s -> Printf.sprintf "Unauthorized: %s" s
;;

let board_error_failure_class = function
  | Board.Post_not_found _ | Board.Comment_not_found _
  (* Owner-gated rejection: retrying with the same actor cannot succeed,
     so it is a workflow rejection rather than a transient runtime failure. *)
  | Board.Unauthorized _ ->
    Tool_result.Workflow_rejection
  | _ -> Tool_result.Runtime_failure
;;

(* RFC-0189 PR-1b.2 — typed helper. Returns [Tool_result.result] directly
   so the [~class_] decision is committed at the catch boundary instead
   of going through [classify_from_structured_failure_message]. Pre-RFC
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

let visibility_of_string = Board.visibility_of_string

(** {1 Formatters} *)

let format_post (p : Board.post) =
  let vis_str = Board.visibility_to_string p.visibility in
  let time_str = format_timestamp_relative p.created_at in
  let ttl_str = format_ttl_remaining p.expires_at in
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
  Printf.sprintf
    "**%s** · %s [%s]%s (by %s, %s, TTL: %s)\n%s\n[↑%d ↓%d = %+d] [%d replies]%s"
    (Board.Post_id.to_string p.id)
    p.title
    vis_str
    hearth_str
    (Board.Agent_id.to_string p.author)
    time_str
    ttl_str
    p.body
    p.votes_up
    p.votes_down
    score
    p.reply_count
    thread_str
;;

(** Compact one-line format: id, title, author, time, score. Omits
    body/TTL/visibility/thread to minimize token usage. *)
let format_post_compact (p : Board.post) =
  let time_str = format_timestamp_relative p.created_at in
  let score = p.votes_up - p.votes_down in
  let hearth_str =
    match p.hearth with
    | Some h -> Printf.sprintf " [%s]" h
    | None -> ""
  in
  Printf.sprintf
    "%s · %s%s (by %s, %s, %+d, %d replies)"
    (Board.Post_id.to_string p.id)
    p.title
    hearth_str
    (Board.Agent_id.to_string p.author)
    time_str
    score
    p.reply_count
;;

let format_comment ?(indent = 0) (c : Board.comment) =
  let prefix = String.make indent ' ' in
  let tree_prefix = if indent > 0 then "└─ " else "" in
  let time_str = format_timestamp_relative c.created_at in
  let vote_str =
    if c.votes_up > 0 || c.votes_down > 0
    then Printf.sprintf ", 👍%d 👎%d" c.votes_up c.votes_down
    else ""
  in
  Printf.sprintf
    "%s%s%s: %s [%s%s]"
    prefix
    tree_prefix
    (Board.Agent_id.to_string c.author)
    c.content
    time_str
    vote_str
;;

(** Format comments as a tree, grouping replies under parents.
    [max_depth] limits nesting (default 5); beyond that, comments
    render flat. *)
let format_comment_tree ?(max_depth = 5) (comments : Board.comment list) =
  let visible_comment_ids = Hashtbl.create (List.length comments) in
  let children_map = Hashtbl.create (List.length comments) in
  let comment_id = Board.Comment_id.to_string in
  List.iter
    (fun (comment : Board.comment) ->
       Hashtbl.replace visible_comment_ids (comment_id comment.id) true)
    comments;
  List.iter
    (fun (comment : Board.comment) ->
       match comment.parent_id with
       | Some parent_id ->
         let key = comment_id parent_id in
         let existing = Hashtbl.find_opt children_map key |> Option.value ~default:[] in
         Hashtbl.replace children_map key (comment :: existing)
       | None -> ())
    comments;
  let roots =
    List.filter
      (fun (comment : Board.comment) ->
         match comment.parent_id with
         | None -> true
         | Some parent_id -> not (Hashtbl.mem visible_comment_ids (comment_id parent_id)))
      comments
  in
  let children_of parent_id =
    Hashtbl.find_opt children_map (comment_id parent_id)
    |> Option.value ~default:[]
    |> List.rev
  in
  let rec render depth indent (c : Board.comment) =
    let self = format_comment ~indent c in
    if depth >= max_depth
    then [ self ] (* Stop recursing; children rendered flat at next level. *)
    else (
      let kids = children_of c.id in
      self :: List.concat_map (render (depth + 1) (indent + 4)) kids)
  in
  List.concat_map (render 0 0) roots
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

(** {1 Truncated-markdown detection}

    Walk the string once with a small state machine aware of fenced
    code blocks (markers inside ``` ... ``` don't count) and inline
    code spans (so bold markers inside ` ... ` don't count). Return
    the FIRST signal found; that name is logged so audits can see
    WHICH pattern triggered. New signals are added conservatively
    (#9777). Evidence: ani1999 p-c0494a2e body_len=467 trailing
    backtick (Odd_inline_tick); automation-agent body_len=3575
    (Odd_fence). *)

type truncation_signal =
  | Odd_fence (** odd count of triple-backtick code fences. *)
  | Odd_inline_tick (** odd count of single backticks outside fences. *)
  | Unfinished_link (** trailing text-open-paren with no closing paren. *)
  | Unfinished_image (** trailing image-alt-open-paren with no closing paren. *)
  | Odd_double_asterisk (** odd count of double-asterisks outside fences (unclosed bold). *)

let truncation_signal_to_string = function
  | Odd_fence -> "odd_fence"
  | Odd_inline_tick -> "odd_inline_tick"
  | Unfinished_link -> "unfinished_link"
  | Unfinished_image -> "unfinished_image"
  | Odd_double_asterisk -> "odd_double_asterisk"
;;

(* Underscore- and single-asterisk-based emphasis NOT counted —
   identifiers, file paths, inline math frequently carry odd counts. *)
let detect_truncated_markdown_with_reason (text : string) : truncation_signal option =
  let len = String.length text in
  let in_fence = ref false in
  let in_inline = ref false in
  let inline_outside = ref 0 in
  let fences = ref 0 in
  let double_ast_outside = ref 0 in
  let i = ref 0 in
  while !i < len do
    if
      !i + 2 < len
      && Char.equal text.[!i] '`'
      && Char.equal text.[!i + 1] '`'
      && Char.equal text.[!i + 2] '`'
    then (
      Stdlib.incr fences;
      in_fence := not !in_fence;
      i := !i + 3)
    else if
      !i + 1 < len
      && Char.equal text.[!i] '*'
      && Char.equal text.[!i + 1] '*'
      && (not !in_fence)
      && not !in_inline
    then (
      Stdlib.incr double_ast_outside;
      i := !i + 2)
    else (
      if Char.equal text.[!i] '`' && not !in_fence
      then (
        Stdlib.incr inline_outside;
        in_inline := not !in_inline);
      Stdlib.incr i)
  done;
  let odd n = Int.rem n 2 = 1 in
  if odd !fences
  then Some Odd_fence
  else if odd !inline_outside
  then Some Odd_inline_tick
  else if odd !double_ast_outside
  then Some Odd_double_asterisk
  else (
    (* Trailing fragment heuristic: link `[text](url)` with missing
       `)` before EOF is a strong truncation signal. *)
    let last_open_paren = ref (-1) in
    let last_close_paren = ref (-1) in
    for j = len - 1 downto 0 do
      if !last_open_paren < 0 && Char.equal text.[j] '(' then last_open_paren := j;
      if !last_close_paren < 0 && Char.equal text.[j] ')' then last_close_paren := j
    done;
    if !last_open_paren > !last_close_paren && !last_open_paren > 0
    then (
      (* `]` byte before `(` distinguishes markdown link/image from prose paren. *)
      let bracket_pos = !last_open_paren - 1 in
      if bracket_pos >= 0 && Char.equal text.[bracket_pos] ']'
      then (
        (* Image `![alt](url)` distinguished by `!` before `[`. *)
        let is_image =
          let scan = ref (bracket_pos - 1) in
          let saw_image = ref false in
          (* Find the matching `[` for this `]`; bail at newline. *)
          while
            !scan >= 0
            && (not (Char.equal text.[!scan] '['))
            && not (Char.equal text.[!scan] '\n')
          do
            Stdlib.decr scan
          done;
          if
            !scan >= 0
            && Char.equal text.[!scan] '['
            && !scan > 0
            && Char.equal text.[!scan - 1] '!'
          then saw_image := true;
          !saw_image
        in
        Some (if is_image then Unfinished_image else Unfinished_link))
      else None)
    else None)
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
        "judgment_arg: coerced non-string/judgment %s to string for key %S"
        (Yojson.Safe.to_string other) key;
      Some (`String coerced)
  in
  match value_of "judgment" with
  | Some _ as value -> value
  | None -> value_of "judgement"
;;

let normalize_board_post_meta args =
  let base_fields =
    match Option.value ~default:(`Null) (Json_util.assoc_member_opt "meta" args) with
    | `Assoc fields -> fields
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

let trim_nonempty_string value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

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
    task-213 board post p-1efba4b2311478dff37fff9fdbfea483, sangsu
    broadcast 2026-05-15T10:51:20Z). Diagnostic, not a workaround: the
    offending value field points the next triager at the failing
    field. *)
let with_yojson_boundary ~tool_name ~start_time handler : Tool_result.result =
  try handler () with
  | Yojson.Safe.Util.Type_error (msg, bad_value) ->
    let value_repr =
      let s = Yojson.Safe.to_string bad_value in
      if String.length s > 120 then String.sub s 0 120 ^ "…" else s
    in
    (* RFC-0189 — JSON type error is caller-input shape violation.
       Workflow_rejection (not Runtime_failure) because the request itself
       was malformed at the JSON layer; retrying with the same args won't
       succeed. *)
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      (Printf.sprintf
         "JSON arg type error: %s. Offending value: %s. Likely cause: an \
          optional field (sources / judgment / meta / hearth / title / body) \
          was sent as a non-string JSON type. Send string-typed scalars only."
         msg
         value_repr)
;;
