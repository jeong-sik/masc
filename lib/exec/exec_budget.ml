(* P17: Turn Execution Budget
   Per-turn counter that tracks bash invocations and emits structured
   warnings when the agent approaches or exceeds the configured limit.
   Soft limit = warning in response; hard limit = execution blocked.

   Inspired by OpenAI Codex Harness "loop budget" — one of the top-3
   safety requirements for autonomous agents. *)

type t = {
  mutable count : int;
  mutable cumulative_ms : int;
  limit : int;
  soft_limit : int;
}

let default_limit = 30
let default_soft_limit = 20

let create ?(limit = default_limit) ?(soft_limit = default_soft_limit) () =
  { count = 0; cumulative_ms = 0; limit; soft_limit }

let reset t =
  t.count <- 0;
  t.cumulative_ms <- 0

let record t ~duration_ms =
  t.count <- t.count + 1;
  t.cumulative_ms <- t.cumulative_ms + duration_ms

type budget_status =
  | Ok of { remaining : int }
  | Soft_warning of { remaining : int; limit : int }
  | Hard_stop of { count : int; limit : int; cumulative_ms : int }

let check t =
  if t.count >= t.limit then
    Hard_stop { count = t.count; limit = t.limit; cumulative_ms = t.cumulative_ms }
  else if t.count >= t.soft_limit then
    Soft_warning { remaining = t.limit - t.count; limit = t.limit }
  else
    Ok { remaining = t.soft_limit - t.count }

let status_to_json = function
  | Ok _ -> `Null
  | Soft_warning { remaining; limit } ->
      `Assoc [
        ("level", `String "soft_warning");
        ("message", `String (Printf.sprintf
          "Approaching execution budget: %d commands remaining (limit %d)"
          remaining limit));
        ("remaining", `Int remaining);
        ("limit", `Int limit);
        ("suggestion", `String
          "Consider consolidating commands or summarizing progress");
      ]
  | Hard_stop { count; limit; cumulative_ms } ->
      `Assoc [
        ("level", `String "hard_stop");
        ("message", `String (Printf.sprintf
          "Execution budget exhausted: %d/%d commands used this turn"
          count limit));
        ("count", `Int count);
        ("limit", `Int limit);
        ("cumulative_ms", `Int cumulative_ms);
        ("suggestion", `String
          "Turn execution budget reached. Report progress and wait for next turn.");
      ]

let to_json t =
  `Assoc [
    ("count", `Int t.count);
    ("limit", `Int t.limit);
    ("soft_limit", `Int t.soft_limit);
    ("remaining", `Int (t.limit - t.count));
    ("cumulative_ms", `Int t.cumulative_ms);
  ]
