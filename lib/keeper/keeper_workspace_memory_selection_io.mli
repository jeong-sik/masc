(** Durable effect edge for purpose-specific selection. The caller must resolve
    enabled destinations and Keeper exclusions before constructing this adapter.
    No runtime configuration is modified here. *)
type t

val create : config:Workspace.config -> keeper_id:string ->
  destinations:Typesafeai_config.destinations -> t

val journal_path : t -> string
(** Private evidence path; not a model-facing retrieval route. *)

val selection_id : t -> string
(** One identity joining all assessments to the final request without injecting
    every individual assessment ID into the prompt. *)

val request_ids : t -> string list
(** IDs whose started records were durably accepted, in dispatch order. Join
    these to the selected evidence in the actual request capture. *)

val retain_result : t -> purpose:Yojson.Safe.t ->
  (Yojson.Safe.t,string) result -> (unit,string) result
(** Retain the final selected/unresolved projection before publishing it, even
    when no individual assessment was required. *)

val retain_projection : t -> reason:string -> payload:Yojson.Safe.t -> (unit,string) result
(** Save a proposed provider-bound projection. This is not a delivery receipt;
    actual request captures establish transmission. *)

val evaluate : ?clock:[> float Eio.Time.clock_ty] Eio.Resource.t -> t ->
  state:Yojson.Safe.t -> questions:(string * Typesafeai_types.question) list ->
  (Typesafeai_types.eval_response, Keeper_workspace_memory_selection.evaluation_error) result
(** Save the input before HTTP dispatch and the typed response before returning
    it. Persistence failure prevents selection from consuming an unretained
    judgment. Cancellation records a terminal attempt when possible and propagates.
    Records contain private source data and sanitized destination identities. *)

module For_testing : sig
  val evaluate_with :
    call:(destinations:Typesafeai_config.destinations -> state:Yojson.Safe.t ->
      questions:(string * Typesafeai_types.question) list -> unit ->
      (Typesafeai_client.evaluated, Typesafeai_client.failure) result) ->
    t -> state:Yojson.Safe.t -> questions:(string * Typesafeai_types.question) list ->
    (Typesafeai_types.eval_response, Keeper_workspace_memory_selection.evaluation_error) result
end
