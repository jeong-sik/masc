(** Mitosis_dna — DNA extraction, compression, delta merge, and continuity anchors.

    These are the core context-transfer operations used during mitosis:
    compress context to DNA, extract continuity anchors, merge prepared DNA
    with delta changes, and generate mentor wisdom for successor cells. *)

(** Safe substring extraction - never throws, returns empty on invalid range *)
let safe_sub s start len =
  let s_len = String.length s in
  if start < 0 || len < 0 || start >= s_len then ""
  else
    let actual_len = min len (s_len - start) in
    if actual_len <= 0 then ""
    else String.sub s start actual_len

(* Cap handoff context to a fixed approximate token budget. *)
let handoff_token_budget = 20000

let handoff_max_chars () =
  (* Approximate 4 chars/token for safety. *)
  handoff_token_budget * 4

let truncate_to_handoff_budget context =
  let max_chars = handoff_max_chars () in
  let context_len = String.length context in
  if context_len <= max_chars then context
  else
    let truncated = safe_sub context (context_len - max_chars) max_chars in
    Printf.sprintf
      "[... context truncated to %d-token budget: showing latest context ...]\n%s"
      handoff_token_budget
      truncated

let starts_with_ci ~prefix s =
  let p = String.lowercase_ascii prefix in
  let t = String.lowercase_ascii (String.trim s) in
  let lp = String.length p in
  String.length t >= lp && String.sub t 0 lp = p

let first_line_with_prefixes ~prefixes lines =
  let rec loop = function
    | [] -> None
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "" then
          loop rest
        else if List.exists (fun p -> starts_with_ci ~prefix:p trimmed) prefixes then
          Some trimmed
        else
          loop rest
  in
  loop lines

let take_last_non_empty_lines ~count text =
  let non_empty =
    String.split_on_char '\n' text
    |> List.fold_left (fun acc line ->
      let trimmed = String.trim line in
      if trimmed = "" then acc else trimmed :: acc
    ) []
    |> List.rev
  in
  let len = List.length non_empty in
  let drop_n = max 0 (len - count) in
  let rec drop n xs =
    if n <= 0 then xs
    else
      match xs with
      | [] -> []
      | _ :: rest -> drop (n - 1) rest
  in
  drop drop_n non_empty

let build_continuity_anchors full_context =
  let normalize_anchor_line s =
    let max_len = 240 in
    let trimmed = String.trim s in
    if String.length trimmed <= max_len then trimmed
    else safe_sub trimmed 0 max_len ^ "..."
  in
  let lines = String.split_on_char '\n' full_context in
  let goal_line =
    first_line_with_prefixes
      ~prefixes:["goal:"; "goal -"; "objective:"; "north star:"]
      lines
  in
  let task_line =
    first_line_with_prefixes
      ~prefixes:["current task:"; "current_task:"; "task:"; "now:"]
      lines
  in
  let recent_lines = take_last_non_empty_lines ~count:3 full_context in
  let anchor_lines =
    []
    |> fun acc ->
    (match goal_line with Some line -> acc @ [normalize_anchor_line line] | None -> acc)
    |> fun acc ->
    (match task_line with Some line -> acc @ [normalize_anchor_line line] | None -> acc)
    |> fun acc ->
    if recent_lines = [] then acc
    else
      acc
      @ ("Recent turns:"
         :: List.map (fun line -> "- " ^ normalize_anchor_line line) recent_lines)
  in
  match anchor_lines with
  | [] -> ""
  | _ ->
      String.concat "\n" (
        ["=== CONTINUITY ANCHORS ==="] @ anchor_lines @ ["=== END CONTINUITY ANCHORS ==="; ""]
      )

