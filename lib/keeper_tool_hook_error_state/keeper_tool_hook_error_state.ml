(* Typed dedupe state for the Keeper_hooks_oas on_tool_error ERROR log noise.

   See the .mli for the rationale and the production system_log evidence
   that motivates this noise-dedupe layer. The module is intentionally
   stdlib-only (Hashtbl + Mutex + String) so it can be linked into both
   the main library and a standalone Alcotest executable without dragging
   Eio in.

   Sibling of [Keeper_tool_retry_state] (lib/keeper_tool_retry_state/).
   Same shape, different fingerprint dimension: the retry module keys on
   [(tool, signature)] because the retry loop iterates within a single
   keeper context, while this module keys on [(keeper, tool, signature)]
   because the hook fires per-keeper and two different keepers seeing
   the same tool error are legitimately distinct ERROR events.

   Threading: the in-memory [Hashtbl.t] is guarded by a single [Mutex.t].
   All public entry points take and release the lock in a critical
   section that performs only [Hashtbl] manipulation and integer
   arithmetic; no allocations of caller-visible records happen while the
   lock is held, so contention is bounded.

   Memory: there is no eviction policy. The set of distinct
   (keeper_name, tool_name, error_signature) fingerprints is bounded by
   (number of distinct keepers) × (number of distinct tools each
   exercises) × (number of distinct normalized error families per
   tool). At production scale (~tens of keepers, low tens of tools per
   keeper, low tens of stable error families per tool) the cardinality
   is at most low thousands — unbounded accumulation across process
   lifetime is acceptable. *)

type outcome =
  [ `First
  | `Repeated of int
  | `Threshold_silence of int
  ]

(* Threshold tuned against the 2026-05-19 1000-line system_log sample
   (4 distinct (keeper, tool) pairs × 2 repetitions each). With the
   on_tool_error hook firing once per failure (no 1→3 retry ladder
   bundled inside one event), threshold 5 means the operator sees the
   first ERROR plus four DEBUG-demoted intermediates before the durable
   Threshold_silence ERROR fires. *)
let default_silence_threshold = 5

(* Byte cap on the normalized signature. The first 80 bytes of a
   typical OAS tool error carry the error-class prefix and a short
   stable description (the high-signal portion). Variable payloads
   (timestamps, paths, request IDs, PR numbers) that follow are
   deliberately dropped from the fingerprint so the dedupe layer can
   converge. *)
let normalize_length_cap = 80

(* ── normalize ────────────────────────────────────────────────────

   Total, idempotent projection of an arbitrary error string to a
   stable fingerprint suffix. Steps:

   1. Walk the bytes; whitespace runs (ASCII space, tab, CR, LF) are
      collapsed to a single space. Leading whitespace is dropped.
   2. ASCII letters [A]–[Z] are lowercased; non-ASCII bytes pass
      through untouched.
   3. After the walk, trailing whitespace is trimmed and the result
      is truncated to [normalize_length_cap] bytes.

   Pure stdlib (Buffer + Bytes + Char). No regex. *)

let is_ws c =
  match c with
  | ' ' | '\t' | '\r' | '\n' -> true
  | _ -> false
;;

let lowercase_ascii c =
  match c with
  | 'A' .. 'Z' -> Char.chr (Char.code c + 32)
  | _ -> c
;;

let normalize (raw : string) : string =
  let n = String.length raw in
  let buf = Buffer.create (min n normalize_length_cap) in
  let prev_was_space = ref true (* drop leading whitespace *) in
  let i = ref 0 in
  while !i < n do
    let c = String.unsafe_get raw !i in
    if is_ws c
    then (
      if not !prev_was_space
      then (
        Buffer.add_char buf ' ';
        prev_was_space := true))
    else (
      Buffer.add_char buf (lowercase_ascii c);
      prev_was_space := false);
    incr i
  done;
  let s = Buffer.contents buf in
  let s =
    (* trim trailing whitespace introduced by the walk above. The
       collapse step preserves at most one trailing space when the
       input ended on whitespace; strip it. *)
    let len = String.length s in
    if len > 0 && Char.equal (String.unsafe_get s (len - 1)) ' '
    then String.sub s 0 (len - 1)
    else s
  in
  if String.length s > normalize_length_cap
  then String.sub s 0 normalize_length_cap
  else s
;;

type entry =
  { mutable count : int
  ; mutable silenced_emitted : bool
        (* True once a [`Threshold_silence] outcome has been returned
           for this entry, so subsequent calls return [`Repeated]
           rather than re-firing the silence outcome. *)
  }

let make_entry () = { count = 0; silenced_emitted = false }

(* Fingerprint key. [keeper_name], [tool_name], and [error_signature]
   are concatenated with a null separator. The separator avoids the
   collision risk of straight concatenation when one component happens
   to be a prefix of another component's neighbour (e.g. tool name
   "ab" + signature "cd" vs tool name "a" + signature "bcd"). *)
let key ~keeper_name ~tool_name ~error_signature =
  String.concat "\x00" [ keeper_name; tool_name; error_signature ]
;;

let state : (string, entry) Hashtbl.t = Hashtbl.create 32
let mutex = Mutex.create ()

let with_lock f =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f
;;

let record
  ?(silence_threshold = default_silence_threshold)
  ~(keeper_name : string)
  ~(tool_name : string)
  ~(error_signature : string)
  ()
  : outcome
  =
  let k = key ~keeper_name ~tool_name ~error_signature in
  with_lock (fun () ->
    match Hashtbl.find_opt state k with
    | None ->
      let e = make_entry () in
      e.count <- 1;
      Hashtbl.replace state k e;
      `First
    | Some e ->
      e.count <- e.count + 1;
      if e.count >= silence_threshold && not e.silenced_emitted
      then (
        e.silenced_emitted <- true;
        `Threshold_silence e.count)
      else `Repeated e.count)
;;

let reset_for_test () : unit = with_lock (fun () -> Hashtbl.clear state)

let cardinality () : int =
  with_lock (fun () -> Hashtbl.length state)
;;

let occurrence_count
  ~(keeper_name : string)
  ~(tool_name : string)
  ~(error_signature : string)
  : int
  =
  let k = key ~keeper_name ~tool_name ~error_signature in
  with_lock (fun () ->
    match Hashtbl.find_opt state k with
    | None -> 0
    | Some e -> e.count)
;;
