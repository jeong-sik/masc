(* Recovery — Cycle 23 / Tier B6.
   Classification surface only; strategy execution (Retry/Fallback/Handoff/
   Abort) is intentionally deferred — see resilience_runtime.mli §Deferred
   and docs/audit-responses/2026-05-05-dashboard-heuristic.md §4.
   See recovery.mli for the design rationale. *)

type error_mode =
  | TransientError of {
      detail : string;
      max_retries : int;
      backoff_ms : int;
    }
  | PermanentError of { detail : string; fallback_strategy : fallback }
  | ResourceExhausted of {
      resource : [ `Tokens | `Time | `Cost | `Memory | `Disk ];
      consumed : float;
      limit : float;
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
  ResourceExhausted { resource; consumed; limit }

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
    ("memory", `Memory);
    ("disk", `Disk);
    ("budget", `Cost);
  ]

let classify_string (s : string) : error_mode =
  if List.exists (fun p -> lowercased_contains s p) transient_phrases then
    transient ~detail:s ~max_retries:3 ~backoff_ms:250 ()
  else
    match
      List.find_opt
        (fun (p, _) -> lowercased_contains s p)
        resource_phrases
    with
    | Some (_, resource) ->
        resource_exhausted ~resource ~consumed:0.0 ~limit:0.0
    | None -> permanent ~detail:s ~fallback:(HumanHandoff s)

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
  | ResourceExhausted { resource; consumed; limit } ->
      let resource_str =
        match resource with
        | `Tokens -> "Tokens"
        | `Time -> "Time"
        | `Cost -> "Cost"
        | `Memory -> "Memory"
        | `Disk -> "Disk"
      in
      Abort
        {
          reason =
            Printf.sprintf
              "ResourceExhausted: %s consumed=%.2f limit=%.2f"
              resource_str consumed limit;
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
