module Terminal_text = Masc_tui_ansi.Terminal_text
module Answer = Masc.Keeper_volume_gc_answer

let tool = "masc_sandbox_volume_gc"
let claims_image = "base"

let arguments ~execute =
  [ "image", `String claims_image; "execute", `Bool execute ]
;;

type answer =
  | Report of Answer.t
  | Refused of string
  | Unreadable of string

let answer_of_text ~is_error text =
  if is_error
  then Refused text
  else (
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error detail -> Unreadable ("the answer is not JSON: " ^ detail)
    | json ->
      (match Answer.of_json json with
       | Ok report -> Report report
       | Error detail -> Unreadable detail))
;;

let candidates (report : Answer.t) =
  List.filter_map
    (fun (verdict : Answer.verdict) ->
       match verdict.kind with
       | Answer.Reclaim_candidate -> Some verdict.keeper_name
       | Answer.Kept | Answer.Reclaimed | Answer.Reclaim_failed -> None)
    report.keepers
;;

let reclaimable = function
  | Report report when not report.Answer.executed ->
    (match candidates report with
     | [] -> None
     | names -> Some names)
  | Report _ | Refused _ | Unreadable _ -> None
;;

let summary_line report =
  let s = Answer.summary report in
  Printf.sprintf
    "%d kept · %d reclaim candidates · %d reclaimed · %d failed"
    s.Answer.kept
    s.reclaim_candidates
    s.reclaimed
    s.reclaim_failed
;;

let confirm_prompt ~confirm_key names =
  Printf.sprintf
    "press %s again to reclaim the build volumes of %s; the server judges them once more first"
    confirm_key
    (String.concat ", " (List.map Terminal_text.single_line names))
;;

let volume_label = function
  | None -> "-"
  | Some name -> Terminal_text.single_line name
;;

let keeper_line (verdict : Answer.verdict) =
  Printf.sprintf
    "%s: %s (work %s, build %s)"
    (Terminal_text.single_line verdict.keeper_name)
    (Terminal_text.single_line verdict.outcome)
    (volume_label verdict.work_volume)
    (volume_label verdict.build_volume)
;;

let report_sections (report : Answer.t) =
  let state =
    if report.executed
    then "Reclaimed on request."
    else if report.image_given
    then "Report only. Nothing was deleted."
    else "Report only. No claims image was given, so unowned Keepers stay unverified."
  in
  let keepers =
    match report.keepers with
    | [] -> "No retired Keeper volume."
    | verdicts -> String.concat "\n" (List.map keeper_line verdicts)
  in
  let summary = state ^ "\n" ^ summary_line report in
  [ "Summary", summary; "Keepers", keepers ]
  @
  match report.foreign_volumes with
  | [] -> []
  | names ->
    [ "Not a Keeper's", String.concat "\n" (List.map Terminal_text.single_line names) ]
;;

let sections = function
  | Report report -> report_sections report
  | Refused detail -> [ "Refused", Terminal_text.single_line detail ]
  | Unreadable detail -> [ "Unreadable answer", Terminal_text.single_line detail ]
;;
