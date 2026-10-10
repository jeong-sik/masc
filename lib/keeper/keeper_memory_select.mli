(** Explicit purpose-based retrieval of this Keeper's current memory. Selection
    roles never authorize mutation or establish the truth of a source. *)
val handle :
  ?turn_ref:Ids.Turn_ref.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta -> args:Yojson.Safe.t ->
  unit -> Keeper_tool_execution.t
(** [clock] bounds each selection request with the HTTP client's request
    timeout. Without one, an endpoint that accepts the request and never
    answers holds the call with no time limit. The selection contract itself
    owns no time. *)
