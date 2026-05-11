(* RFC-0070 Phase 3b-iv.0 — Typed docker daemon response surface.
   See .mli for the contract. *)

type ps_status =
  | Created
  | Running
  | Paused
  | Restarting
  | Exited of { code : int }
  | Dead
[@@deriving show, eq]

type state_parse_error =
  | Unknown_state of string

let parse_state s =
  match String.lowercase_ascii (String.trim s) with
  | "created" -> Ok Created
  | "running" -> Ok Running
  | "paused" -> Ok Paused
  | "restarting" -> Ok Restarting
  | "exited" ->
    (* Phase 3b-iv.0: bare "exited" — exit code 0 placeholder.
       Phase 3b-iv.2 will consume the docker-inspect record and
       supply the real ExitCode. *)
    Ok (Exited { code = 0 })
  | "dead" -> Ok Dead
  | _ -> Error (Unknown_state s)

let state_to_string = function
  | Created -> "created"
  | Running -> "running"
  | Paused -> "paused"
  | Restarting -> "restarting"
  | Exited _ -> "exited"
  | Dead -> "dead"

type exec_result =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }
[@@deriving show, eq]