(** Compress context into DNA for transfer *)
let compress_to_dna ~ratio ~context =
  (* Clamp ratio to valid range [0.0, 1.0] *)
  let ratio = Float.max 0.0 (Float.min 1.0 ratio) in
  (* Continuity-aware compression: keep both head and tail *)
  let len = String.length context in
  let target_len = int_of_float (float_of_int len *. ratio) in
  if target_len <= 0 then
    ""
  else if target_len >= len then
    context
  else if target_len < 200 then
    safe_sub context 0 target_len
  else
    let head_len = max 1 (int_of_float (float_of_int target_len *. 0.6)) in
    let tail_len = max 1 (target_len - head_len) in
    if head_len + tail_len >= len then
      context
    else
      let head = safe_sub context 0 head_len in
      let tail = safe_sub context (len - tail_len) tail_len in
      String.concat "\n\n" [head; "[... middle context omitted ...]"; tail]

(** String Set for O(log n) lookup instead of O(n) List.mem *)
module StringSet = Set.Make(String)

(** Lazy line sequence from string - avoids full split allocation. *)
let lines_seq s =
  let len = String.length s in
  let rec find_line start () =
    if start >= len then Seq.Nil
    else
      match String.index_from_opt s start '\n' with
      | Some newline_pos ->
          let line = String.sub s start (newline_pos - start) in
          Seq.Cons (line, find_line (newline_pos + 1))
      | None ->
          let line = String.sub s start (len - start) in
          Seq.Cons (line, fun () -> Seq.Nil)
  in
  find_line 0

(** Simple line-based deduplication for merge - O(n log n) with lazy Seq. *)
let deduplicate_lines ~base ~delta =
  let base_set =
    lines_seq base
    |> Seq.fold_left (fun acc line ->
        let trimmed = String.trim line in
        if String.length trimmed > 10 then
          StringSet.add trimmed acc
        else acc
      ) StringSet.empty
  in
  lines_seq delta
  |> Seq.filter (fun line ->
      let trimmed = String.trim line in
      String.length trimmed <= 10 || not (StringSet.mem trimmed base_set))
  |> List.of_seq
  |> String.concat "\n"

(** Merge prepared DNA with delta from 50%->80% window *)
let merge_dna_with_delta ~prepared_dna ~delta =
  if String.length delta = 0 then
    prepared_dna
  else
    let deduped_delta = deduplicate_lines ~base:prepared_dna ~delta in
    let deduped_len = String.length deduped_delta in
    let original_len = String.length delta in
    if deduped_len < original_len then
      Log.debug ~ctx:"mitosis/merge" "Deduplication: %d -> %d chars (-%d%% overlap)"
        original_len deduped_len ((original_len - deduped_len) * 100 / original_len);
    if String.length (String.trim deduped_delta) = 0 then
      prepared_dna
    else
      Printf.sprintf "%s\n\n## Recent Updates (Delta)\n\n%s" prepared_dna deduped_delta

