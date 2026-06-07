type rejection =
  { limit : int
  ; inflight : int
  ; waited_ms : int
  }

type acquired =
  { release : unit -> unit
  ; wait_ms : int
  }

type acquisition_key =
  { keeper_name : string
  ; acquisition_id : int
  }

module Acquisition_key = struct
  type t = acquisition_key
  let compare = Stdlib.compare
end

module Acquisition_map = Map.Make (Acquisition_key)

let inflight = Atomic.make 0
let active_acquisitions : unit Acquisition_map.t ref = ref Acquisition_map.empty
let next_acquisition_id = ref 0
let capacity_mutex = Stdlib.Mutex.create ()

let with_capacity_lock f = Stdlib.Mutex.protect capacity_mutex f

let waited_ms ~started_at =
  let waited_s = Time_compat.now () -. started_at in
  int_of_float ((if waited_s < 0.0 then 0.0 else waited_s) *. 1000.0)
;;

let decrement_inflight () =
  let rec loop () =
    let current = Atomic.get inflight in
    if current <= 0
    then ()
    else if not (Atomic.compare_and_set inflight current (current - 1))
    then loop ()
  in
  loop ()
;;

let release_acquisition key =
  with_capacity_lock (fun () ->
    if Acquisition_map.mem key !active_acquisitions
    then (
      active_acquisitions := Acquisition_map.remove key !active_acquisitions;
      decrement_inflight ();
      true)
    else false)
;;

let force_release_for_keeper ~keeper_name =
  with_capacity_lock (fun () ->
    let matches, next =
      Acquisition_map.fold
        (fun key () (matches, acc) ->
           if String.equal key.keeper_name keeper_name
           then (key :: matches, acc)
           else (matches, Acquisition_map.add key () acc))
        !active_acquisitions
        ([], Acquisition_map.empty)
    in
    active_acquisitions := next;
    List.iter (fun _ -> decrement_inflight ()) matches;
    List.length matches)
;;

let acquire_global_capacity ~keeper_name ~timeout_s =
  let started_at = Time_compat.now () in
  let rec loop () =
    let limit = Keeper_config.keeper_turn_capacity_limit () in
    if limit <= 0
    then Ok { release = (fun () -> ()); wait_ms = waited_ms ~started_at }
    else
      let acquired =
        with_capacity_lock (fun () ->
          let current = Atomic.get inflight in
          if current < limit
          then (
            incr next_acquisition_id;
            let key = { keeper_name; acquisition_id = !next_acquisition_id } in
            active_acquisitions := Acquisition_map.add key () !active_acquisitions;
            Atomic.set inflight (current + 1);
            Some key)
          else None)
      in
      match acquired with
      | Some key ->
        let released = Atomic.make false in
        Ok
          { release =
              (fun () ->
                 if Atomic.compare_and_set released false true
                 then ignore (release_acquisition key : bool))
          ; wait_ms = waited_ms ~started_at
          }
      | None ->
        let current = Atomic.get inflight in
        if current < limit
        then
          (* Another fiber released between the locked probe and this snapshot. *)
          (Eio.Fiber.yield (); loop ())
        else if Time_compat.now () -. started_at >= timeout_s
        then Error { limit; inflight = current; waited_ms = waited_ms ~started_at }
        else (
          Eio.Fiber.yield ();
          loop ())
  in
  loop ()
;;

let with_turn_capacity ?timeout_s ~keeper_name ~channel:_ f =
  let timeout_s =
    match timeout_s with
    | Some value -> value
    | None -> Keeper_runtime_resolved.admission_wait_timeout_sec ()
  in
  match acquire_global_capacity ~keeper_name ~timeout_s with
  | Error rejection -> Error rejection
  | Ok acquired ->
    Fun.protect
      ~finally:acquired.release
      (fun () -> Ok (f ~capacity_wait_ms:acquired.wait_ms))
;;

let inflight_for_test () = Atomic.get inflight

let reset_for_test () =
  with_capacity_lock (fun () ->
    active_acquisitions := Acquisition_map.empty;
    next_acquisition_id := 0;
    Atomic.set inflight 0)
;;
