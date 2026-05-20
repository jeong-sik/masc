(** Cascade_tier_admission — per-tier inflight admission control.

    RFC-0153 Phase B.1. See [.mli] for the full contract.

    Implementation uses [Eio.Mutex] for per-tier counter + a single
    structural mutex guarding the tier-id Hashtbl during lazy tier
    creation. The fast path (already-known tier) takes only the
    tier-local mutex.

    Why not [Eio.Semaphore]? [Eio.Semaphore.acquire] blocks; this
    module is non-blocking by design (the cascade chain caller
    decides what to do on capacity_full — typically advance to the
    next tier, return a typed signal, or schedule a retry).
    Non-blocking is also why [with_admission] does not require an
    [Eio.Switch.t]: there is no asynchronous wait to cancel. *)

type tier_id = string

type admission_policy =
  | Required
  | Bypass

type tier_state = {
  mu : Eio.Mutex.t;
  mutable inflight : int;
  mutable max_inflight : int;
}

type t = {
  tiers : (tier_id, tier_state) Hashtbl.t;
  guard_mu : Eio.Mutex.t;
  default_max_inflight : int;
}

type try_decision =
  | Granted of { inflight_after_acquire : int; max_inflight : int }
  | Capacity_full of { inflight_at_check : int; max_inflight : int }

let default_default_max_inflight = 8

let create ?(default_max_inflight = default_default_max_inflight) () =
  {
    tiers = Hashtbl.create 8;
    guard_mu = Eio.Mutex.create ();
    default_max_inflight;
  }

(* Lazy tier creation: under [guard_mu] check-and-insert pattern.
   The Hashtbl is mutated only here. After tier_state exists in the
   table, subsequent operations on that tier use its own [mu]
   without touching [guard_mu]. *)
let get_or_create_tier t tier_id =
  Eio.Mutex.use_rw t.guard_mu ~protect:false (fun () ->
      match Hashtbl.find_opt t.tiers tier_id with
      | Some ts -> ts
      | None ->
          let ts =
            {
              mu = Eio.Mutex.create ();
              inflight = 0;
              max_inflight = t.default_max_inflight;
            }
          in
          Hashtbl.add t.tiers tier_id ts;
          ts)

let configure t ~tier_id ~max_inflight =
  let ts = get_or_create_tier t tier_id in
  Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
      ts.max_inflight <- max_inflight)

let try_acquire t ~tier_id =
  let ts = get_or_create_tier t tier_id in
  Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
      if ts.inflight < ts.max_inflight
      then begin
        ts.inflight <- ts.inflight + 1;
        Granted
          {
            inflight_after_acquire = ts.inflight;
            max_inflight = ts.max_inflight;
          }
      end
      else
        Capacity_full
          {
            inflight_at_check = ts.inflight;
            max_inflight = ts.max_inflight;
          })

let release t ~tier_id =
  match Hashtbl.find_opt t.tiers tier_id with
  | None -> ()  (* release before any acquire — no-op *)
  | Some ts ->
      Eio.Mutex.use_rw ts.mu ~protect:false (fun () ->
          if ts.inflight > 0 then ts.inflight <- ts.inflight - 1)

(* Release that swallows its own exceptions. Used as a finally clause
   so we never mask the primary exception path. Per masc-mcp
   manifest §"finally는 예외를 내부 처리". *)
let release_quietly t ~tier_id =
  try release t ~tier_id with _ -> ()

let with_admission t ~tier_id ~admission_policy f =
  match admission_policy with
  | Bypass -> Ok (f ())
  | Required ->
      (match try_acquire t ~tier_id with
       | Capacity_full { inflight_at_check = _; max_inflight } ->
           Error
             (Cascade_saturation_signal.Inflight_capacity_full
                { tier_id; max_inflight })
       | Granted _ ->
           (match f () with
            | v ->
                release_quietly t ~tier_id;
                Ok v
            | exception exn ->
                release_quietly t ~tier_id;
                raise exn))

let current_inflight t ~tier_id =
  match Hashtbl.find_opt t.tiers tier_id with
  | None -> 0
  | Some ts ->
      Eio.Mutex.use_ro ts.mu (fun () -> ts.inflight)

let configured_max t ~tier_id =
  match Hashtbl.find_opt t.tiers tier_id with
  | None -> t.default_max_inflight
  | Some ts ->
      Eio.Mutex.use_ro ts.mu (fun () -> ts.max_inflight)
