(* Store callbacks may run outside Eio and must not wait for SSE fanout.
   Keep one pending and one active publication per typed key. A publisher
   waiting cooperatively does not prevent another key from starting. *)
module Make (Key : Map.OrderedType) = struct
  module Keys = Set.Make (Key)

  let start ~sw ~mono_clock ~publish =
    let pending = ref Keys.empty in
    let active = ref Keys.empty in
    let wake = Eio.Stream.create 1 in
    let mu = Stdlib.Mutex.create () in
    let signal_locked () =
      if Eio.Stream.is_empty wake then Eio.Stream.add wake () in
    let enqueue key =
      Stdlib.Mutex.protect mu (fun () ->
        pending := Keys.add key !pending;
        signal_locked ())
    in
    let finish key =
      Stdlib.Mutex.protect mu (fun () ->
        active := Keys.remove key !active;
        if not (Keys.is_empty (Keys.diff !pending !active))
        then signal_locked ())
    in
    (* Bound retries after a transport failure; an idle source has no timer. *)
    let retry_initial_s = Server_observation_retry.initial_delay_s in
    let publish_one key =
      let rec attempt delay =
        match publish key with
        | () -> ()
        | exception exn ->
          (match exn with
           | Eio.Cancel.Cancelled _ -> Eio.Fiber.check ()
           | _ -> ());
          (* A transport exception can contain source data; the event itself
             carries no rows, and logs must not expose confirmation tokens. *)
          Log.Server.warn "workspace invalidation publish failed; retrying";
          Eio.Time.Mono.sleep mono_clock delay;
          attempt (Server_observation_retry.next_delay_s delay)
      in
      Fun.protect ~finally:(fun () -> finish key)
        (fun () -> attempt retry_initial_s)
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        Eio.Stream.take wake;
        let keys = Stdlib.Mutex.protect mu (fun () ->
          let keys = Keys.diff !pending !active in
          pending := Keys.diff !pending keys;
          active := Keys.union !active keys;
          keys) in
        Keys.iter (fun key ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
            publish_one key;
            `Stop_daemon)) keys;
        loop () in
      loop ());
    enqueue
  ;;

end

module Workspaces = Make (String)

let start ~sw ~mono_clock ~publish =
  let enqueue = Workspaces.start ~sw ~mono_clock
      ~publish:(fun base_path -> publish ~base_path) in
  fun ~base_path -> enqueue base_path
;;
