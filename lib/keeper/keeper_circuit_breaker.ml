(** Keeper_circuit_breaker - Persistent state for idle circuit breaker.

    Tracks consecutive idle turns across keeper restarts to prevent infinite
    polling loops. State persists in .masc/circuit_breaker_state.json.

    See task-1120 for design rationale.
    See task-1126 for persistence implementation. *)

open Yojson.Basic.Util

type state = {
  consecutive_idle_turns : int;
  last_reset_ts : float;
  threshold : int;
}

let default_state ~threshold = {
  consecutive_idle_turns = 0;
  last_reset_ts = 0.0;
  threshold;
}

let state_file_path workspace_base =
  Format.sprintf "%s/.masc/circuit_breaker_state.json" workspace_base

let load_state ~workspace_base ~default =
  let path = state_file_path workspace_base in
  try
    let json = Yojson.Basic.from_file path in
    let consecutive_idle_turns = json |> "consecutive_idle_turns" |> int in
    let last_reset_ts = json |> "last_reset_ts" |> float in
    let threshold = json |> "threshold" |> int in
    { consecutive_idle_turns; last_reset_ts; threshold }
  with
  | _ -> default

let save_state ~workspace_base ~state =
  let path = state_file_path workspace_base in
  let json =
    `Assoc [
      ("consecutive_idle_turns", `Int state.consecutive_idle_turns);
      ("last_reset_ts", `Float state.last_reset_ts);
      ("threshold", `Int state.threshold);
    ]
  in
  let dir =
    match String.rindex path '/' with
    | i -> String.sub path 0 i
    | exception Not_found -> "."
  in
  Sys.command (Format.sprintf "mkdir -p %s" dir);
  Yojson.Basic.to_file path json

let increment_state ~state =
  { state with consecutive_idle_turns = state.consecutive_idle_turns + 1 }

let reset_state ~state ~now =
  { state with consecutive_idle_turns = 0; last_reset_ts = now }

let should_skip ~state =
  state.consecutive_idle_turns >= state.threshold

let state_to_json ~state =
  `Assoc [
    ("consecutive_idle_turns", `Int state.consecutive_idle_turns);
    ("last_reset_ts", `Float state.last_reset_ts);
    ("threshold", `Int state.threshold);
  ]

let json_to_state ~json =
  let consecutive_idle_turns = json |> "consecutive_idle_turns" |> int in
  let last_reset_ts = json |> "last_reset_ts" |> float in
  let threshold = json |> "threshold" |> int in
  { consecutive_idle_turns; last_reset_ts; threshold }