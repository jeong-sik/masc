(** Dashboard response cache — time-bounded memoization for heavy JSON computations.

    Per-key locking prevents deadlock from nested [get_or_compute] calls while
    still guarding against stampede (multiple fibers computing the same key).

    The single [Eio.Mutex] guards only [Hashtbl] access.  [compute] functions
    execute without holding the lock, so nested calls for different keys
    proceed without blocking. *)

type entry = {
  value : Yojson.Safe.t;
  expires_at : float;
}

type slot =
  | Ready of entry
  | Computing of Eio.Condition.t

let table : (string, slot) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()
let eio_available = ref false

let enable_eio () = eio_available := true

let now () = Time_compat.now ()

(** Eio path: per-key locking with stampede protection.
    [mu] is held only during [Hashtbl] lookups/updates, never during [compute]. *)
let get_or_compute_eio key ~ttl compute =
  let rec try_get () =
    let action =
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        match Hashtbl.find_opt table key with
        | Some (Ready entry) when entry.expires_at > now () ->
          `Hit entry.value
        | Some (Computing cond) ->
          Eio.Condition.await cond mu;
          `Retry
        | _ ->
          let cond = Eio.Condition.create () in
          Hashtbl.replace table key (Computing cond);
          `Compute cond)
    in
    match action with
    | `Hit v -> v
    | `Retry -> try_get ()
    | `Compute cond ->
      (match compute () with
       | value ->
         Eio.Mutex.use_rw ~protect:true mu (fun () ->
           Hashtbl.replace table key
             (Ready { value; expires_at = now () +. ttl }));
         Eio.Condition.broadcast cond;
         value
       | exception exn ->
         let bt = Printexc.get_raw_backtrace () in
         Eio.Mutex.use_rw ~protect:true mu (fun () ->
           Hashtbl.remove table key);
         Eio.Condition.broadcast cond;
         Printexc.raise_with_backtrace exn bt)
  in
  try_get ()

(** Non-Eio fallback: no mutex, no concurrency. *)
let get_or_compute_simple key ~ttl compute =
  match Hashtbl.find_opt table key with
  | Some (Ready entry) when entry.expires_at > now () -> entry.value
  | _ ->
    let value = compute () in
    Hashtbl.replace table key (Ready { value; expires_at = now () +. ttl });
    value

let timeout_error_json key timeout_sec =
  `Assoc [
    ("error", `String "computation_timeout");
    ("message", `String (Printf.sprintf "Dashboard %s timed out after %.0fs" key timeout_sec));
    ("generated_at", `String (Types.now_iso ()));
  ]

let get_or_compute key ~ttl compute =
  if !eio_available then get_or_compute_eio key ~ttl compute
  else get_or_compute_simple key ~ttl compute

exception Compute_timeout of string

(** Compute with Eio timeout. On timeout, raises [Compute_timeout] inside the
    compute closure so [get_or_compute_eio] removes the [Computing] slot and
    broadcasts waiters. The outer [try] catches [Compute_timeout] and returns
    a timeout-error JSON without caching it. *)
let get_or_compute_with_timeout key ~ttl ~clock ~timeout_sec compute =
  try
    get_or_compute key ~ttl (fun () ->
      match
        Eio.Time.with_timeout clock timeout_sec (fun () ->
          Ok (compute ()))
      with
      | Ok value -> value
      | Error `Timeout ->
        Printf.eprintf "[WARN] Dashboard cache compute timeout: %s (%.0fs)\n%!" key timeout_sec;
        raise (Compute_timeout key))
  with Compute_timeout k ->
    timeout_error_json k timeout_sec

let invalidate key =
  if !eio_available then
    let cond_opt =
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        let c =
          match Hashtbl.find_opt table key with
          | Some (Computing cond) -> Some cond
          | _ -> None
        in
        Hashtbl.remove table key;
        c)
    in
    Option.iter Eio.Condition.broadcast cond_opt
  else Hashtbl.remove table key

let invalidate_all () =
  if !eio_available then
    let conds =
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        let cs =
          Hashtbl.fold
            (fun _key slot acc ->
              match slot with Computing cond -> cond :: acc | _ -> acc)
            table []
        in
        Hashtbl.clear table;
        cs)
    in
    List.iter Eio.Condition.broadcast conds
  else Hashtbl.clear table

let stats () =
  let compute () =
    let now_ts = now () in
    let total = Hashtbl.length table in
    let active =
      Hashtbl.fold
        (fun _key slot count ->
          match slot with
          | Ready entry when entry.expires_at > now_ts -> count + 1
          | _ -> count)
        table 0
    in
    let computing =
      Hashtbl.fold
        (fun _key slot count ->
          match slot with Computing _ -> count + 1 | _ -> count)
        table 0
    in
    `Assoc
      [
        ("entries", `Int total);
        ("active", `Int active);
        ("computing", `Int computing);
        ("expired", `Int (total - active - computing));
      ]
  in
  if !eio_available then Eio.Mutex.use_rw ~protect:true mu compute
  else compute ()
