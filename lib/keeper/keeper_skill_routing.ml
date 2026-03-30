(** Keeper_skill_routing — skill routing types and agent-selected prompt assembly
    and prompt assembly for keeper execution.

    Extracted from keeper_alerting.ml to separate alert infrastructure
    from skill routing logic.

    @since 2.95.0 *)

open Keeper_types
open Keeper_memory

type keeper_skill_route = {
  primary_skill: string;
  secondary_skills: string list;
  reason: string;
}

type keeper_skill_selection_mode =
  | SkillSelectAgent

type keeper_skill_route_resolution = {
  route: keeper_skill_route;
  selection_mode: string;
  provenance: string;
}

let contains_ci (haystack : string) (needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  if n = "" then false
  else Re.execp (Re.str n |> Re.compile) h

let keeper_skill_selection_mode () : keeper_skill_selection_mode =
  SkillSelectAgent

let keeper_allowed_skills = [
  "masc-heartbeat";
  "masc-keeper-autonomy";
]

let canonical_keeper_skill_token (raw : string) : string option =
  match String.lowercase_ascii (String.trim raw) with
  | "masc-heartbeat" | "masc_heartbeat" | "heartbeat" -> Some "masc-heartbeat"
  | "masc-keeper-autonomy"
  | "masc_keeper_autonomy"
  | "keeper-autonomy"
  | "social"
  | "keeper"
  | "autonomy" ->
      Some "masc-keeper-autonomy"
  | _ -> None

let unique_skills_preserve_order (xs : string list) : string list =
  List.fold_left
    (fun acc x -> if List.mem x acc then acc else acc @ [x])
    []
    xs

let skill_match_count_ci ~(text : string) ~(keywords : string list) : int =
  List.fold_left
    (fun acc keyword -> if contains_ci text keyword then acc + 1 else acc)
    0 keywords

let keeper_skill_priority ~(soul_profile : string) (skill : string) : int =
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  match profile, skill with
  | "safety", "masc-heartbeat" -> 0
  | "safety", "masc-keeper-autonomy" -> 1
  | "delivery", "masc-keeper-autonomy" -> 0
  | "delivery", "masc-heartbeat" -> 1
  | "research", "masc-keeper-autonomy" -> 0
  | "research", "masc-heartbeat" -> 1
  | _, "masc-keeper-autonomy" -> 0
  | _, "masc-heartbeat" -> 1
  | _ -> 9

let route_keeper_skill ~(soul_profile : string) ~(message : string) : keeper_skill_route =
  let heartbeat_keywords = [
    "heartbeat"; "alive"; "status"; "health"; "diagnose"; "liveness";
    "하트비트"; "살아"; "상태"; "진단"; "헬스";
  ] in
  let autonomy_keywords = [
    "keeper"; "handoff"; "compaction"; "context"; "generation"; "trace"; "memory";
    "board"; "post"; "comment"; "feed"; "social"; "k2k";
    "키퍼"; "승계"; "핸드오프"; "컴팩팅"; "컨텍스트"; "세대"; "메모리";
    "보드"; "포스트"; "댓글"; "피드"; "활동"; "소셜";
  ] in
  let profile =
    canonical_soul_profile soul_profile |> Option.value ~default:default_soul_profile
  in
  let heartbeat_score = skill_match_count_ci ~text:message ~keywords:heartbeat_keywords in
  let autonomy_score = skill_match_count_ci ~text:message ~keywords:autonomy_keywords in
  let heartbeat_bonus, autonomy_bonus =
    match profile with
    | "safety" -> (1, 1)
    | "delivery" -> (0, 1)
    | "research" -> (0, 1)
    | "relationship" -> (0, 1)
    | _ -> (0, 1)
  in
  let scored = [
    ("masc-heartbeat", heartbeat_score + heartbeat_bonus);
    ("masc-keeper-autonomy", autonomy_score + autonomy_bonus);
  ] in
  let sorted =
    List.sort
      (fun (sa, score_a) (sb, score_b) ->
         let c = compare score_b score_a in
         if c <> 0 then c
         else
           compare
             (keeper_skill_priority ~soul_profile:profile sa)
             (keeper_skill_priority ~soul_profile:profile sb))
      scored
  in
  let primary_skill =
    match sorted with
    | (name, _) :: _ -> name
    | [] -> "masc-keeper-autonomy"
  in
  let secondary_skills =
    sorted
    |> List.filter_map (fun (name, score) ->
           if name = primary_skill || score <= 0 then None else Some name)
    |> take 1
  in
  let reason =
    Printf.sprintf
      "profile=%s; scores{heartbeat=%d,autonomy=%d}"
      profile
      (heartbeat_score + heartbeat_bonus)
      (autonomy_score + autonomy_bonus)
  in
  { primary_skill; secondary_skills; reason }

let skill_route_header (route : keeper_skill_route) : string =
  match route.secondary_skills with
  | [] -> Printf.sprintf "SKILL: %s" route.primary_skill
  | secs ->
      Printf.sprintf
        "SKILL: %s (+%s)"
        route.primary_skill
        (String.concat ", " secs)

let ensure_skill_route_header ~(route : keeper_skill_route) (raw : string) : string =
  let trimmed = String.trim raw in
  if trimmed = "" then
    skill_route_header route
  else
    let first_line =
      match String.split_on_char '\n' trimmed with
      | head :: _ -> String.trim head
      | [] -> ""
    in
    let already_tagged =
      match strip_prefix_ci ~prefix:"SKILL:" first_line with
      | Some _ -> true
      | None -> false
    in
    if already_tagged then raw
    else Printf.sprintf "%s\n%s" (skill_route_header route) raw

let strip_skill_route_lines (raw : string) : string =
  let lines = String.split_on_char '\n' raw in
  let keep line =
    let trimmed = String.trim line in
    if trimmed = "" then true
    else
      match strip_prefix_ci ~prefix:"SKILL:" trimmed with
      | Some _ -> false
      | None -> (
          match strip_prefix_ci ~prefix:"SKILL_REASON:" trimmed with
          | Some _ -> false
          | None -> true)
  in
  lines |> List.filter keep |> String.concat "\n"

let parse_skill_line (line : string) : (string * string list) option =
  match strip_prefix_ci ~prefix:"SKILL:" line with
  | None -> None
  | Some payload ->
      let payload = String.trim payload in
      if payload = "" then None
      else
        let payload_len = String.length payload in
        let rec first_sep i =
          if i >= payload_len then payload_len
          else
            match payload.[i] with
            | ' ' | '\t' | '(' -> i
            | _ -> first_sep (i + 1)
        in
        let primary_end = first_sep 0 in
        let primary_raw = String.sub payload 0 primary_end |> String.trim in
        let rest =
          if primary_end >= payload_len then ""
          else String.sub payload primary_end (payload_len - primary_end) |> String.trim
        in
        let secondary_raw_opt =
          if String.length rest >= 2 && String.sub rest 0 2 = "(+" then
            match Re.exec_opt ~pos:2 (Re.str ")" |> Re.compile) rest with
            | Some g ->
              let close_idx = Re.Group.start g 0 in
              let inside = String.sub rest 2 (close_idx - 2) |> String.trim in
              if inside = "" then None else Some inside
            | None -> None
          else
            None
        in
        match canonical_keeper_skill_token primary_raw with
        | None -> None
        | Some primary ->
            let secondary =
              match secondary_raw_opt with
              | None -> []
              | Some raw ->
                  raw
                  |> String.split_on_char ','
                  |> List.filter_map canonical_keeper_skill_token
                  |> unique_skills_preserve_order
                  |> List.filter (fun s -> s <> primary)
                  |> take 1
            in
            Some (primary, secondary)

let parse_skill_reason_line (line : string) : string option =
  match strip_prefix_ci ~prefix:"SKILL_REASON:" line with
  | Some v -> trim_nonempty v
  | None -> None

let agent_selected_skill_route_from_reply (raw : string) : keeper_skill_route option =
  let lines =
    raw
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  match lines with
  | [] -> None
  | first :: tail ->
      (match parse_skill_line first with
       | None -> None
       | Some (primary, secondary) ->
           let reason =
             tail
             |> take 3
             |> List.find_map parse_skill_reason_line
             |> Option.value ~default:"agent-selected"
           in
           Some { primary_skill = primary; secondary_skills = secondary; reason })

let resolved_keeper_skill_route
    ~(selection_mode : keeper_skill_selection_mode)
    ~(fallback_route : keeper_skill_route)
    ~(reply_raw : string) : keeper_skill_route_resolution =
  match selection_mode with
  | SkillSelectAgent ->
      (match agent_selected_skill_route_from_reply reply_raw with
       | Some route ->
           { route; selection_mode = "agent"; provenance = "judgment" }
       | None ->
           { route = fallback_route; selection_mode = "agent"; provenance = "fallback" })

let skill_route_system_prompt_agent
    ~(base_system_prompt : string)
    ~(fallback_route : keeper_skill_route)
    ~(soul_profile : string) : string =
  Printf.sprintf
    "%s\n\n\
     Skill routing policy (agent-selected):\n\
     - Available skills: %s\n\
     - SOUL profile: %s\n\
     - You MUST choose exactly one primary skill from the list above.\n\
     - You MAY add at most one secondary skill.\n\
     - First line MUST be: SKILL: <primary> (+<secondary>)\n\
     - Second line SHOULD be: SKILL_REASON: <short reason>\n\
     - If uncertain, default to `%s`.\n\
     - After those lines, answer normally and concretely.\n\
     - Do not fabricate capabilities beyond chosen skills."
    base_system_prompt
    (String.concat ", " keeper_allowed_skills)
    soul_profile
    fallback_route.primary_skill
