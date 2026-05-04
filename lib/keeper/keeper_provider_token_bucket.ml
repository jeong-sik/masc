type provider_id = string

type state = {
  mutable tokens : float;
  mutable last_refill_at : float;
}

type t = {
  provider : provider_id;
  capacity : int;
  refill_rate : float;
  now : unit -> float;
  state : state;
  mutex : Mutex.t;
}

let refilled ~current_tokens ~capacity ~refill_rate ~elapsed_sec =
  if elapsed_sec <= 0.0 then current_tokens
  else
    let added = elapsed_sec *. refill_rate in
    let raw = current_tokens +. added in
    let cap = float_of_int capacity in
    if raw > cap then cap else raw

let create ~provider ~capacity ~refill_rate ~now =
  if capacity < 1 then
    invalid_arg "Keeper_provider_token_bucket.create: capacity must be >= 1";
  if refill_rate <= 0.0 then
    invalid_arg
      "Keeper_provider_token_bucket.create: refill_rate must be > 0.0";
  {
    provider;
    capacity;
    refill_rate;
    now;
    state = { tokens = float_of_int capacity; last_refill_at = now () };
    mutex = Mutex.create ();
  }

let with_mutex t f =
  Mutex.lock t.mutex;
  match f () with
  | v ->
    Mutex.unlock t.mutex;
    v
  | exception e ->
    Mutex.unlock t.mutex;
    raise e

let refill_locked t =
  let now_ts = t.now () in
  let elapsed = now_ts -. t.state.last_refill_at in
  let new_tokens =
    refilled
      ~current_tokens:t.state.tokens
      ~capacity:t.capacity
      ~refill_rate:t.refill_rate
      ~elapsed_sec:elapsed
  in
  t.state.tokens <- new_tokens;
  t.state.last_refill_at <- now_ts

let try_acquire t =
  with_mutex t (fun () ->
      refill_locked t;
      if t.state.tokens >= 1.0 then begin
        t.state.tokens <- t.state.tokens -. 1.0;
        true
      end
      else false)

let tokens_available t =
  with_mutex t (fun () ->
      refill_locked t;
      t.state.tokens)

let provider t = t.provider
