(** Keeper_skill_routing — automated and model-assisted skill routing for keepers.
    Keepers always have access to all 'keeper' shard tools, but they
    are routed to specific meta-skills (heartbeat, autonomy) based on
    the user's request. *)

type selection_mode =
  | Heuristic
  | Model_selected of string
  | Model_rejected of string

type keeper_skill_route =
  { primary_skill : string
  ; secondary_skill : string option
  ; reason : string
  ; selection_mode : selection_mode
  }

let keeper_allowed_skills = [ "masc-heartbeat"; "masc-keeper-autonomy" ]
let is_valid_keeper_skill s = List.mem s keeper_allowed_skills

let contains_ci (haystack : string) (needle : string) : bool =
  String_util.contains_substring_ci haystack needle
;;

let skill_match_count_ci ~(text : string) ~(keywords : string list) : int =
  let text_lc = String.lowercase_ascii text in
  List.fold_left
    (fun acc kw ->
       let kw_lc = String.lowercase_ascii kw in
       if contains_ci text_lc kw_lc then acc + 1 else acc)
    0
    keywords
;;

let keeper_skill_priority (skill : string) : int =
  match skill with
  | "masc-keeper-autonomy" -> 0
  | "masc-heartbeat" -> 1
  | _ -> 9
;;

let route_keeper_skill ~(message : string) : keeper_skill_route =
  let heartbeat_keywords =
    [ "heartbeat"
    ; "alive"
    ; "status"
    ; "health"
    ; "diagnose"
    ; "liveness"
    ; "하트비트"
    ; "살아"
    ; "상태"
    ; "진단"
    ; "헬스"
    ]
  in
  let autonomy_keywords =
    [ "keeper"
    ; "handoff"
    ; "compaction"
    ; "context"
    ; "generation"
    ; "trace"
    ; "memory"
    ; "board"
    ; "post"
    ; "comment"
    ; "feed"
    ; "social"
    ; "k2k"
    ; "키퍼"
    ; "승계"
    ; "핸드오프"
    ; "컴팩팅"
    ; "컨텍스트"
    ; "세대"
    ; "메모리"
    ; "보드"
    ; "포스트"
    ; "댓글"
    ; "피드"
    ; "활동"
    ; "소셜"
    ]
  in
  let heartbeat_score = skill_match_count_ci ~text:message ~keywords:heartbeat_keywords in
  let autonomy_score = skill_match_count_ci ~text:message ~keywords:autonomy_keywords in
  let heartbeat_bonus, autonomy_bonus = 0, 1 in
  let scored =
    [ "masc-heartbeat", heartbeat_score + heartbeat_bonus
    ; "masc-keeper-autonomy", autonomy_score + autonomy_bonus
    ]
  in
  let sorted =
    List.sort
      (fun (sa, score_a) (sb, score_b) ->
         let c = compare score_b score_a in
         if c <> 0
         then c
         else compare (keeper_skill_priority sa) (keeper_skill_priority sb))
      scored
  in
  let primary_skill =
    match sorted with
    | (name, _) :: _ -> name
    | [] -> "masc-keeper-autonomy"
  in
  let secondary_skill =
    match sorted with
    | _ :: (name, score) :: _ when score > 0 -> Some name
    | _ -> None
  in
  { primary_skill
  ; secondary_skill
  ; reason = "Heuristic match based on message content"
  ; selection_mode = Heuristic
  }
;;

let format_skill_route_line (route : keeper_skill_route) : string =
  match route.secondary_skill with
  | Some s -> Printf.sprintf "SKILL: %s (+%s)" route.primary_skill s
  | None -> Printf.sprintf "SKILL: %s" route.primary_skill
;;

let format_skill_route_reason (route : keeper_skill_route) : string =
  match route.selection_mode with
  | Heuristic -> Printf.sprintf "SKILL_REASON: %s" route.reason
  | Model_selected r -> Printf.sprintf "SKILL_REASON: %s" r
  | Model_rejected r -> Printf.sprintf "SKILL_REASON: %s (heuristic fallback)" r
;;

let strip_skill_route_lines (raw : string) : string =
  let lines = String.split_on_char '\n' raw in
  let keep line =
    let trimmed = String.trim line in
    if trimmed = ""
    then true
    else (
      let lc = String.lowercase_ascii trimmed in
      if String.starts_with ~prefix:"skill:" lc
      then false
      else if String.starts_with ~prefix:"skill_reason:" lc
      then false
      else true)
  in
  lines |> List.filter keep |> String.concat "\n"
;;

let parse_skill_route_response (text : string) ~(fallback_route : keeper_skill_route)
  : keeper_skill_route
  =
  let lines = String.split_on_char '\n' text in
  let skill_line = List.find_opt (String.starts_with ~prefix:"SKILL:") lines in
  let reason_line = List.find_opt (String.starts_with ~prefix:"SKILL_REASON:") lines in
  match skill_line with
  | Some line ->
    let raw = String.sub line 6 (String.length line - 6) |> String.trim in
    let primary, secondary =
      if contains_ci raw "(+"
      then (
        match String.split_on_char '(' raw with
        | p :: s :: _ ->
          let p = String.trim p in
          let s =
            String.sub s 1 (String.length s - 2)
            |> String.trim
            |> String.map (fun c -> if c = ')' then ' ' else c)
            |> String.trim
          in
          p, Some s
        | _ -> raw, None)
      else raw, None
    in
    if is_valid_keeper_skill primary
    then (
      let reason =
        match reason_line with
        | Some rl -> String.sub rl 13 (String.length rl - 13) |> String.trim
        | None -> "No reason provided by model"
      in
      { primary_skill = primary
      ; secondary_skill = secondary
      ; reason
      ; selection_mode = Model_selected reason
      })
    else
      { fallback_route with
        selection_mode = Model_rejected (Printf.sprintf "Invalid skill: %s" primary)
      }
  | None -> { fallback_route with selection_mode = Model_rejected "No SKILL line found" }
;;

let keeper_skill_routing_instructions ~(fallback_route : keeper_skill_route) : string =
  Printf.sprintf
    "Skill routing policy (agent-selected):\n\
     - Available skills: %s\n\
     - You MUST choose exactly one primary skill from the list above.\n\
     - You MAY add at most one secondary skill.\n\
     - First line MUST be: SKILL: <primary> (+<secondary>)\n\
     - Second line SHOULD be: SKILL_REASON: <short reason>\n\
     - If uncertain, default to `%s`.\n\
     - After those lines, answer normally and concretely.\n\
     - Do not fabricate capabilities beyond chosen skills."
    (String.concat ", " keeper_allowed_skills)
    fallback_route.primary_skill
;;

let skill_route_context_text ~(fallback_route : keeper_skill_route) : string =
  let instructions = keeper_skill_routing_instructions ~fallback_route in
  let current =
    Printf.sprintf
      "Current heuristic route:\n%s\n%s"
      (format_skill_route_line fallback_route)
      (format_skill_route_reason fallback_route)
  in
  Printf.sprintf
    "\n--- SKILL ROUTING ---\n%s\n\n%s\n----------------------\n"
    instructions
    current
;;
