(** Keeper_skill_routing -- model-assisted skill routing for keepers.
    Keepers always have access to all 'keeper' shard tools. The local
    fallback is a deterministic default route only; message-dependent routing
    belongs at the model boundary. *)

type selection_mode =
  | Default_route
  | Model_selected of string
  | Model_rejected of string

type keeper_skill_route =
  { primary_skill : string
  ; secondary_skill : string option
  ; reason : string
  ; selection_mode : selection_mode
  }

let heartbeat_skill = "masc-heartbeat"
let autonomy_skill = "masc-keeper-autonomy"
let default_keeper_skill = autonomy_skill

let keeper_allowed_skills = [ heartbeat_skill; autonomy_skill ]

let is_valid_keeper_skill s = List.mem s keeper_allowed_skills

let route_keeper_skill ~(message : string) : keeper_skill_route =
  ignore message;
  { primary_skill = default_keeper_skill
  ; secondary_skill = None
  ; reason = "Default route pending model selection"
  ; selection_mode = Default_route
  }

let format_skill_route_line (route : keeper_skill_route) : string =
  match route.secondary_skill with
  | Some s -> Printf.sprintf "SKILL: %s (+%s)" route.primary_skill s
  | None -> Printf.sprintf "SKILL: %s" route.primary_skill

let format_skill_route_reason (route : keeper_skill_route) : string =
  match route.selection_mode with
  | Default_route -> Printf.sprintf "SKILL_REASON: %s" route.reason
  | Model_selected r -> Printf.sprintf "SKILL_REASON: %s" r
  | Model_rejected r -> Printf.sprintf "SKILL_REASON: %s (default route)" r

(* RFC-0089 G5 — closed sums for skill route protocol lines. The LLM
   model_select response is the producer; markers are the wire-level protocol
   tokens. Callers consume [skill_line] instead of re-running marker prefix
   checks in routing logic. *)
type skill_marker =
  | Skill_marker
  | Skill_reason_marker

type skill_selection =
  { selected_primary : string
  ; selected_secondary : string option
  }

type skill_line =
  | Skill of skill_selection
  | Skill_parse_error of string
  | Skill_reason of string
  | Other of string

let skill_marker_to_wire = function
  | Skill_marker -> "SKILL:"
  | Skill_reason_marker -> "SKILL_REASON:"

let skill_markers = [ Skill_marker; Skill_reason_marker ]

let wire_payload ~prefix source =
  let prefix_len = String.length prefix in
  if String.length source < prefix_len then None
  else if String.equal (String.sub source 0 prefix_len) prefix then
    Some
      (String.sub source prefix_len (String.length source - prefix_len)
       |> String.trim)
  else None

let marker_payload_of_line ~(case_sensitive : bool) (line : string) :
    (skill_marker * string) option =
  let source = if case_sensitive then line else String.trim line in
  if String.equal source "" then None
  else
    let candidate =
      if case_sensitive then source else String.lowercase_ascii source
    in
  List.find_map
    (fun marker ->
      let wire = skill_marker_to_wire marker in
      let prefix =
        if case_sensitive then wire else String.lowercase_ascii wire
      in
      match wire_payload ~prefix candidate with
      | Some _ ->
          let payload =
            String.sub source (String.length wire)
              (String.length source - String.length wire)
            |> String.trim
          in
          Some (marker, payload)
      | None -> None)
    skill_markers

