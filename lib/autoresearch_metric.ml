(** Autoresearch_metric — Metric measurement and retry logic.

    Runs a shell command (metric_fn) and parses the last line as a float score.
    Supports retry on transient errors (timeout, connection).

    @since 2.80.0 *)

(** Check if [needle] is a substring of [haystack]. *)
let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then
        found := true
    done;
    !found

(** Run metric_fn shell command and parse the last float from stdout.
    Returns Error if command fails or output is not a valid float. *)
let measure_metric ~workdir ~timeout_s metric_fn =
  let timeout_flag = Printf.sprintf "timeout %.0f" timeout_s in
  let cmd = Printf.sprintf "cd %s && %s %s 2>/dev/null | tail -1"
    (Filename.quote workdir) timeout_flag metric_fn in
  let start = Time_compat.now () in
  let ic = Unix.open_process_in cmd in
  let output = Fun.protect ~finally:(fun () ->
    ignore (Unix.close_process_in ic)
  ) (fun () ->
    try input_line ic with End_of_file -> ""
  ) in
  let elapsed_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  match float_of_string_opt (String.trim output) with
  | Some v -> Result.ok (v, elapsed_ms)
  | None -> Result.error (Printf.sprintf "metric_fn output not a float: %S" output)

(** Run metric_fn with retry on transient errors (timeout, connection).
    Returns Ok (score, total_elapsed_ms) or Error on non-transient failure.
    max_retries=2 means up to 3 total attempts. *)
let measure_metric_with_retry ~workdir ~timeout_s ?(max_retries = 2) metric_fn =
  let is_transient err =
    let lower = String.lowercase_ascii err in
    contains_substring lower "timeout" || contains_substring lower "connection"
  in
  let rec attempt n =
    match measure_metric ~workdir ~timeout_s metric_fn with
    | Ok _ as ok -> ok
    | Error e when n < max_retries && is_transient e ->
      Time_compat.sleep 1.0;
      attempt (n + 1)
    | Error _ as err -> err
  in
  attempt 0
