(** Failure observation for MASC agents.

    Recorded outcomes never classify, delay, or suppress execution.

    Implementation: all breaker records are immutable and stored in a
    persistent [StringMap].  The single mutable field [observations] in [t]
    is protected by [Eio.Mutex].

    @since 0.6.0 - MASC Social v4 Tier 1
*)

module StringMap = Set_util.StringMap

(** {1 Types} *)

type failure_record = {
  timestamp: float;
  reason: string;
}

type observation = {
  agent_id: string;
  failure_count: int;
  last_failure: failure_record option;
  last_success_at: float option;
}

type t = {
  mutable observations: observation StringMap.t;
  mutex: Eio.Mutex.t;
}

(** {1 Creation} *)

let create () =
  { observations = StringMap.empty; mutex = Eio.Mutex.create () }

let create_default () = create ()

(** {1 Internal Helpers} *)

let with_lock t f =
  Eio_guard.with_mutex t.mutex f

let put_observation t observation =
  t.observations <-
    StringMap.add observation.agent_id observation t.observations

let get_or_create_observation t ~agent_id =
  match StringMap.find_opt agent_id t.observations with
  | Some observation -> observation
  | None ->
      let observation =
        { agent_id; failure_count = 0; last_failure = None; last_success_at = None }
      in
      put_observation t observation;
      observation

(** {1 Core Operations} *)

(** Record a failure for an agent *)
let record_failure t ~agent_id ~reason =
  with_lock t (fun () ->
    let observation = get_or_create_observation t ~agent_id in
    let now = Time_compat.now () in
    let observation =
      { observation with
        failure_count = observation.failure_count + 1
      ; last_failure = Some { timestamp = now; reason }
      }
    in
    put_observation t observation
  )

let record_success t ~agent_id =
  with_lock t (fun () ->
    let observation = get_or_create_observation t ~agent_id in
    let now = Time_compat.now () in
    put_observation t { observation with last_success_at = Some now }
  )

(** {1 Status & Statistics} *)

let get_observation t ~agent_id =
  with_lock t (fun () ->
    match StringMap.find_opt agent_id t.observations with
    | None ->
      { agent_id; failure_count = 0; last_failure = None; last_success_at = None }
    | Some observation -> observation
  )

let list_all t =
  with_lock t (fun () ->
    StringMap.fold
      (fun _ observation acc -> observation :: acc)
      t.observations
      []
  )

(** {1 Global Instance}

    The singleton is read from tests and startup paths that can run before an
    Eio scheduler exists, so it must not force [Eio.Lazy].  Use a
    cross-context Atomic+Stdlib.Mutex memo instead of [Stdlib.Lazy.force]. *)

let global_cache : t option Atomic.t = Atomic.make None
let global_mu = Mutex.create ()

let global () =
  match Atomic.get global_cache with
  | Some t -> t
  | None ->
      let candidate = create_default () in
      Mutex.protect global_mu (fun () ->
        match Atomic.get global_cache with
        | Some t -> t
        | None ->
            Atomic.set global_cache (Some candidate);
            candidate)

let record_failure_global ~agent_id ~reason = record_failure (global ()) ~agent_id ~reason
let record_success_global ~agent_id = record_success (global ()) ~agent_id
let get_observation_global ~agent_id = get_observation (global ()) ~agent_id