let parse_skill_payload (raw : string) :
    (skill_selection, string) result =
  let raw = String.trim raw in
  if String.equal raw "" then Error "Empty SKILL payload"
  else
    match String.split_on_char '(' raw with
    | [ primary ] ->
        let selected_primary = String.trim primary in
        if String.equal selected_primary "" then Error "Empty primary skill"
        else Ok { selected_primary; selected_secondary = None }
    | [ primary; secondary_segment ] ->
        let selected_primary = String.trim primary in
        let secondary_segment = String.trim secondary_segment in
        let secondary_len = String.length secondary_segment in
        if String.equal selected_primary "" then Error "Empty primary skill"
        else if secondary_len < 3
                || not (Char.equal (String.get secondary_segment 0) '+')
                || not
                     (Char.equal
                        (String.get secondary_segment (secondary_len - 1))
                        ')')
        then Error "Invalid secondary skill syntax"
        else
          let selected_secondary =
            String.sub secondary_segment 1 (secondary_len - 2)
            |> String.trim
          in
          if String.equal selected_secondary ""
          then Error "Empty secondary skill"
          else Ok { selected_primary; selected_secondary = Some selected_secondary }
    | _ -> Error "Invalid SKILL payload syntax"

let parse_skill_line ~(case_sensitive : bool) (line : string) : skill_line =
  match marker_payload_of_line ~case_sensitive line with
  | None -> Other line
  | Some (Skill_reason_marker, payload) -> Skill_reason payload
  | Some (Skill_marker, payload) -> (
      match parse_skill_payload payload with
      | Ok selection -> Skill selection
      | Error error -> Skill_parse_error error)

let is_skill_route_line (line : string) : bool =
  match parse_skill_line ~case_sensitive:false line with
  | Skill _
  | Skill_parse_error _
  | Skill_reason _ -> true
  | Other _ -> false

let strip_skill_route_lines (raw : string) : string =
  let lines = String.split_on_char '\n' raw in
  lines
  |> List.filter (fun line -> not (is_skill_route_line line))
  |> String.concat "\n"

let count_skill_route_lines (raw : string) : int =
  String.split_on_char '\n' raw
  |> List.fold_left
       (fun acc line -> if is_skill_route_line line then acc + 1 else acc)
       0

let parse_skill_route_response (text : string)
    ~(fallback_route : keeper_skill_route) : keeper_skill_route =
  let lines = String.split_on_char '\n' text in
  let parsed_lines = List.map (parse_skill_line ~case_sensitive:true) lines in
  let skill_line =
    List.find_map
      (function
        | Skill selection -> Some (Ok selection)
        | Skill_parse_error error -> Some (Error error)
        | Skill_reason _
        | Other _ -> None)
      parsed_lines
  in
  let reason =
    List.find_map
      (function
        | Skill_reason reason -> Some reason
        | Skill _
        | Skill_parse_error _
        | Other _ -> None)
      parsed_lines
  in
  match skill_line with
  | Some (Ok { selected_primary = primary; selected_secondary = secondary }) ->
      if not (is_valid_keeper_skill primary) then
        { fallback_route with
          selection_mode =
            Model_rejected (Printf.sprintf "Invalid skill: %s" primary)
        }
      else if Option.exists (fun s -> not (is_valid_keeper_skill s)) secondary then
        { fallback_route with
          selection_mode =
            Model_rejected
              (Printf.sprintf
                 "Invalid secondary skill: %s"
                 (Option.value ~default:"" secondary))
        }
      else
        let reason = Option.value ~default:"No reason provided by model" reason in
        { primary_skill = primary
        ; secondary_skill = secondary
        ; reason
        ; selection_mode = Model_selected reason
        }
  | Some (Error error) ->
      { fallback_route with
        selection_mode = Model_rejected (Printf.sprintf "Invalid SKILL line: %s" error)
      }
  | None ->
      { fallback_route with selection_mode = Model_rejected "No SKILL line found" }

let keeper_skill_routing_instructions ~(fallback_route : keeper_skill_route)
    : string =
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

let skill_route_context_text ~(fallback_route : keeper_skill_route) : string =
  let instructions = keeper_skill_routing_instructions ~fallback_route in
  let current =
    Printf.sprintf "Default route:\n%s\n%s"
      (format_skill_route_line fallback_route)
      (format_skill_route_reason fallback_route)
  in
  Printf.sprintf
    "\n--- SKILL ROUTING ---\n%s\n\n%s\n----------------------\n"
    instructions current
