(** Forward-looking continuity summary filtering.

    This module is deliberately string-only: it strips stale or backward-looking
    rendered summary lines before prompt assembly without depending on the
    keeper snapshot record type. *)

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

let filter_forward_looking_summary (summary : string) : string =
  let backward_labels = [ "Done"; "Progress"; "Decisions" ] in
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
  in
  let stale_tool_surface_markers =
    [
      "masc_* only";
      "mcp__masc__ only";
      "no keeper_* tools";
      "no keeper tools";
      "tool surface: masc";
      "tool-surface: masc";
    ]
  in
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
  in
  let is_backward_line line =
    let trimmed = String.trim line in
    List.exists
      (fun label ->
        let prefix = label ^ ":" in
        String.starts_with trimmed ~prefix)
      backward_labels
  in
  let is_inert_next_line line =
    match strip_labeled_value ~prefixes:[ "Next plan:"; "Next:" ] line with
    | None -> false
    | Some value ->
        let payload = String.trim value in
        payload <> ""
        && List.exists
             (fun marker -> String_util.contains_substring_ci payload marker)
             inert_next_markers
  in
  let is_stale_tool_surface_line line =
    let payload = String.trim line in
    String_util.contains_substring_ci payload "tool"
    && (List.exists
          (fun marker -> String_util.contains_substring_ci payload marker)
          stale_tool_surface_markers
        || (String_util.contains_substring_ci payload "only"
            && (String_util.contains_substring_ci payload "allowed tool"
                || String_util.contains_substring_ci payload "available tool"
                || String_util.contains_substring_ci payload "visible tool"
                || String_util.contains_substring_ci payload "tool surface"
                || String_util.contains_substring_ci payload "tool-surface")))
  in
  let kept =
    summary
    |> String.split_on_char '\n'
    |> List.filter (fun line -> not (is_backward_line line))
    |> List.filter (fun line -> not (is_inert_next_line line))
    |> List.filter (fun line -> not (is_stale_tool_surface_line line))
    |> List.filter (fun line -> String.trim line <> "")
  in
  match kept with
  | [] -> ""
  | _ -> String.concat "\n" kept
