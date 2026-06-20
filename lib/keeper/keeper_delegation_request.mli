(** Keeper delegation requests projected from deliberation.

    This module does not spawn agents.  It turns a keeper's
    [propose_spawn] deliberation into a human/promoter-readable MASC task
    seed so existing task, board, and keeper surfaces can decide whether and
    how to route the work. *)

type promotion_state =
  | Candidate
  | Promoted
  | Rejected

val promotion_state_to_string : promotion_state -> string

type task_seed = {
  title : string;
  description : string;
  tags : string list;
}

type t = {
  id : string;
  requester : string;
  topic : string;
  reason : string;
  goal : string option;
  source_action : string;
  promotion_state : promotion_state;
  task_seed : task_seed;
}

val make :
  requester:string -> ?goal:string -> topic:string -> reason:string -> unit -> t

val of_action :
  requester:string ->
  ?goal:string ->
  Keeper_deliberation.deliberation_action ->
  t option
(** [of_action] projects the first [propose_spawn] in a [multi_step] action.
    Multiple spawn proposals are intentionally first-wins so the dashboard
    surfaces keep a single deterministic delegation artifact. *)

val of_execution_result :
  requester:string ->
  ?goal:string ->
  Keeper_deliberation.execution_result ->
  t option

val task_seed_to_json : task_seed -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t

val delegation_request_json :
  requester:string ->
  ?goal:string ->
  Keeper_deliberation.execution_result option ->
  Yojson.Safe.t

val delegation_request_field :
  requester:string ->
  ?goal:string ->
  Keeper_deliberation.execution_result option ->
  string * Yojson.Safe.t
