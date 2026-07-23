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
  source_action : string;
  promotion_state : promotion_state;
  task_seed : task_seed;
}

val make :
  requester:string -> topic:string -> reason:string -> unit -> t

val identity_key : t -> string
(** Stable artifact/index identity. Keeps [None] distinct from [Some ""]-style
    inputs after normalization so stores do not duplicate that encoding. *)

val of_action :
  requester:string ->
  Keeper_deliberation.deliberation_action ->
  t list
(** [of_action] projects all [propose_spawn] actions in a [multi_step] action.
    Returns an empty list when no [propose_spawn] is found. *)

val of_execution_result :
  requester:string ->
  Keeper_deliberation.execution_result ->
  t list


val task_seed_to_json : task_seed -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t

val delegation_request_json :
  requester:string ->
  Keeper_deliberation.execution_result option ->
  Yojson.Safe.t

val delegation_request_field :
  requester:string ->
  Keeper_deliberation.execution_result option ->
  string * Yojson.Safe.t
