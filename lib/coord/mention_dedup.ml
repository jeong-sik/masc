(** Sender-side mention dedup. See [mention_dedup.mli] for contract. *)

let default_ttl_seconds : float =
  match Sys.getenv_opt "MASC_MENTION_DEDUP_TTL_S" with
  | None -> 300.0
  | Some raw ->
      (match float_of_string_opt (String.trim raw) with
       | Some v when v > 0.0 -> v
       | _ -> 300.0)

(* Module-level singleton. Hashtbl is not thread-safe across Eio fibers
   that may re-enter via [run_in_main]; guard with a Mutex. *)
let table : (string * string * string, float) Hashtbl.t = Hashtbl.create 256
let mu : Mutex.t = Mutex.create ()

let inc_outcome outcome =
  (* [Safe_ops.protect] re-raises [Eio.Cancel.Cancelled] so a cancel
     racing with the surrounding fiber still propagates instead of
     being silently swallowed by the previous [with _ -> ()] catch. *)
  Safe_ops.protect ~default:() (fun () ->
    (Atomic.get Coord_hooks.mention_dedup_decision_fn) ~outcome)

let content_topic_hash content =
  let normalized = String.lowercase_ascii (String.trim content) in
  Digest.string normalized |> Digest.to_hex

let should_skip ~from_agent ~target ~content_hash ~now =
  let key = (from_agent, target, content_hash) in
  Mutex.lock mu;
  let decision =
    match Hashtbl.find_opt table key with
    | Some last_seen when now -. last_seen < default_ttl_seconds ->
        (* Within window — skip; do NOT refresh last_seen so the window
           is anchored to the first observation, not the last attempt. *)
        true
    | _ ->
        Hashtbl.replace table key now;
        false
  in
  Mutex.unlock mu;
  inc_outcome (if decision then "skipped" else "passed");
  decision

let reset_for_test () =
  Mutex.lock mu;
  Hashtbl.clear table;
  Mutex.unlock mu
