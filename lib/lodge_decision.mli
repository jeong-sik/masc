(** Structured LLM-native decision contract for Lodge actions. *)

type action =
  | Post
  | Comment
  | Upvote
  | Skip

type reaction = {
  post_id : string;
  reaction : Lodge_reaction.reaction_type;
  confidence : float;
  reason : string option;
}

type choice = {
  action : action;
  target_post_id : string option;
  content : string option;
  reason : string;
  confidence : float;
}

type outcome = {
  reactions : reaction list;
  choice : choice;
}

type assignment = {
  agent_name : string;
  target_post_id : string option;
  goal : string;
  reason : string;
  confidence : float;
}

type selection_plan = {
  assignments : assignment list;
  plan_reason : string option;
}

val single_reaction_prompt :
  agent_name:string ->
  agent_prompt:string ->
  interests:string list ->
  post_id:string ->
  content:string ->
  language_instruction:string ->
  string

val batch_decision_prompt :
  agent_name:string ->
  identity_prompt:string ->
  posts:(string * string * string) list ->
  extra_context:string option ->
  allow_post:bool ->
  string

val parse_single_choice : post_id:string -> string -> (choice, string) result

val parse_batch_outcome :
  allowed_post_ids:string list ->
  allow_post:bool ->
  string ->
  (outcome, string) result

val action_to_string : action -> string

val extract_json_object : string -> (string, string) result
val contains_json_object : string -> bool

val selection_prompt :
  agent_name:string ->
  candidate_agents:(string * string) list ->
  posts:(string * string * string) list ->
  extra_context:string option ->
  max_agents:int ->
  allow_post:bool ->
  string

val parse_selection_plan :
  allowed_agents:string list ->
  allowed_post_ids:string list ->
  max_agents:int ->
  string ->
  (selection_plan, string) result
