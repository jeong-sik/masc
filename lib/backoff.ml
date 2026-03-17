(** Backoff — General-purpose exponential backoff with jitter

    Chain-independent retry utility for any recoverable operation.
    Integrates with Eio for cooperative sleeping.

    Usage:
    {[
      let policy = Backoff.default_policy in
      match Backoff.retry ~clock ~policy (fun () ->
        do_something_fallible ()
      ) with
      | Ok result -> handle result
      | Error { last_error; attempts; _ } ->
          Log.warn "failed after %d attempts: %s" attempts last_error
    ]}

    @since 2.102.0 *)

(** {1 Configuration} *)

type policy = {
  max_attempts : int;       (** Total attempts including the first (min 1) *)
  base_delay_s : float;     (** Initial delay between retries in seconds *)
  max_delay_s : float;      (** Delay cap *)
  multiplier : float;       (** Exponential multiplier (typically 2.0) *)
  jitter : bool;            (** Add ±20% random jitter *)
}

let default_policy = {
  max_attempts = 3;
  base_delay_s = 1.0;
  max_delay_s = 30.0;
  multiplier = 2.0;
  jitter = true;
}

let aggressive_policy = {
  max_attempts = 5;
  base_delay_s = 0.5;
  max_delay_s = 60.0;
  multiplier = 2.0;
  jitter = true;
}

let fast_policy = {
  max_attempts = 2;
  base_delay_s = 0.1;
  max_delay_s = 1.0;
  multiplier = 2.0;
  jitter = true;
}

let no_retry = {
  max_attempts = 1;
  base_delay_s = 0.0;
  max_delay_s = 0.0;
  multiplier = 1.0;
  jitter = false;
}

(** {1 Result} *)

type 'a retry_result = {
  value : ('a, string) result;
  attempts : int;
  total_delay_s : float;
  last_error : string;
}

(** {1 Delay Calculation} *)

(* Fiber-safe random state for jitter *)
let jitter_rng = Random.State.make_self_init ()

let delay_for_attempt (policy : policy) (attempt : int) : float =
  if attempt <= 0 then 0.0
  else
    let raw = policy.base_delay_s *. (policy.multiplier ** float_of_int (attempt - 1)) in
    let capped = Float.min raw policy.max_delay_s in
    if policy.jitter then
      let range = capped *. 0.4 in  (* ±20% *)
      capped +. Random.State.float jitter_rng range -. (range /. 2.0)
    else capped

(** {1 Retry Execution} *)

(** Retry with exponential backoff using Eio clock for sleeping.
    [f] should return [Ok value] on success or [Error message] on failure.
    Returns the final result after all attempts are exhausted. *)
let retry ~clock ~(policy : policy) (f : unit -> ('a, string) result) : 'a retry_result =
  let rec loop attempt total_delay last_err =
    if attempt >= policy.max_attempts then
      { value = Error last_err; attempts = attempt;
        total_delay_s = total_delay; last_error = last_err }
    else
      match f () with
      | Ok v ->
          { value = Ok v; attempts = attempt + 1;
            total_delay_s = total_delay; last_error = last_err }
      | Error msg ->
          let delay = delay_for_attempt policy (attempt + 1) in
          if attempt + 1 < policy.max_attempts then
            Eio.Time.sleep clock delay;
          loop (attempt + 1) (total_delay +. delay) msg
  in
  loop 0 0.0 ""

(** Retry variant that catches exceptions as errors. *)
let retry_exn ~clock ~(policy : policy) (f : unit -> 'a) : 'a retry_result =
  retry ~clock ~policy (fun () ->
    try Ok (f ())
    with exn -> Error (Printexc.to_string exn))

(** {1 Pure Delay Sequence (no Eio dependency)} *)

(** Generate the delay sequence for a policy (for testing/logging). *)
let delay_sequence (policy : policy) : float list =
  List.init (max 0 (policy.max_attempts - 1)) (fun i ->
    delay_for_attempt { policy with jitter = false } (i + 1))
