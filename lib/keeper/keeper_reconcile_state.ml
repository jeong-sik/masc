(** Reconciler back-off state for TOML hot-reload. See .mli. *)

type record_outcome =
  [ `First
  | `Repeated
  | `Threshold_disable
  ]

let default_disable_threshold = 10

type entry =
  { error_digest : string
  ; consecutive_failures : int
  ; first_seen_at : float
  ; last_seen_at : float
  ; toml_mtime : float
  ; disabled : bool
  }

(* Per-keeper in-memory state. Mutex-guarded because the supervisor sweep
   runs inside an Eio fiber while individual keeper turns may also call
   [record_success] from a different fiber. Hashtbl ops are O(1) but
   not domain-safe under concurrent writes. *)
let state : (string, entry) Hashtbl.t = Hashtbl.create 16
let mutex = Mutex.create ()

let with_lock f =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f
;;

(* Compress an error string into a stable, low-cardinality digest. The
   reconcile error from [ensure_keeper_meta] is human prose plus the
   offending [cascade_name] / field — using a hash would lose the
   prefix, but a verbatim 200-byte snapshot also tracks irrelevant
   wording drift. Compromise: strip whitespace runs and clip to 96
   characters so two failures with the same root cause hash to the
   same digest even if the formatter changes one space.

   We deliberately keep the prefix readable so the digest can be
   surfaced in observability without a reverse lookup table. *)
let digest_of_error (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create (min len 96) in
  let last_was_space = ref true in
  let i = ref 0 in
  while !i < len && Buffer.length buf < 96 do
    let c = String.unsafe_get s !i in
    let is_space = match c with ' ' | '\t' | '\n' | '\r' -> true | _ -> false in
    if is_space
    then (
      if not !last_was_space then Buffer.add_char buf ' ';
      last_was_space := true)
    else (
      Buffer.add_char buf c;
      last_was_space := false);
    incr i
  done;
  (* Trim trailing single space added above, if any. *)
  let result = Buffer.contents buf in
  let rlen = String.length result in
  if rlen > 0 && result.[rlen - 1] = ' '
  then String.sub result 0 (rlen - 1)
  else result
;;

let now () = Unix.gettimeofday ()

let record_failure ~keeper ~error ~toml_mtime : record_outcome =
  let digest = digest_of_error error in
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper with
    | None ->
        let e =
          { error_digest = digest
          ; consecutive_failures = 1
          ; first_seen_at = now ()
          ; last_seen_at = now ()
          ; toml_mtime
          ; disabled = false
          }
        in
        Hashtbl.replace state keeper e;
        `First
    | Some prev when not (String.equal prev.error_digest digest) ->
        (* Different root error than what we were tracking — treat as a
           fresh signal so the operator sees the new message at WARN. *)
        let e =
          { error_digest = digest
          ; consecutive_failures = 1
          ; first_seen_at = now ()
          ; last_seen_at = now ()
          ; toml_mtime
          ; disabled = false
          }
        in
        Hashtbl.replace state keeper e;
        `First
    | Some prev ->
        let next_count = prev.consecutive_failures + 1 in
        let crossed_threshold =
          (not prev.disabled) && next_count >= default_disable_threshold
        in
        let e =
          { prev with
            consecutive_failures = next_count
          ; last_seen_at = now ()
          ; toml_mtime
          ; disabled = prev.disabled || crossed_threshold
          }
        in
        Hashtbl.replace state keeper e;
        if crossed_threshold then `Threshold_disable
        else if prev.disabled then `Repeated
        else `Repeated)
;;

let is_disabled ~keeper =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper with
    | None -> false
    | Some e -> e.disabled)
;;

let reset_on_mtime_change ~keeper ~new_mtime =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper with
    | None -> false
    | Some e when Float.equal e.toml_mtime new_mtime -> false
    | Some _ ->
        Hashtbl.remove state keeper;
        true)
;;

let record_success ~keeper =
  with_lock (fun () -> Hashtbl.remove state keeper)
;;

let peek_for_test ~keeper =
  with_lock (fun () ->
    match Hashtbl.find_opt state keeper with
    | None -> None
    | Some e -> Some (e.consecutive_failures, e.disabled, e.error_digest))
;;

let reset_all_for_test () =
  with_lock (fun () -> Hashtbl.reset state)
;;
