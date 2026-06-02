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

