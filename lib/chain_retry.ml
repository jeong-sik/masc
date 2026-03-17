(** Chain Retry - Error Recovery with Exponential Backoff

    OpenClaw-inspired retry policies for chain execution.
    Integrates with Chain_error.t for structured error handling.

    @since 0.4.0
*)

(* Fiber-safe random state for jitter calculation *)
let jitter_rng = Random.State.make_self_init ()

(** {1 Retry Configuration} *)

type retry_policy = {
  max_attempts : int;           (** Maximum number of attempts (including first) *)
  base_delay_ms : int;          (** Base delay between retries in milliseconds *)
  max_delay_ms : int;           (** Maximum delay cap *)
  exponential_base : float;     (** Multiplier for exponential backoff (e.g., 2.0) *)
  jitter : bool;                (** Add random jitter to prevent thundering herd *)
}

(** Default retry policy - 3 attempts with exponential backoff *)
let default_policy = {
  max_attempts = 3;
  base_delay_ms = 1000;
  max_delay_ms = 30000;
  exponential_base = 2.0;
  jitter = true;
}

(** Aggressive retry for transient errors *)
let aggressive_policy = {
  max_attempts = 5;
  base_delay_ms = 500;
  max_delay_ms = 60000;
  exponential_base = 2.0;
  jitter = true;
}

(** No retry - fail immediately *)
let no_retry_policy = {
  max_attempts = 1;
  base_delay_ms = 0;
  max_delay_ms = 0;
  exponential_base = 1.0;
  jitter = false;
}

(** {1 Retry Result} *)

type 'a retry_result = {
  value : ('a, Chain_error.t) result;  (** Final result *)
  attempts : int;                 (** Total attempts made *)
  total_delay_ms : int;           (** Total time spent waiting *)
  errors : Chain_error.t list;          (** All errors encountered *)
}

(** {1 Delay Calculation} *)

(** Calculate delay for attempt N (0-indexed) *)
let calculate_delay policy attempt =
  if attempt = 0 then 0
  else
    let base = float_of_int policy.base_delay_ms in
    let exp_delay = base *. (policy.exponential_base ** float_of_int (attempt - 1)) in
    let capped = min exp_delay (float_of_int policy.max_delay_ms) in
    let with_jitter =
      if policy.jitter then
        let jitter_range = capped *. 0.2 in  (* ±10% jitter *)
        capped +. (Random.State.float jitter_rng jitter_range) -. (jitter_range /. 2.0)
      else capped
    in
    int_of_float (max 0.0 with_jitter)

(** {1 Retry Execution} *)

(** Execute with retry using Eio for async sleep *)
let execute_with_retry ~clock ~policy f =
  let rec loop attempt errors total_delay =
    if attempt >= policy.max_attempts then
      let last_error = match errors with
        | e :: _ -> e
        | [] -> Chain_error.Internal "No error recorded"
      in
      { value = Error last_error; attempts = attempt; total_delay_ms = total_delay; errors = List.rev errors }
    else
      let delay = calculate_delay policy attempt in
      if delay > 0 then begin
        Eio.Time.sleep clock (float_of_int delay /. 1000.0)
      end;
      match f () with
      | Ok v ->
          { value = Ok v; attempts = attempt + 1; total_delay_ms = total_delay + delay; errors = List.rev errors }
      | Error e ->
          if Chain_error.is_recoverable e && attempt + 1 < policy.max_attempts then
            loop (attempt + 1) (e :: errors) (total_delay + delay)
          else
            { value = Error e; attempts = attempt + 1; total_delay_ms = total_delay + delay; errors = List.rev (e :: errors) }
  in
  loop 0 [] 0

(** Execute with retry - sync version (for non-Eio contexts) *)
let execute_with_retry_sync ~policy f =
  let rec loop attempt errors total_delay =
    if attempt >= policy.max_attempts then
      let last_error = match errors with
        | e :: _ -> e
        | [] -> Chain_error.Internal "No error recorded"
      in
      { value = Error last_error; attempts = attempt; total_delay_ms = total_delay; errors = List.rev errors }
    else
      let delay = calculate_delay policy attempt in
      if delay > 0 then Time_compat.sleep (float_of_int delay /. 1000.0);
      match f () with
      | Ok v ->
          { value = Ok v; attempts = attempt + 1; total_delay_ms = total_delay + delay; errors = List.rev errors }
      | Error e ->
          if Chain_error.is_recoverable e && attempt + 1 < policy.max_attempts then
            loop (attempt + 1) (e :: errors) (total_delay + delay)
          else
            { value = Error e; attempts = attempt + 1; total_delay_ms = total_delay + delay; errors = List.rev (e :: errors) }
  in
  loop 0 [] 0