(* ================================================================ *)
(* DNA Quality Validation (#3072)                                    *)
(* ================================================================ *)

(** Quality dimensions for mitosis DNA validation.
    Each dimension scores [0.0, 1.0] and contributes to the overall score
    with its assigned weight.

    Goal anchor (0.30): Without a goal, the child agent has no purpose.
    Task anchor (0.20): Current task provides immediate focus.
    Content coherence (0.25): Truncation artifacts indicate damaged context.
    Minimum length (0.15): Below ~200 chars, DNA carries too little signal.
    Recent context (0.10): Recent turns help the child continue work. *)
type dna_quality = {
  has_goal_anchor : bool;
  has_task_anchor : bool;
  has_recent_context : bool;
  truncation_artifacts : int;
  content_length : int;
  score : float;
}

(** Detect truncation artifacts: mid-sentence cuts, orphan brackets, etc.
    Returns count of detected artifacts. *)
let count_truncation_artifacts (dna : string) : int =
  let lines = String.split_on_char '\n' dna in
  let last_non_empty =
    lines
    |> List.rev
    |> List.find_opt (fun l -> String.trim l <> "")
  in
  let artifacts = ref 0 in
  (* Check for mid-word truncation at boundaries *)
  (match last_non_empty with
   | Some line ->
     let trimmed = String.trim line in
     let len = String.length trimmed in
     if len > 0 then begin
       let last_char = trimmed.[len - 1] in
       (* Sentence-ending punctuation or structural markers are OK *)
       let is_sentence_end =
        last_char = '.' || last_char = '!' || last_char = '?'
        || last_char = ']' || last_char = '}'
        || last_char = '"' || last_char = '\''
        || last_char = '=' (* structural separator *)
       in
       if not is_sentence_end && len > 20 then incr artifacts
     end
   | None -> incr artifacts (* empty DNA *)
  );
  (* Check for orphan opening brackets/quotes without closing *)
  let open_parens = ref 0 in
  let open_brackets = ref 0 in
  String.iter (fun c ->
    match c with
    | '(' -> incr open_parens
    | ')' -> decr open_parens
    | '[' -> incr open_brackets
    | ']' -> decr open_brackets
    | _ -> ()
  ) dna;
  if !open_parens > 2 then incr artifacts;
  if !open_brackets > 2 then incr artifacts;
  !artifacts

(** Validate DNA quality before spawning a child agent.
    Returns a quality assessment with a composite score [0.0, 1.0].

    Usage: call after [compress_to_dna] + [build_continuity_anchors].
    If [score < 0.3], consider falling back to a full context reset
    rather than spawning with degraded DNA. *)
let validate_dna ~(dna : string) ~(anchors : string) : dna_quality =
  let goal_prefixes = ["goal:"; "goal -"; "objective:"; "north star:"] in
  let task_prefixes = ["current task:"; "current_task:"; "task:"; "now:"] in
  (* Case-insensitive substring search without Str dependency *)
  let contains_ci ~needle haystack =
    let n = String.lowercase_ascii needle in
    let h = String.lowercase_ascii haystack in
    let nlen = String.length n in
    let hlen = String.length h in
    if nlen > hlen then false
    else
      let rec scan i =
        if i > hlen - nlen then false
        else if String.sub h i nlen = n then true
        else scan (i + 1)
      in
      scan 0
  in
  let has_goal_anchor =
    List.exists (fun p -> contains_ci ~needle:p anchors) goal_prefixes
  in
  let has_task_anchor =
    List.exists (fun p -> contains_ci ~needle:p anchors) task_prefixes
  in
  let has_recent_context =
    contains_ci ~needle:"Recent turns:" anchors
  in
  let truncation_artifacts = count_truncation_artifacts dna in
  let content_length = String.length (String.trim dna) in
  (* Weighted scoring *)
  let goal_score = if has_goal_anchor then 1.0 else 0.0 in
  let task_score = if has_task_anchor then 1.0 else 0.0 in
  let recent_score = if has_recent_context then 1.0 else 0.0 in
  let coherence_score =
    match truncation_artifacts with
    | 0 -> 1.0
    | 1 -> 0.5
    | _ -> 0.1
  in
  let length_score =
    if content_length < 100 then 0.0
    else if content_length < 200 then 0.3
    else if content_length < 500 then 0.7
    else 1.0
  in
  let score =
    (goal_score *. 0.30)
    +. (task_score *. 0.20)
    +. (coherence_score *. 0.25)
    +. (length_score *. 0.15)
    +. (recent_score *. 0.10)
  in
  { has_goal_anchor; has_task_anchor; has_recent_context;
    truncation_artifacts; content_length; score }

let dna_quality_to_json (q : dna_quality) : Yojson.Safe.t =
  `Assoc [
    ("has_goal_anchor", `Bool q.has_goal_anchor);
    ("has_task_anchor", `Bool q.has_task_anchor);
    ("has_recent_context", `Bool q.has_recent_context);
    ("truncation_artifacts", `Int q.truncation_artifacts);
    ("content_length", `Int q.content_length);
    ("score", `Float q.score);
  ]
