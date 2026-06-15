(** Forward-looking continuity summary filtering.

    Input is rendered free-text summary prose (one classification per line), not
    a structured keeper snapshot record. Leaf-level detection therefore inspects
    line text, but the classification {b dispatch} is a closed variant
    ({!line_kind}) matched exhaustively: every line is mapped to exactly one kind
    and {!should_keep} decides keep/drop per kind. Adding a new kind forces a
    compile-time decision instead of an implicit catch-all default. *)

let strip_prefix_ci ~(prefix : string) (s : string) : string option =
  let s = String.trim s in
  let plen = String.length prefix in
  if String.length s < plen then None
  else
    let head = String.sub s 0 plen |> String.lowercase_ascii in
    if head = String.lowercase_ascii prefix then
      Some (String.sub s plen (String.length s - plen) |> String.trim)
    else
      None

(** Why a summary line is classified. Closed sum: every line maps to exactly
    one constructor. Adding a kind forces a {!should_keep} update at compile
    time (no catch-all drop/keep default). *)
type line_kind =
  | Blank  (** whitespace-only after trim *)
  | Backward  (** Done:/Progress:/Decisions: prefixed retrospective line *)
  | Inert_next  (** Next:/Next plan: pointing at an idle/no-op directive *)
  | Stale_tool_surface  (** stale claim about the available tool surface *)
  | Stale_goal_capacity  (** stale goal-cap / goal-capacity claim *)
  | Forward_content  (** live forward-looking content to keep *)

let backward_labels = [ "Done"; "Progress"; "Decisions" ]

let inert_next_markers =
  [
    "stay_silent";
    "stay silent";
    "wait for new actionable work";
    "nothing to do";
    "no actionable work";
    "do nothing";
    "all non-destructive actions exhausted";
    "대기 유지";
    "침묵";
    "할 일 없음";
    "아무것도 하지";
  ]

let stale_tool_surface_markers =
  [
    "masc_* only";
    "mcp__masc__ only";
    "no keeper_* tools";
    "no keeper tools";
    "tool surface: masc";
    "tool-surface: masc";
  ]

let stale_goal_capacity_markers =
  [
    "goal cap";
    "goal_cap";
    "goal capacity";
    "active_goal_ids";
    "새 작업 못";
    "작업 못 받";
  ]

let strip_labeled_value ~prefixes line =
  let trimmed = String.trim line in
  let rec loop = function
    | [] -> None
    | prefix :: rest -> (
        match strip_prefix_ci ~prefix trimmed with
        | Some value -> Some value
        | None -> loop rest)
  in
  loop prefixes

let is_backward_line line =
  let trimmed = String.trim line in
  List.exists
    (fun label ->
      let prefix = label ^ ":" in
      String.starts_with trimmed ~prefix)
    backward_labels

let is_inert_next_line line =
  match strip_labeled_value ~prefixes:[ "Next plan:"; "Next:" ] line with
  | None -> false
  | Some value ->
      let payload = String.trim value in
      payload <> ""
      && List.exists
           (fun marker -> String_util.contains_substring_ci payload marker)
           inert_next_markers

let is_stale_tool_surface_line line =
  let payload = String.trim line in
  String_util.contains_substring_ci payload "tool"
  && (List.exists
        (fun marker -> String_util.contains_substring_ci payload marker)
        stale_tool_surface_markers
      || (String_util.contains_substring_ci payload "only"
          && (String_util.contains_substring_ci payload "allowed tool"
              || String_util.contains_substring_ci payload "available tool"
              || String_util.contains_substring_ci payload "allowed tool"
              || String_util.contains_substring_ci payload "tool surface"
              || String_util.contains_substring_ci payload "tool-surface")))

let is_stale_goal_capacity_line line =
  let payload = String.trim line in
  List.exists
    (fun marker -> String_util.contains_substring_ci payload marker)
    stale_goal_capacity_markers

(** Map a line to its single {!line_kind}. Drop-kinds are tested first; a line
    matching none of them and not blank is [Forward_content]. The keep/drop
    outcome is independent of the test order because every drop-kind resolves to
    [false] in {!should_keep}. *)
let classify (line : string) : line_kind =
  if String.trim line = "" then Blank
  else if is_backward_line line then Backward
  else if is_inert_next_line line then Inert_next
  else if is_stale_tool_surface_line line then Stale_tool_surface
  else if is_stale_goal_capacity_line line then Stale_goal_capacity
  else Forward_content

(** Exhaustive match: every constructor decided explicitly, no catch-all. *)
let should_keep : line_kind -> bool = function
  | Forward_content -> true
  | Blank -> false
  | Backward -> false
  | Inert_next -> false
  | Stale_tool_surface -> false
  | Stale_goal_capacity -> false

let filter_forward_looking_summary (summary : string) : string =
  let kept =
    summary
    |> String.split_on_char '\n'
    |> List.filter (fun line -> should_keep (classify line))
  in
  match kept with
  | [] -> ""
  | _ -> String.concat "\n" kept
