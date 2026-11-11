(** Fiber-scoped passive capture for one physically owned original run. The
    scope is supplied by that run's producer; lane names never select a sink.
    No provider call, durable write or decision is introduced by the capture. *)
type t
val create : ?owner:Runtime_schema.exact_lane_owner -> unit -> t
val with_capture : t -> (unit -> 'a) -> 'a
val observations : t -> Exact_lane_slot_observation.t list option
val flow : Agent_core.Exact_output.flow_attempt ->
  (unit -> (('a,'b) Agent_core.Exact_output.validated_flow_success,
            ('c,'b) Agent_core.Exact_output.validated_flow_error) result) ->
  (('a,'b) Agent_core.Exact_output.validated_flow_success,
   ('c,'b) Agent_core.Exact_output.validated_flow_error) result
(** Snapshot real results, including predecessor failures. Exceptions retain
    the last published evidence and propagate unchanged. *)
val walk_cli :
  ?runner:Keeper_lane_cli_oneshot.runner ->
  ?observe:(Keeper_lane_cli_oneshot.attempt_observation -> unit) ->
  base_dir:string -> cli_slots:string list -> system_prompt:string ->
  requirement:Agent_core.Exact_output.output_requirement -> prompt:string ->
  validate:(Yojson.Safe.t -> ('a,string) result) ->
  on_failure:(Keeper_lane_cli_oneshot.failure -> unit) -> unit ->
  (string * 'a, Keeper_lane_cli_oneshot.failure list) result
val run_cli :
  ?runner:Keeper_lane_cli_oneshot.runner ->
  ?observe:(Keeper_lane_cli_oneshot.attempt_observation -> unit) ->
  base_dir:string -> runtime_id:string -> system_prompt:string ->
  requirement:Agent_core.Exact_output.output_requirement -> prompt:string -> unit ->
  (Yojson.Safe.t, Keeper_lane_cli_oneshot.failure) result
(** [run_cli]'s parsed JSON is still [Unresolved] until its caller supplies
    the domain verdict with {!cli_outcome}. Times describe client invocation,
    never an unobserved remote provider dispatch or endpoint. *)
val cli_outcome : slot_id:string -> Exact_lane_slot_observation.outcome -> unit
