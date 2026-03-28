(** Chain Executor Retry Integration

    Wraps chain execution with retry logic from Chain_retry.
    Provides automatic recovery for transient failures.

    @since 0.4.0
*)

(** {1 Execution with Retry} *)

(** Default retry policy for chain nodes *)
let default_node_policy = Chain_retry.{
  max_attempts = 3;
  base_delay_ms = 1000;
  max_delay_ms = 10000;
  exponential_base = 2.0;
  jitter = true;
}

(** Fast retry policy for quick operations *)
let fast_policy = Chain_retry.{
  max_attempts = 2;
  base_delay_ms = 100;
  max_delay_ms = 1000;
  exponential_base = 2.0;
  jitter = true;
}

(** Aggressive retry policy for critical paths *)
let aggressive_policy = Chain_retry.{
  max_attempts = 5;
  base_delay_ms = 500;
  max_delay_ms = 30000;
  exponential_base = 2.0;
  jitter = true;
}

(** {1 Error Classification} *)

(** Classify if a string error message indicates a recoverable condition *)
let is_recoverable_message msg =
  let lower = String.lowercase_ascii msg in
  List.exists (fun pattern -> 
    let len_p = String.length pattern in
    let len_m = String.length lower in
    if len_p > len_m then false
    else
      let rec check i =
        if i > len_m - len_p then false
        else if String.sub lower i len_p = pattern then true
        else check (i + 1)
      in check 0
  ) [
    "timeout"; "timed out";
    "rate limit"; "ratelimit"; "429";
    "connection refused"; "connection reset";
    "temporary"; "transient";
    "retry"; "unavailable";
    "503"; "502"; "504";
    "econnreset"; "etimedout";
  ]

(** Convert string error to Chain_error.t for retry classification *)
let classify_error msg =
  if is_recoverable_message msg then
    Chain_error.Io (Chain_error.NetworkError msg)  (* Recoverable *)
  else
    Chain_error.Internal msg  (* Not recoverable *)

(** {1 Wrapped Execution Functions} *)

(** Execute a node with retry.

    Wraps the execution function with automatic retry on recoverable errors.

    @param clock Eio clock for timing
    @param policy Retry policy to use (default: default_node_policy)
    @param node_id Node identifier for logging
    @param f Execution function returning (string, string) result
    @return Result with retry metadata
*)
let execute_with_retry ~clock ?(policy = default_node_policy) ~node_id f =
  let wrapped () =
    match f () with
    | Ok result -> Ok result
    | Error msg -> Error (classify_error msg)
  in
  let result = Chain_retry.execute_with_retry ~clock ~policy wrapped in
  
  (* Log retry activity *)
  if result.attempts > 1 then
    Chain_log.info "chain_retry" "Node %s: %d attempts, %dms delay, %s"
      node_id
      result.attempts
      result.total_delay_ms
      (match result.value with Ok _ -> "success" | Error _ -> "failed");

  (* Convert back to string error *)
  match result.value with
  | Ok v -> Ok v
  | Error e -> Error (Chain_error.to_string e)

(** Execute MODEL call with retry.

    Specialized retry for MODEL provider calls with appropriate error handling.

    @param clock Eio clock
    @param provider MODEL provider name (for logging)
    @param f MODEL execution function
*)
let execute_model_with_retry ~clock ~provider f =
  let policy = Chain_retry.{
    max_attempts = 3;
    base_delay_ms = 2000;  (* MODEL calls need longer delays *)
    max_delay_ms = 30000;
    exponential_base = 2.0;
    jitter = true;
  } in
  let result = Chain_retry.execute_with_retry ~clock ~policy f in
  
  if result.attempts > 1 then
    Chain_log.info "model_retry" "%s: %d attempts, %dms delay"
      provider result.attempts result.total_delay_ms;

  result

(** Execute tool call with retry.

    Specialized retry for MCP tool calls.

    @param clock Eio clock
    @param tool_name Tool being called
    @param f Tool execution function
*)
let execute_tool_with_retry ~clock ~tool_name f =
  let result = Chain_retry.execute_with_retry ~clock ~policy:fast_policy f in
  
  if result.attempts > 1 then
    Chain_log.info "tool_retry" "%s: %d attempts, %dms delay"
      tool_name result.attempts result.total_delay_ms;

  result

(** {1 Batch Execution with Retry} *)

(** Execute multiple nodes with individual retry.

    Each node gets its own retry budget. Failures are collected
    and returned as a summary.

    @param clock Eio clock
    @param nodes List of (node_id, execution_fn) pairs
    @return List of (node_id, result) pairs
*)
let execute_batch_with_retry ~clock nodes =
  List.map (fun (node_id, f) ->
    let result = execute_with_retry ~clock ~node_id f in
    (node_id, result)
  ) nodes

(** {1 Circuit Breaker Integration} *)

(** Simple circuit breaker state *)
type circuit_state = Closed | Open | HalfOpen

type circuit_breaker = {
  mutable state : circuit_state;
  mutable failure_count : int;
  mutable last_failure : float;
  failure_threshold : int;
  reset_timeout : float;
}

(** Create a circuit breaker *)
let create_breaker ?(failure_threshold = 5) ?(reset_timeout = 30.0) () = {
  state = Closed;
  failure_count = 0;
  last_failure = 0.0;
  failure_threshold;
  reset_timeout;
}

(** Check if circuit allows execution *)
let circuit_allows breaker =
  match breaker.state with
  | Closed -> true
  | Open ->
      let now = Unix.gettimeofday () in
      if now -. breaker.last_failure > breaker.reset_timeout then begin
        breaker.state <- HalfOpen;
        true
      end else false
  | HalfOpen -> true

(** Record success *)
let circuit_success breaker =
  breaker.failure_count <- 0;
  breaker.state <- Closed

(** Record failure *)
let circuit_failure breaker =
  breaker.failure_count <- breaker.failure_count + 1;
  breaker.last_failure <- Unix.gettimeofday ();
  if breaker.failure_count >= breaker.failure_threshold then
    breaker.state <- Open

(** Execute with circuit breaker and retry *)
let execute_with_breaker ~clock ~breaker ~node_id f =
  if not (circuit_allows breaker) then
    Error "Circuit breaker open - service unavailable"
  else
    match execute_with_retry ~clock ~node_id f with
    | Ok v ->
        circuit_success breaker;
        Ok v
    | Error e ->
        circuit_failure breaker;
        Error e
