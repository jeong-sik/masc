type provider_id = string

type state = {
  mutable tokens : float;
  mutable last_refill_at : float;
}

type refill_callback = unit -> unit

type t = {
  provider : provider_id;
  capacity : int;
  refill_rate : float;
  now : unit -> float;
  state : state;
  mutex : Mutex.t;
  mutable on_refill_callbacks : refill_callback list;
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
    on_refill_callbacks = [];
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

let rec fire_on_refill_callbacks t =
  let cbs = with_mutex t (fun () -> t.on_refill_callbacks) in
  List.iter (fun cb -> cb ()) cbs

let refill_locked t =
  let now_ts = t.now () in
  let elapsed = now_ts -. t.state.last_refill_at in
  let old_tokens = t.state.tokens in
  let new_tokens =
    refilled
      ~current_tokens:old_tokens
      ~capacity:t.capacity
      ~refill_rate:t.refill_rate
      ~elapsed_sec:elapsed
  in
  t.state.tokens <- new_tokens;
  t.state.last_refill_at <- now_ts;
  (* Fire on_refill callbacks when refill moves tokens from < 1.0 to >= 1.0,
     i.e. a previously empty bucket now has dispatchable capacity. *)
  if old_tokens < 1.0 && new_tokens >= 1.0 then
    fire_on_refill_callbacks t

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

let release t =
  with_mutex t (fun () ->
      refill_locked t;
      let cap = float_of_int t.capacity in
      if t.state.tokens < cap then
        t.state.tokens <- t.state.tokens +. 1.0;
      (* Clamp to capacity — release should never overfill. *)
      if t.state.tokens > cap then t.state.tokens <- cap)

let add_on_refill t callback =
  with_mutex t (fun () ->
      t.on_refill_callbacks <- callback :: t.on_refill_callbacks)