(** {1 Retry with Context} *)

(** Retry context for tracking across multiple operations *)
type retry_context = {
  mutable total_attempts : int;
  mutable total_retries : int;
  mutable total_delay_ms : int;
  mutable error_counts : (string, int) Hashtbl.t;
}

let create_retry_context () = {
  total_attempts = 0;
  total_retries = 0;
  total_delay_ms = 0;
  error_counts = Hashtbl.create 8;
}

(** Execute with retry and update context *)
let execute_with_context ~clock ~policy ~ctx f =
  let result = execute_with_retry ~clock ~policy f in
  ctx.total_attempts <- ctx.total_attempts + result.attempts;
  ctx.total_retries <- ctx.total_retries + max 0 (result.attempts - 1);
  ctx.total_delay_ms <- ctx.total_delay_ms + result.total_delay_ms;
  List.iter (fun e ->
    let key = Chain_error.to_string e in
    let count = match Hashtbl.find_opt ctx.error_counts key with Some n -> n | None -> 0 in
    Hashtbl.replace ctx.error_counts key (count + 1)
  ) result.errors;
  result

(** {1 Specialized Retry Functions} *)

(** Retry only on specific error types *)
let execute_with_filter ~clock ~policy ~should_retry f =
  let rec loop attempt errors total_delay =
    if attempt >= policy.max_attempts then
      let last_error = match errors with
        | e :: _ -> e
        | [] -> Chain_error.Internal "No error recorded"
      in
      { value = Error last_error; attempts = attempt; total_delay_ms = total_delay; errors = List.rev errors }
    else
      let delay = calculate_delay policy attempt in
      if delay > 0 then
        Eio.Time.sleep clock (float_of_int delay /. 1000.0);
      match f () with
      | Ok v ->
          { value = Ok v; attempts = attempt + 1; total_delay_ms = total_delay + delay; errors = List.rev errors }
      | Error e ->
          if should_retry e && attempt + 1 < policy.max_attempts then
            loop (attempt + 1) (e :: errors) (total_delay + delay)
          else
            { value = Error e; attempts = attempt + 1; total_delay_ms = total_delay + delay; errors = List.rev (e :: errors) }
  in
  loop 0 [] 0

(** Retry with timeout *)
let execute_with_timeout ~clock ~policy ~timeout_ms f =
  let start = Unix.gettimeofday () *. 1000.0 in
  let rec loop attempt errors total_delay =
    let elapsed = (Unix.gettimeofday () *. 1000.0) -. start in
    if elapsed >= float_of_int timeout_ms then
      { value = Error (Chain_error.Chain (Chain_error.ChainTimeoutError timeout_ms)); 
        attempts = attempt; total_delay_ms = total_delay; errors = List.rev errors }
    else if attempt >= policy.max_attempts then
      let last_error = match errors with
        | e :: _ -> e
        | [] -> Chain_error.Internal "No error recorded"
      in
      { value = Error last_error; attempts = attempt; total_delay_ms = total_delay; errors = List.rev errors }
    else
      let delay = calculate_delay policy attempt in
      let remaining = float_of_int timeout_ms -. elapsed in
      let actual_delay = min (float_of_int delay) remaining in
      if actual_delay > 0.0 then
        Eio.Time.sleep clock (actual_delay /. 1000.0);
      match f () with
      | Ok v ->
          { value = Ok v; attempts = attempt + 1; total_delay_ms = total_delay + int_of_float actual_delay; errors = List.rev errors }
      | Error e ->
          if Chain_error.is_recoverable e && attempt + 1 < policy.max_attempts then
            loop (attempt + 1) (e :: errors) (total_delay + int_of_float actual_delay)
          else
            { value = Error e; attempts = attempt + 1; total_delay_ms = total_delay + int_of_float actual_delay; errors = List.rev (e :: errors) }
  in
  loop 0 [] 0

(** {1 Logging} *)

let log_retry_result ~node_id result =
  if result.attempts > 1 then
    Chain_log.info "[Retry] Node %s: %d attempts, %dms total delay, %s"
      node_id
      result.attempts
      result.total_delay_ms
      (match result.value with Ok _ -> "success" | Error _ -> "failed")
