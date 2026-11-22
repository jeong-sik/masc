(** Cancellation-relay-safe CPU offload wrapper over {!Domain_pool}.

    Offloads heavy JSON decoding, Markdown parsing, temporal memory diffing,
    and fuzzy search onto the single 4M-minor-heap Worker domain without ever
    touching raw [Eio.Executor_pool] directly. *)

type t

val create : sw:Eio.Switch.t -> _ Eio.Domain_manager.t -> t
(** Create a 1-domain Worker pool using {!Domains.start_worker_pool}. *)

val of_domain_pool : Domain_pool.t -> t
val domain_count : t -> int

val submit_cpu : t -> name:string -> (unit -> 'a) -> 'a
(** Blocking CPU submission via {!Domain_pool.submit_cpu}, preserving caller
    cancellation relay and worker cleanup settlement. *)

val submit_cpu_async :
  t -> sw:Eio.Switch.t -> name:string -> (unit -> 'a) -> 'a Eio.Promise.or_exn
(** Async CPU submission via {!Domain_pool.submit_cpu_async}. Cancelling [sw]
    relays cancellation to the worker and waits for settlement. *)

val submit_result_async :
  t ->
  sw:Eio.Switch.t ->
  name:string ->
  (unit -> ('a, string) result) ->
  ('a, string) result Eio.Promise.t
(** Async CPU submission capturing non-cancellation exceptions into
    [Error (Printexc.to_string ex)] while always re-raising
    [Eio.Cancel.Cancelled]. *)
