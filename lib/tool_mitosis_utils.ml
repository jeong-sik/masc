(** Tool_mitosis_utils — Utility functions for mitosis tools.

    String matching, DNA validation, overlap analysis, and
    continuity regression checking. Extracted from tool_mitosis.ml. *)

let contains_substring_ci ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let lh = String.length h in
  let ln = String.length n in
  if ln = 0 then
    true
  else if ln > lh then
    false
  else
    let rec loop i =
      if i + ln > lh then false
      else if String.sub h i ln = n then true
      else loop (i + 1)
    in
    loop 0

(** DNA quality validation - BALTHASAR feedback (P1-7: enhanced semantic checks)
    Ensures extracted DNA contains meaningful, structured content.
    Checks: length, goal/task markers, whitespace ratio, structural markers. *)
let validate_dna dna =
  let min_length = 50 in
  let len = String.length dna in
  if len < min_length then
    Error (Printf.sprintf "DNA too short: %d chars (min: %d)" len min_length)
  else
    (* Check for goal/task markers (case-insensitive) *)
    let has_marker =
      List.exists (fun needle -> contains_substring_ci ~haystack:dna ~needle)
        ["goal"; "task"; "objective"; "context"]
    in
    if not has_marker then
      Error "DNA lacks goal/task markers (expected: goal, task, objective, or context)"
    else
      (* Check whitespace ratio < 0.5 *)
      let ws_count = String.fold_left (fun acc c ->
        if c = ' ' || c = '\t' || c = '\n' || c = '\r' then acc + 1 else acc
      ) 0 dna in
      let ws_ratio = Float.of_int ws_count /. Float.of_int len in
      if ws_ratio >= 0.5 then
        Error (Printf.sprintf "DNA is mostly whitespace: %.0f%% (max: 50%%)" (ws_ratio *. 100.0))
      else
        (* Check for structural markers: newline, bullet, colon, dash *)
        let has_structure =
          String.contains dna '\n' ||
          contains_substring_ci ~haystack:dna ~needle:"- " ||
          contains_substring_ci ~haystack:dna ~needle:": " ||
          contains_substring_ci ~haystack:dna ~needle:"* "
        in
        if not has_structure then
          Error "DNA lacks structure (expected: newlines, bullets, colons, or dashes)"
        else
          Ok dna

let normalize_for_overlap s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c ->
    let lc = Char.lowercase_ascii c in
    if (lc >= 'a' && lc <= 'z') || (lc >= '0' && lc <= '9') then
      Buffer.add_char b lc
    else
      Buffer.add_char b ' '
  ) s;
  Buffer.contents b

let tokenize_overlap s =
  String.split_on_char ' ' (normalize_for_overlap s)
  |> List.filter (fun tok -> String.length tok >= 3)

let token_overlap_ratio ~source ~target =
  let source_tokens = tokenize_overlap source in
  match source_tokens with
  | [] -> 1.0
  | _ ->
      let matched =
        List.fold_left (fun acc tok ->
          if List.mem tok (tokenize_overlap target) then acc + 1 else acc
        ) 0 source_tokens
      in
      Float.of_int matched /. Float.of_int (List.length source_tokens)

let extract_prefixed_line ~prefix text =
  let p = String.lowercase_ascii prefix in
  let lp = String.length p in
  let rec loop = function
    | [] -> ""
    | line :: rest ->
        let trimmed = String.trim line in
        let lowered = String.lowercase_ascii trimmed in
        if String.length lowered >= lp && String.sub lowered 0 lp = p then
          String.trim (String.sub trimmed lp (String.length trimmed - lp))
        else
          loop rest
  in
  loop (String.split_on_char '\n' text)

let last_non_empty_line text =
  let rec loop last = function
    | [] -> last
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "" then loop last rest else loop trimmed rest
  in
  loop "" (String.split_on_char '\n' text)

let continuity_regression_check ~full_context ~compressed_context =
  let goal_hint = extract_prefixed_line ~prefix:"goal:" full_context in
  let task_hint = extract_prefixed_line ~prefix:"current task:" full_context in
  let recent_hint = last_non_empty_line full_context in
  let hints =
    List.filter (fun (_, v) -> String.trim v <> "") [
      ("goal", goal_hint);
      ("current_task", task_hint);
      ("recent_turn", recent_hint);
    ]
  in
  let details, passed =
    List.fold_left (fun (acc, pass_n) (name, hint) ->
      let overlap = token_overlap_ratio ~source:hint ~target:compressed_context in
      let retained =
        contains_substring_ci ~haystack:compressed_context ~needle:hint
        || overlap >= 0.6
      in
      let detail = `Assoc [
        ("name", `String name);
        ("hint", `String (Mitosis.safe_sub hint 0 120));
        ("overlap_ratio", `Float overlap);
        ("retained", `Bool retained);
      ] in
      (detail :: acc, if retained then pass_n + 1 else pass_n)
    ) ([], 0) hints
  in
  let total = List.length hints in
  let retention_score =
    if total = 0 then 1.0
    else Float.of_int passed /. Float.of_int total
  in
  `Assoc [
    ("assessed", `Bool (total > 0));
    ("checks_total", `Int total);
    ("checks_passed", `Int passed);
    ("retention_score", `Float retention_score);
    ("details", `List (List.rev details));
  ]
