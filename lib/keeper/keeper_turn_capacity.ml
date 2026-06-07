type rejection =
  { limit : int
  ; inflight : int
  ; waited_ms : int
  }

type acquired =
  { release : unit -> unit
  ; wait_ms : int
  }

let inflight = Atomic.make 0

let waited_ms ~started_at =
  let waited_s = Time_compat.now () -. started_at in
  int_of_float ((if waited_s < 0.0 then 0.0 else waited_s) *. 1000.0)
;;

let release_global_capacity () =
  let rec loop () =
    let current = Atomic.get inflight in
    if current <= 0
    then ()
    else if not (Atomic.compare_and_set inflight current (current - 1))
    then loop ()
  in
  loop ()
;;

let acquire_global_capacity ~timeout_s =
  let started_at = Time_compat.now () in
  let rec loop () =
    let limit = Keeper_config.keeper_turn_capacity_limit () in
    if limit <= 0
    then Ok { release = (fun () -> ()); wait_ms = waited_ms ~started_at }
    else (
      let current = Atomic.get inflight in
      if current < limit
      then
        if Atomic.compare_and_set inflight current (current + 1)
        then (
          let released = Atomic.make false in
          Ok
            { release =
                (fun () ->
                   if Atomic.compare_and_set released false true
                   then release_global_capacity ())
            ; wait_ms = waited_ms ~started_at
            })
        else (
          Eio.Fiber.yield ();
          loop ())
      else if Time_compat.now () -. started_at >= timeout_s
      then Error { limit; inflight = current; waited_ms = waited_ms ~started_at }
      else (
        Eio.Fiber.yield ();
        loop ()))
  in
  loop ()
;;

let with_turn_capacity ?timeout_s ~keeper_name:_ ~channel:_ f =
  let timeout_s =
    match timeout_s with
    | Some value -> value
    | None -> Keeper_runtime_resolved.admission_wait_timeout_sec ()
  in
  match acquire_global_capacity ~timeout_s with
  | Error rejection -> Error rejection
  | Ok acquired ->
    Fun.protect
      ~finally:acquired.release
      (fun () -> Ok (f ~capacity_wait_ms:acquired.wait_ms))
;;

let inflight_for_test () = Atomic.get inflight
