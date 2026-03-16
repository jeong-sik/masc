(** Dashboard response cache — time-bounded memoization for heavy JSON computations.

    Prevents duplicate computation when multiple dashboard endpoints request
    the same underlying data within a short window. For example, /room-truth
    internally calls dashboard_execution which also serves /execution; the
    cache ensures the expensive computation runs at most once per TTL window.

    Thread-safety: Eio.Mutex guards all table access. The lock is held during
    compute() — this is intentional in Eio's cooperative model where CPU-bound
    work doesn't yield, so holding the lock prevents duplicate computation
    without adding extra blocking. *)

type entry = {
  value : Yojson.Safe.t;
  expires_at : float;
}

let table : (string, entry) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()
let eio_available = ref false

let enable_eio () = eio_available := true

let now () = Time_compat.now ()

let with_lock f =
  if !eio_available then
    Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())
  else
    f ()

let get_or_compute key ~ttl compute =
  with_lock (fun () ->
    match Hashtbl.find_opt table key with
    | Some entry when entry.expires_at > now () -> entry.value
    | _ ->
      let value = compute () in
      Hashtbl.replace table key
        { value; expires_at = now () +. ttl };
      value)

let invalidate key = with_lock (fun () -> Hashtbl.remove table key)

let invalidate_all () = with_lock (fun () -> Hashtbl.clear table)

let stats () =
  with_lock (fun () ->
    let now_ts = now () in
    let total = Hashtbl.length table in
    let active =
      Hashtbl.fold
        (fun _key entry count ->
          if entry.expires_at > now_ts then count + 1 else count)
        table 0
    in
    `Assoc
      [
        ("entries", `Int total);
        ("active", `Int active);
        ("expired", `Int (total - active));
      ])
