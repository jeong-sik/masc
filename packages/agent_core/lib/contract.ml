(** Explicit runtime contract helpers.

    The SDK already had prompt and context primitives needed to shape an agent
    run. This module packages those primitives into a first-class contract so callers can
    declare runtime awareness, trigger context, and skill bundles in one place. *)

type trigger =
  { kind : string
  ; source : string option
  ; reason : string option
  ; payload : Yojson.Safe.t option
  }

type instruction_layer =
  { label : string option
  ; content : string
  }

type t =
  { runtime_awareness : string option
  ; trigger : trigger option
  ; instruction_layers : instruction_layer list
  ; skills : Skill.t list
  }

let context_key = "agent_sdk.contract"

let empty =
  { runtime_awareness = None; trigger = None; instruction_layers = []; skills = [] }
;;

let trim_to_option value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let dedupe_skills skills =
  let key_of_skill (skill : Skill.t) =
    match skill.path with
    | Some path -> path
    | None -> skill.name
  in
  let seen = Hashtbl.create (List.length skills) in
  skills
  |> List.filter (fun skill ->
    let key = key_of_skill skill in
    if Hashtbl.mem seen key
    then false
    else (
      Hashtbl.add seen key ();
      true))
;;

let with_runtime_awareness awareness contract =
  { contract with runtime_awareness = trim_to_option awareness }
;;

let with_trigger ?source ?reason ?payload kind contract =
  let kind = String.trim kind in
  if kind = ""
  then contract
  else
    { contract with
      trigger =
        Some
          { kind
          ; source = Option.bind source trim_to_option
          ; reason = Option.bind reason trim_to_option
          ; payload
          }
    }
;;

let add_instruction_layer ?label content contract =
  match trim_to_option content with
  | None -> contract
  | Some content ->
    let layer = { label = Option.bind label trim_to_option; content } in
    { contract with instruction_layers = contract.instruction_layers @ [ layer ] }
;;

let with_skill skill contract =
  { contract with skills = dedupe_skills (contract.skills @ [ skill ]) }
;;

let with_skills skills contract =
  { contract with skills = dedupe_skills (contract.skills @ skills) }
;;

let merge left right =
  { runtime_awareness =
      (match right.runtime_awareness with
       | Some _ -> right.runtime_awareness
       | None -> left.runtime_awareness)
  ; trigger =
      (match right.trigger with
       | Some _ -> right.trigger
       | None -> left.trigger)
  ; instruction_layers = left.instruction_layers @ right.instruction_layers
  ; skills = dedupe_skills (left.skills @ right.skills)
  }
;;

let is_empty contract =
  contract.runtime_awareness = None
  && contract.trigger = None
  && contract.instruction_layers = []
  && contract.skills = []
;;

let trigger_to_json trigger =
  `Assoc
    [ "kind", `String trigger.kind
    ; ( "source"
      , Option.value
          ~default:`Null
          (Option.map (fun value -> `String value) trigger.source) )
    ; ( "reason"
      , Option.value
          ~default:`Null
          (Option.map (fun value -> `String value) trigger.reason) )
    ; "payload", Option.value ~default:`Null trigger.payload
    ]
;;

let instruction_layer_to_json layer =
  `Assoc
    [ "label", Util.json_of_string_opt layer.label; "content", `String layer.content ]
;;

let skill_to_json (skill : Skill.t) =
  `Assoc
    [ "name", `String skill.name
    ; "description", Util.json_of_string_opt skill.description
    ; "path", Util.json_of_string_opt skill.path
    ; "allowed_tools", Util.json_of_string_list skill.allowed_tools
    ]
;;

let to_json contract =
  `Assoc
    [ ( "runtime_awareness"
      , Option.value
          ~default:`Null
          (Option.map (fun value -> `String value) contract.runtime_awareness) )
    ; "trigger", Option.value ~default:`Null (Option.map trigger_to_json contract.trigger)
    ; ( "instruction_layers"
      , `List (List.map instruction_layer_to_json contract.instruction_layers) )
    ; "skills", `List (List.map skill_to_json contract.skills)
    ]
;;

let render_trigger trigger =
  let fields =
    [ Some ("kind: " ^ trigger.kind) ]
    @ [ Option.map (fun value -> "source: " ^ value) trigger.source ]
    @ [ Option.map (fun value -> "reason: " ^ value) trigger.reason ]
    @
    match trigger.payload with
    | Some payload -> [ Some ("payload: " ^ Yojson.Safe.pretty_to_string payload) ]
    | None -> []
  in
  fields
  |> List.filter_map Fun.id
  |> List.map (fun line -> "- " ^ line)
  |> String.concat "\n"
;;

let render_instruction_layer layer =
  match layer.label with
  | Some label -> Printf.sprintf "[Instruction Layer: %s]\n%s" label layer.content
  | None -> Printf.sprintf "[Instruction Layer]\n%s" layer.content
;;

let render_skill (skill : Skill.t) =
  match trim_to_option (Skill.render_prompt skill) with
  | None -> None
  | Some body -> Some (Printf.sprintf "[Skill: %s]\n%s" skill.name body)
;;

let compose_system_prompt ?base contract =
  let sections =
    (match Option.bind base trim_to_option with
     | Some value -> [ value ]
     | None -> [])
    @ (match contract.runtime_awareness with
       | Some value -> [ "[Runtime Awareness]\n" ^ value ]
       | None -> [])
    @ (match contract.trigger with
       | Some trigger -> [ "[Trigger Context]\n" ^ render_trigger trigger ]
       | None -> [])
    @ List.map render_instruction_layer contract.instruction_layers
    @ List.filter_map render_skill contract.skills
  in
  match sections with
  | [] -> None
  | _ -> Some (String.concat "\n\n" sections)
;;

let context_with_contract ?context contract =
  if is_empty contract
  then context
  else (
    let ctx =
      match context with
      | Some value -> value
      | None -> Context.create_sync ()
    in
    Context.set ctx context_key (to_json contract);
    Some ctx)
;;
