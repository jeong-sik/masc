(** RFC-0107 Phase E step 1 — Docker UDS HTTP client skeleton.

    All public entry points raise [Failure]. Step 2 will replace these
    bodies with the actual Eio + cohttp-eio over UDS implementation.
    Until then there are *zero* production callers — the corresponding
    [worker_runtime_docker.ml] / [keeper_sandbox_runtime.ml] branches
    stay on the legacy [docker run / docker exec] subprocess path. *)

(* The skeleton uses a unit type by design (cf. RFC-0107 Phase D.2 —
   "type-correct skeleton + runtime fail" pattern). Step 2 will replace
   [t] with a record carrying the daemon endpoint flow, the parent
   switch, and any per-connection HTTP state. *)
type t = unit

type exec_response =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }

let not_implemented fn =
  let msg =
    Printf.sprintf
      "Docker_api.%s: not yet implemented (RFC-0107 Phase E step 2 — HTTP \
       transport over /var/run/docker.sock)"
      fn
  in
  raise (Failure msg)
;;

let create ~sw:_ ~env:_ ?socket_path:_ () : t = not_implemented "create"
let ping (_ : t) : (unit, string) result = not_implemented "ping"

let container_create (_ : t) ~image:_ ?cmd:_ ?env:_ ()
  : (string, string) result
  =
  not_implemented "container_create"
;;

let container_start (_ : t) ~container_id:_ : (unit, string) result =
  not_implemented "container_start"
;;

let container_exec (_ : t) ~container_id:_ ~cmd:_ ?stdin:_ ()
  : (exec_response, string) result
  =
  not_implemented "container_exec"
;;

let container_remove (_ : t) ~container_id:_ ?force:_ ()
  : (unit, string) result
  =
  not_implemented "container_remove"
;;
