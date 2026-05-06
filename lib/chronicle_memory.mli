(** Chronicle_memory -- inject git chronicle candidates into episodic memory. *)

val episode_id : Chronicle_ingest.candidate_epoch -> string
(** Deterministic episode id for a chronicle candidate epoch. *)

val episode_of_candidate :
  ?timestamp:float ->
  keeper_name:string ->
  Chronicle_ingest.candidate_epoch ->
  Agent_sdk.Memory.episode
(** Convert a chronicle candidate epoch into an OAS episodic memory entry. *)

val store_candidate_epoch :
  memory:Agent_sdk.Memory.t ->
  keeper_name:string ->
  Chronicle_ingest.candidate_epoch ->
  unit
(** Store one candidate epoch in [memory]. *)

val store_candidate_epochs :
  memory:Agent_sdk.Memory.t ->
  keeper_name:string ->
  Chronicle_ingest.candidate_epoch list ->
  int
(** Store candidate epochs in [memory]. Returns the number of stored entries. *)
