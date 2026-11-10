(** Backend_types - Shared types for Backend modules.

    This module is the single source of truth for error types, config,
    and shared utilities used by all _eio backend implementations.
*)

(* ============================================ *)
(* Error Types                                  *)
(* ============================================ *)

type error =
  | NotFound of string
  | AlreadyExists of string
  | IOError of string
  | InvalidKey of string
[@@deriving show]

type 'a result = ('a, error) Stdlib.result

(* ============================================ *)
(* Health Result                                *)
(* ============================================ *)

type health_result = {
  latency_ms: float;
  is_healthy: bool;
}

(* ============================================ *)
(* Config                                       *)
(* ============================================ *)

type config = {
  base_path: string;
  node_id: string;
}

(* [node_id] is the owner recorded on a workspace lock, so two live processes
   holding the same one each read the other's lock as their own. Hostname and
   pid already separate concurrent processes; the suffix is what separates a
   run from an earlier one that reused its pid.

   It used to be [Hashtbl.hash (gettimeofday ())] masked to 16 bits (#26718).
   A hash of the clock is only as distinct as the clock, and 16 bits is a
   birthday collision every few hundred draws. This is 64 bits from the entropy
   source the rest of the tree uses. Nothing parses the id — it is an opaque
   owner string and a health-check key suffix — so the width is free. *)
let node_id_suffix_bytes = 8

let generate_node_id () =
  let hostname = try Unix.gethostname () with Unix.Unix_error _ -> "unknown" in
  let pid = Unix.getpid () in
  Printf.sprintf "%s-%d-%s" hostname pid (Random_id.hex ~bytes:node_id_suffix_bytes)
;;

let default_config () = {
  base_path = Common.masc_dirname;
  node_id = generate_node_id ();
}

(** Acquire exclusive file lock using Unix.lockf.
    Returns true if lock acquired, false if would block. *)
(** Release file lock *)
(* ============================================ *)
(* In-Memory Pub/Sub (shared by Memory + FS)    *)
(* ============================================ *)

module Pubsub_mem = struct
  type t = {
    subscribers: (string, (string -> unit) list) Hashtbl.t;
  }

  let create () = { subscribers = Hashtbl.create 16 }

  let publish t ~channel ~message =
    match Hashtbl.find_opt t.subscribers channel with
    | None -> Ok 0
    | Some callbacks ->
        List.iter (fun cb ->
          try cb message with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Backend.warn "subscriber callback failed: %s" (Printexc.to_string exn)
        ) callbacks;
        Ok (List.length callbacks)

  let subscribe t ~channel ~callback =
    let existing = match Hashtbl.find_opt t.subscribers channel with
      | Some cbs -> cbs | None -> []
    in
    Hashtbl.replace t.subscribers channel (callback :: existing);
    Ok ()
end
