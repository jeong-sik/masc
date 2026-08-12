(** Per-endpoint admission of concurrent provider requests. See the .mli for
    the contract. *)

module State = Provider_admission_state

(* Stdlib.Mutex rather than Eio.Mutex: the critical section only swaps an
   immutable registry state and never blocks or switches fibers. Scheduler
   creation, diagnostics, snapshots, and permit waiting remain outside it. *)
let state : Slot_scheduler.t State.t ref = ref State.empty
let state_mutex = Stdlib.Mutex.create ()

let key_of_config (config : Provider_config.t) =
  State.key
    ~kind:(Provider_config.string_of_provider_kind config.kind)
    ~base_url:config.base_url
    ~secret:(Secret.identity config.api_key)
;;

let apply_transition transition =
  Stdlib.Mutex.protect state_mutex (fun () ->
    let next, output = transition !state in
    state := next;
    output)
;;

let resolve_existing ~key ~max =
  Stdlib.Mutex.protect state_mutex (fun () ->
    match State.resolve_existing key ~declared_max:max !state with
    | None -> None
    | Some (next, resolution) ->
      state := next;
      Some resolution)
;;

let warn_conflict = function
  | None -> ()
  | Some (conflict : State.conflict) ->
    Diag.warn
      "provider_admission"
      "conflicting max_concurrent_requests for %s %s: scheduler holds %d, a config \
       declares %d; the first declaration stays authoritative"
      conflict.kind
      (Complete_common.sanitize_url_for_log conflict.base_url)
      conflict.authoritative_max
      conflict.declared_max
;;

let entry_for ~key ~max =
  let resolution =
    match resolve_existing ~key ~max with
    | Some resolution -> resolution
    | None ->
      let candidate = Slot_scheduler.create ~max_slots:max in
      apply_transition (State.install key ~declared_max:max ~candidate)
  in
  warn_conflict resolution.conflict;
  resolution.scheduler
;;

let with_admission ~(config : Provider_config.t) f =
  match config.max_concurrent_requests with
  | None -> f ()
  | Some max ->
    (* max >= 1 is enforced by Complete_common.validate_all before any
       dispatch reaches this point; Slot_scheduler.create re-checks and
       raises on a bypassing caller rather than admitting silently. *)
    let scheduler = entry_for ~key:(key_of_config config) ~max in
    Slot_scheduler.with_permit scheduler f
;;

let snapshot_for ~(config : Provider_config.t) =
  let key = key_of_config config in
  let snapshot = Stdlib.Mutex.protect state_mutex (fun () -> !state) in
  State.find_scheduler key snapshot |> Option.map Slot_scheduler.snapshot
;;
