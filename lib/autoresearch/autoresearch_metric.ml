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

(** Shell metacharacters that indicate injection risk in metric_fn.
    metric_fn is intentionally interpolated as a bare command (e.g. "python eval.py --metric accuracy"),
    so we cannot quote it. Instead we reject strings containing shell metacharacters
    that could chain or redirect commands. *)
let dangerous_shell_chars =
  [';'; '|'; '&'; '`'; '$'; '('; ')'; '{'; '}'; '<'; '>'; '\n';
   '#'; '!'; '~'; '['; ']'; '*'; '?'; '\\']

(** Validate that metric_fn does not contain dangerous shell metacharacters.
    Returns Ok fn on success, Error message on failure. *)
let validate_metric_fn fn =
  let has_danger = String.to_seq fn |> Seq.exists (fun c -> List.mem c dangerous_shell_chars) in
  if has_danger then
    Error (Printf.sprintf "metric_fn contains dangerous shell metacharacters: %s" fn)
  else
    Ok fn

(** Run metric_fn shell command and parse the last float from stdout.
    Returns Error if command fails, metric_fn is unsafe, or output is not a valid float.
    Uses Process_eio.run_argv_with_status to avoid blocking the Eio event loop. *)
let measure_metric ~workdir ~timeout_s metric_fn =
  match validate_metric_fn metric_fn with
  | Error e -> Error e
  | Ok metric_fn ->
  let timeout_flag = Printf.sprintf "timeout %s" (Filename.quote (Printf.sprintf "%.0f" timeout_s)) in
  let cmd = Printf.sprintf "cd %s && %s %s 2>/dev/null | tail -1"
    (Filename.quote workdir) timeout_flag metric_fn in
  let start = Time_compat.now () in
  let _status, raw_output =
    Process_eio.run_argv_with_status ~timeout_sec:(timeout_s +. 5.0)
      ["sh"; "-c"; cmd]
  in
  let elapsed_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  let output = String.trim raw_output in
  match float_of_string_opt output with
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
