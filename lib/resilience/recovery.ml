(* Recovery — Cycle 23 / Tier B6.
   Classification plus callback-driven strategy execution. Keeper-turn
   lifecycle integration remains outside this module; see recovery.mli for
   the design rationale.

   Audit response 2026-05-05 §4: classification + audit log entry only;
   strategy execution is deferred until the keeper-turn wire-in lands
   (see resilience_runtime.mli §Deferred). External audits should read the
   matrix at docs/audit-responses/2026-05-05-dashboard-heuristic.md before
   filing claims against this module. *)

type error_mode =
  | TransientError of {
      detail : string;
      max_retries : int;
      backoff_ms : int;
    }
  | PermanentError of { detail : string; fallback_strategy : fallback }
  | ResourceExhausted of {
      resource : [ `Tokens | `Time | `Cost | `Memory | `Disk ];
      consumed : float option;
      limit : float option;
      detail : string option;
    }
  | AmbiguityError of { detail : string; branches : string list }
  | ConsensusError of { detail : string; dissenters : string list }
  | DegradationRequired of { detail : string; recommended_level : int }

and fallback =
  | UseDefaultString of string
  | UsePlaceholder of string
  | SkipArtifact of string
  | HumanHandoff of string

type _ strategy =
  | Retry : {
      max_attempts : int;
      backoff : int -> float;
    }
      -> [> `Retry ] strategy
  | Fallback : { fallback_value : string; degrade_confidence_by : float }
      -> [> `Fallback ] strategy
  | Handoff : { operator_message : string; preserve_state : bool }
      -> [> `Handoff ] strategy
  | Abort : { reason : string; cleanup : unit -> unit }
      -> [> `Abort ] strategy

type retry_attempt_result =
  | Retry_success
  | Retryable_failure of string
  | Fatal_failure of string

type execution_event =
  | RetryAttempt of { attempt : int; max_attempts : int }
  | RetryBackoff of { attempt : int; delay_s : float; error : string }
  | FallbackApply of { value : string; confidence_delta : float }
  | HandoffRequest of { message : string; preserve_state : bool }
  | AbortRun of { reason : string }

type execution_outcome =
  | RetrySucceeded of { attempts : int }
  | RetryExhausted of { attempts : int; last_error : string option }
  | RetryFatal of { attempt : int; error : string }
  | FallbackApplied of { value : string; confidence_delta : float }
  | HandoffRequested of { message : string; preserve_state : bool }
  | Aborted of { reason : string }

type strategy_executor = {
  run_retry_attempt : attempt:int -> retry_attempt_result;
  sleep : float -> unit;
  on_event : execution_event -> unit;
  apply_fallback :
    value:string -> confidence_delta:float -> (unit, string) result;
  request_handoff :
    message:string -> preserve_state:bool -> (unit, string) result;
  abort : reason:string -> (unit, string) result;
}

let clamp_delay_s delay_s =
  if Float.is_finite delay_s then max 0.0 delay_s else 0.0

(* #13072 — every executor callback (on_event, run_retry_attempt,
   sleep, apply_fallback, request_handoff, abort) is foreign code
   from this module's perspective; an exception escaping any of them
   bypasses [keeper_bridge]'s [Strategy_execution_failed] audit and
   tears down the keeper turn. Wrap each call in [trap] so executor
   misbehaviour surfaces as [Error <string>] like the existing
   [cleanup] arm in [Abort]. Keep this module independent from Eio;
   cancellation-aware callers should encode cancellation in their
   executor result rather than adding a scheduler dependency here. *)
let trap_call ~op f =
  match f () with
  | exception exn ->
      Error (Printf.sprintf "%s raised: %s" op (Printexc.to_string exn))
  | v -> Ok v

let execute_strategy : type a.
    strategy_executor ->
    a strategy ->
    (execution_outcome, string) result =
 fun executor strategy ->
  let ( let* ) = Result.bind in
  let on_event evt = trap_call ~op:"on_event" (fun () -> executor.on_event evt) in
  match strategy with
  | Retry { max_attempts; backoff } ->
      let max_attempts = max 1 max_attempts in
      let rec loop attempt =
        let* () = on_event (RetryAttempt { attempt; max_attempts }) in
        let* outcome =
          trap_call ~op:"run_retry_attempt" (fun () ->
            executor.run_retry_attempt ~attempt)
        in
        match outcome with
        | Retry_success -> Ok (RetrySucceeded { attempts = attempt })
        | Fatal_failure error ->
            Ok (RetryFatal { attempt; error })
        | Retryable_failure error ->
            if attempt >= max_attempts then
              Ok
                (RetryExhausted
                   { attempts = attempt; last_error = Some error })
            else
              (* PR #13072 review: the strategy's [backoff] callback is
                 part of the public [Retry.t] API and may raise (caller
                 typo, integer overflow on attempt, etc.).  Without this
                 trap the exception escaped and tore down the turn,
                 instead of being converted into the [Error ...] that
                 [execute_strategy]'s contract promises. *)
              let* delay_s_raw =
                trap_call ~op:"backoff" (fun () -> backoff attempt)
              in
              let delay_s = clamp_delay_s delay_s_raw in
              let* () =
                on_event (RetryBackoff { attempt; delay_s; error })
              in
              let* () =
                trap_call ~op:"sleep" (fun () -> executor.sleep delay_s)
              in
              loop (attempt + 1)
      in
      loop 1
  | Fallback { fallback_value; degrade_confidence_by } ->
      let confidence_delta = degrade_confidence_by in
      let* () =
        on_event (FallbackApply { value = fallback_value; confidence_delta })
      in
      let* applied =
        trap_call ~op:"apply_fallback" (fun () ->
          executor.apply_fallback ~value:fallback_value ~confidence_delta)
      in
      Result.map
        (fun () ->
          FallbackApplied { value = fallback_value; confidence_delta })
        applied
  | Handoff { operator_message; preserve_state } ->
      let* () =
        on_event (HandoffRequest { message = operator_message; preserve_state })
      in
      let* requested =
        trap_call ~op:"request_handoff" (fun () ->
          executor.request_handoff ~message:operator_message ~preserve_state)
      in
      Result.map
        (fun () ->
          HandoffRequested { message = operator_message; preserve_state })
        requested
  | Abort { reason; cleanup } ->
      let* () =
        trap_call ~op:"cleanup" (fun () -> cleanup ())
      in
      let* () = on_event (AbortRun { reason }) in
      let* aborted =
        trap_call ~op:"abort" (fun () -> executor.abort ~reason)
      in
      Result.map
        (fun () -> Aborted { reason })
        aborted

(* TLA+ taxonomy mirrors for specs/resilience/ResilienceDegradation.tla.
   Payload-bearing constructors cannot use ppx_tla's [all_states], so
   the exhaustive functions below are the typed contract and the lists
   are the set surface consumed by parity tests. *)
let error_mode_to_tla_symbol = function
  | TransientError _ -> "Transient"
  | PermanentError _ -> "Permanent"
  | ResourceExhausted _ -> "ResourceExhausted"
  | AmbiguityError _ -> "Ambiguity"
  | ConsensusError _ -> "Consensus"
  | DegradationRequired _ -> "Degradation"

let all_error_mode_tla_symbols =
  [ "Transient";
    "Permanent";
    "ResourceExhausted";
    "Ambiguity";
    "Consensus";
    "Degradation";
  ]

let strategy_to_tla_symbol : type a. a strategy -> string = function
  | Retry _ -> "Retry"
  | Fallback _ -> "Fallback"
  | Handoff _ -> "Handoff"
  | Abort _ -> "Abort"

let all_strategy_tla_symbols = [ "Retry"; "Fallback"; "Handoff"; "Abort" ]

(* ── Convenience constructors ─────────────────────────────────── *)

let transient ~detail ?(max_retries = 3) ?(backoff_ms = 200) () =
  TransientError { detail; max_retries; backoff_ms }

let permanent ~detail ~fallback =
  PermanentError { detail; fallback_strategy = fallback }

let resource_exhausted ~resource ~consumed ~limit =
  ResourceExhausted
    { resource; consumed = Some consumed; limit = Some limit; detail = None }

let resource_exhausted_unknown ~resource ~detail =
  ResourceExhausted
    { resource; consumed = None; limit = None; detail = Some detail }

let ambiguity ~detail ~branches = AmbiguityError { detail; branches }

let consensus_failure ~detail ~dissenters =
  ConsensusError { detail; dissenters }

let degradation_required ~detail ~recommended_level =
  DegradationRequired { detail; recommended_level }

(* ── Heuristic classification ─────────────────────────────────── *)

let lowercased_contains haystack needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let h_len = String.length h in
  let n_len = String.length n in
  if n_len = 0 then true
  else if n_len > h_len then false
  else
    let rec loop i =
      if i + n_len > h_len then false
      else if String.sub h i n_len = n then true
      else loop (i + 1)
    in
    loop 0

let transient_phrases =
  [ "timeout";
    "timed out";
    "rate limit";
    "rate-limit";
    "too many requests";
    "connection reset";
    "connection refused";
    "temporarily unavailable";
    "temporary";
    "try again";
    "transient";
  ]

let resource_phrases =
  [ ("token", `Tokens);
    ("context overflow", `Tokens);
    ("context window", `Tokens);
    ("context length", `Tokens);
    ("memory", `Memory);
    ("disk", `Disk);
    ("quota", `Cost);
    ("credit", `Cost);
    ("resource exhausted", `Cost);
    ("budget", `Cost);
    ("cost", `Cost);
  ]

