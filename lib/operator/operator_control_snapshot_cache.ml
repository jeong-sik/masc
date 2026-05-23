(** Snapshot TTL cache with same-key deduplication (singleflight),
    extracted from [operator_control_snapshot.ml] (godfile decomp).

    When multiple fibers hit a cache miss for the same key concurrently,
    only one computes; the rest wait for its result via Eio.Condition.
    This prevents memory bursts during keeper autoboot where many
    concurrent dashboard polls would each build heavy keeper snapshots.

    The cluster forms a self-contained subsystem:

    - [snapshot_slot] — variant distinguishing live cache entries
      ([Cached { value; expires_at }]) from in-flight computations
      ([Computing { cond; stale; started_at; stuck_warned }]).

    - [_snapshot_table], [_snapshot_mu] — module-level mutable state.
      Underscore prefix marks them as internal-only; consumers go through
      [invalidate_snapshot_cache] or the [snapshot_json]
      cache-handling code in the parent.

    - [invalidate_snapshot_cache ()] — clears the table and
      broadcasts all in-flight [Computing] conditions so waiting
      fibers can re-run. Eio-guarded: pre-Eio callers single-threaded
      and need no mutex.

    Parent uses [include Operator_control_snapshot_cache] so type
    + state + helpers flow into [Operator_control_snapshot]'s scope.
    The include chain propagates through to [Operator_control] via
    [Operator_control_action]. *)

type snapshot_slot =
  | Cached of
      { value : Yojson.Safe.t
      ; expires_at : float
      }
  | Computing of
      { cond : Eio.Condition.t
      ; stale : Yojson.Safe.t option
      ; started_at : float
      ; stuck_warned : bool ref
      }

let _snapshot_table : (string, snapshot_slot) Hashtbl.t = Hashtbl.create 4
let _snapshot_mu = Eio.Mutex.create ()

let invalidate_snapshot_cache () =
  if Eio_guard.is_ready ()
  then (
    let conds =
      Eio.Mutex.use_rw ~protect:true _snapshot_mu (fun () ->
        let cs =
          Hashtbl.fold
            (fun _key slot acc ->
               match slot with
               | Computing { cond; _ } -> cond :: acc
               | Cached _ -> acc)
            _snapshot_table
            []
        in
        Hashtbl.clear _snapshot_table;
        cs)
    in
    List.iter Eio.Condition.broadcast conds)
  else Hashtbl.clear _snapshot_table
;;
