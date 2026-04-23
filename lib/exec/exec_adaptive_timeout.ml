(* P18: Adaptive Timeout
   Per-command timeout estimation from execution history.
   Uses p95 of successful runs with a safety multiplier.

   Rationale: a fixed 120s timeout is too aggressive for builds and
   too generous for quick lookups.  History-driven p95 adapts to
   actual command behavior. *)

module BH = Bash_history

type timeout_config = {
  default_ms : int;
  min_ms : int;
  max_ms : int;
  multiplier : float;
  min_samples : int;
}

let default_config = {
  default_ms = 120_000;
  min_ms = 30_000;
  max_ms = 600_000;
  multiplier = 1.5;
  min_samples = 3;
}

let compute config entries =
  let success_durations =
    List.filter_map (fun (e : BH.history_entry) ->
      if e.success then Some e.duration_ms else None
    ) entries
  in
  let n = List.length success_durations in
  if n < config.min_samples then config.default_ms
  else begin
    let sorted = List.sort Int.compare success_durations in
    let p95_idx = min (n - 1) (int_of_float (float_of_int n *. 0.95)) in
    let p95 = List.nth sorted p95_idx in
    let raw = int_of_float (float_of_int p95 *. config.multiplier) in
    let clamped = min config.max_ms (max config.min_ms raw) in
    clamped
  end

type stats_result =
  | Adapted of { p95_ms : int; recommended_ms : int; sample_count : int }
  | Default of { reason : string }

let stats config entries =
  let success_durations =
    List.filter_map (fun (e : BH.history_entry) ->
      if e.success then Some e.duration_ms else None
    ) entries
  in
  let n = List.length success_durations in
  if n < config.min_samples then
    Default { reason = Printf.sprintf
      "only %d successful runs (need %d)" n config.min_samples }
  else begin
    let sorted = List.sort Int.compare success_durations in
    let p95_idx = min (n - 1) (int_of_float (float_of_int n *. 0.95)) in
    let p95 = List.nth sorted p95_idx in
    let raw = int_of_float (float_of_int p95 *. config.multiplier) in
    let recommended = min config.max_ms (max config.min_ms raw) in
    Adapted { p95_ms = p95; recommended_ms = recommended; sample_count = n }
  end

let stats_to_json = function
  | Adapted { p95_ms; recommended_ms; sample_count } ->
      `Assoc [
        ("adapted", `Bool true);
        ("p95_ms", `Int p95_ms);
        ("recommended_ms", `Int recommended_ms);
        ("sample_count", `Int sample_count);
      ]
  | Default { reason } ->
      `Assoc [
        ("adapted", `Bool false);
        ("reason", `String reason);
        ("recommended_ms", `Int default_config.default_ms);
      ]
