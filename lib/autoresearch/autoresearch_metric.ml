(** Autoresearch_metric — Metric measurement and retry logic.

    Runs a shell command (metric_fn) and parses the last line as a float score.
    Supports retry on transient errors (timeout, connection).

    @since 2.80.0 *)

let contains_substring = String_util.contains_substring

let default_metric_name = Agent_sdk.Metric_contract.default_metric_name

let prompt_snippet ?metric_name () =
  Agent_sdk.Metric_contract.prompt_snippet ?metric_name ()

(** Shell metacharacters that indicate injection risk in metric_fn when they
    appear outside quotes. *)
let dangerous_shell_chars =
  [';'; '|'; '&'; '`'; '$'; '('; ')'; '{'; '}'; '<'; '>'; '#'; '!'; '~'; '['; ']'; '*'; '?'; '\\']

type quote_mode = Single | Double

let clip text max_len =
  String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." text |> String_util.to_string

let is_blank = function
  | ' ' | '\t' -> true
  | _ -> false

let split_metric_fn_argv fn =
  let len = String.length fn in
  let buf = Buffer.create len in
  let tokens = ref [] in
  let quote = ref None in
  let push_token () =
    if Buffer.length buf > 0 then begin
      tokens := Buffer.contents buf :: !tokens;
      Buffer.clear buf
    end
  in
  let rec loop i =
    if i >= len then
      match !quote with
      | Some Single -> Error "metric_fn has an unterminated single quote"
      | Some Double -> Error "metric_fn has an unterminated double quote"
      | None ->
        push_token ();
        (match List.rev !tokens with
         | [] -> Error "metric_fn is empty"
         | argv -> Ok argv)
    else
      let c = fn.[i] in
      match !quote with
      | None when c = '\n' || c = '\r' ->
        Error "metric_fn must be a single-line command"
      | None when is_blank c ->
        push_token ();
        loop (i + 1)
      | None ->
        (match c with
         | '\'' ->
           quote := Some Single;
           loop (i + 1)
         | '"' ->
           quote := Some Double;
           loop (i + 1)
         | _ when List.mem c dangerous_shell_chars ->
           Error
             (Printf.sprintf
                "metric_fn contains dangerous shell metacharacters outside quotes: %s"
                fn)
         | _ ->
           Buffer.add_char buf c;
           loop (i + 1))
      | Some Single ->
        if c = '\'' then begin
          quote := None;
          loop (i + 1)
        end else begin
          Buffer.add_char buf c;
          loop (i + 1)
        end
      | Some Double ->
        if c = '"' then begin
          quote := None;
          loop (i + 1)
        end else if c = '\\' && i + 1 < len then begin
          Buffer.add_char buf fn.[i + 1];
          loop (i + 2)
        end else begin
          Buffer.add_char buf c;
          loop (i + 1)
        end
  in
  loop 0

(** Validate that metric_fn can be tokenized safely.
    Returns Ok fn on success, Error message on failure. *)
let validate_metric_fn fn =
  split_metric_fn_argv fn |> Result.map (fun _ -> fn)

let last_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.rev
  |> List.find_opt (fun line -> String.trim line <> "")
  |> Option.map String.trim

let parse_metric_output output =
  let trimmed = String.trim output in
  match Agent_sdk.Metric_contract.parse trimmed with
  | Ok metric -> Result.ok metric.value
  | Error tag_error ->
    let candidate =
      match last_nonempty_line output with
      | Some line -> line
      | None -> trimmed
    in
    match float_of_string_opt candidate with
    | Some v -> Result.ok v
    | None ->
      Result.error
        (Printf.sprintf
           "metric_fn output not a float or metric tag: %S (%s). Expected contract: %s"
           (clip trimmed 240) tag_error
           (prompt_snippet ()))

let run_metric_argv ~workdir ~timeout_s argv =
  let config =
    { Masc_mcp_cdal_runtime.Autonomy_exec.default_config with
      cwd = Some workdir; }
  in
  match Process_eio.get_clock () with
  | Error e -> Result.error (Printf.sprintf "metric_fn runtime unavailable: %s" e)
  | Ok clock ->
    Eio.Switch.run @@ fun sw ->
    match Masc_mcp_cdal_runtime.Autonomy_exec.run ~sw ~clock ~config ~argv ~timeout_s with
    | Error err ->
      Result.error
        (Printf.sprintf "metric_fn exec failed: %s"
           (Agent_sdk.Error.to_string err))
    | Ok output ->
      let elapsed_ms = int_of_float (output.elapsed_s *. 1000.0) in
      (match output.status with
       | Masc_mcp_cdal_runtime.Autonomy_exec.Exit_code 0 ->
         Result.ok (output.stdout, elapsed_ms)
       | (Masc_mcp_cdal_runtime.Autonomy_exec.Exit_code _
         | Masc_mcp_cdal_runtime.Autonomy_exec.Exit_signal _
         | Masc_mcp_cdal_runtime.Autonomy_exec.Timed_out _) as status ->
         let detail =
           let stderr = String.trim output.stderr in
           let stdout = String.trim output.stdout in
           if stderr <> "" then stderr
           else if stdout <> "" then stdout
           else Masc_mcp_cdal_runtime.Autonomy_exec.argv_to_string output.effective_argv
         in
         Result.error
           (Printf.sprintf "metric_fn %s: %s"
              (Masc_mcp_cdal_runtime.Autonomy_exec.status_to_string status)
              (clip detail 240)))

(** Run metric_fn command and parse either a strict metric tag or the last
    non-empty stdout line as a float.
    Returns Error if command fails, metric_fn is unsafe, or output is not a valid float.
    Uses Masc_mcp_cdal_runtime.Autonomy_exec for argv-only execution. *)
let measure_metric ~workdir ~timeout_s metric_fn =
  match split_metric_fn_argv metric_fn with
  | Error e -> Error e
  | Ok argv ->
    (match run_metric_argv ~workdir ~timeout_s argv with
     | Error _ as err -> err
     | Ok (raw_output, elapsed_ms) ->
       parse_metric_output raw_output
       |> Result.map (fun score -> (score, elapsed_ms)))

(** Run metric_fn with retry on transient errors (timeout, connection).
    Returns Ok (score, total_elapsed_ms) or Error on non-transient failure.
    max_retries=2 means up to 3 total attempts. *)
let measure_metric_with_retry ~workdir ~timeout_s ?(max_retries = 2) metric_fn =
  let is_transient err =
    let lower = String.lowercase_ascii err in
    contains_substring lower "timeout"
    || contains_substring lower "timed_out"
    || contains_substring lower "connection"
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
