open Base
module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Coord_types - Shared types for coordination modules *)

type tool_result = {
  success : bool;
  message : string;
}

type context = {
  config: Coord.config;
  agent_name: string;
}

type credential_state = {
  credential_required : bool;
  credential_available : bool;
  credential_candidates : string list;
}

type current_binding = {
  assigned_task_ids : string list;
  primary_owned : string option;
  planning_current : string option;
  current_is_assigned : bool;
  effective_current : string option;
  drift_reason : string option;
  current_task_set : bool;
  claim_first_suppressed : bool;
}

type planning_context_state = {
  planning_missing_task : string option;
  deliverable_conflict_task : string option;
}