let classify_string (s : string) : error_mode =
  match
    List.find_opt
      (fun (p, _) -> lowercased_contains s p)
      resource_phrases
  with
  | Some (_, resource) ->
      resource_exhausted_unknown ~resource ~detail:s
  | None ->
      if List.exists (fun p -> lowercased_contains s p) transient_phrases then
        transient ~detail:s ~max_retries:3 ~backoff_ms:250 ()
      else
        permanent ~detail:s ~fallback:(HumanHandoff s)

(* ── Default strategy selection ───────────────────────────────── *)

let default_strategy (mode : error_mode) :
    [ `Retry | `Fallback | `Handoff | `Abort ] strategy =
  match mode with
  | TransientError { max_retries; backoff_ms; _ } ->
      let backoff_seconds = float_of_int backoff_ms /. 1000.0 in
      Retry
        {
          max_attempts = max max_retries 1;
          backoff = (fun n -> backoff_seconds *. float_of_int (n + 1));
        }
  | PermanentError { fallback_strategy; detail } -> (
      match fallback_strategy with
      | UseDefaultString v ->
          Fallback
            { fallback_value = v; degrade_confidence_by = 0.2 }
      | UsePlaceholder name ->
          Fallback
            {
              fallback_value = "<placeholder:" ^ name ^ ">";
              degrade_confidence_by = 0.4;
            }
      | SkipArtifact aid ->
          Fallback
            {
              fallback_value = "<skipped:" ^ aid ^ ">";
              degrade_confidence_by = 0.5;
            }
      | HumanHandoff msg ->
          Handoff
            {
              operator_message =
                Printf.sprintf
                  "permanent error: %s — handoff requested: %s"
                  detail msg;
              preserve_state = true;
            })
  | ResourceExhausted { resource; consumed; limit; detail } ->
      let resource_str =
        match resource with
        | `Tokens -> "Tokens"
        | `Time -> "Time"
        | `Cost -> "Cost"
        | `Memory -> "Memory"
        | `Disk -> "Disk"
      in
      let measurement =
        match consumed, limit with
        | Some consumed, Some limit ->
            Printf.sprintf "consumed=%.2f limit=%.2f" consumed limit
        | _ ->
            match detail with
            | Some detail ->
                Printf.sprintf "measurement=unknown detail=%S" detail
            | None -> "measurement=unknown"
      in
      Abort
        {
          reason =
            Printf.sprintf
              "ResourceExhausted: %s %s"
              resource_str measurement;
          cleanup = (fun () -> ());
        }
  | AmbiguityError { detail; branches } ->
      Handoff
        {
          operator_message =
            Printf.sprintf
              "Ambiguity: %s. Branches: %s. (Speculate deferred to A11)"
              detail
              (String.concat ", " branches);
          preserve_state = true;
        }
  | ConsensusError { detail; dissenters } ->
      Handoff
        {
          operator_message =
            Printf.sprintf
              "Consensus failure: %s. Dissenters: %s."
              detail
              (String.concat ", " dissenters);
          preserve_state = true;
        }
  | DegradationRequired { detail; recommended_level } ->
      Handoff
        {
          operator_message =
            Printf.sprintf
              "Degrade required (target L%d): %s. (Degrade strategy \
               deferred to A11)"
              recommended_level detail;
          preserve_state = true;
        }
