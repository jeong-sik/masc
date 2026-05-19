(** Per-keeper event-queue access.

    Extracted from keeper_registry.ml (lines 1854-1900) as part of the
    godfile decomp campaign. Each [registry_entry] carries its own
    [event_queue : Keeper_event_queue.t Atomic.t] — these wrappers do
    CAS on that per-entry atomic after locating the entry via the
    central registry's public [get]. No coupling to the central
    Atomic state primitive. *)

let enqueue ~base_path name stimulus =
  match Keeper_registry.get ~base_path name with
  | None ->
    Log.Keeper.warn
      "registry: enqueue_event name=%s base_path=%s: keeper not registered"
      name
      base_path
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let next = Keeper_event_queue.enqueue cur stimulus in
      if not (Atomic.compare_and_set entry.event_queue cur next) then loop ()
    in
    loop ()
;;

let snapshot ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Keeper_event_queue.empty
  | Some entry -> Atomic.get entry.event_queue
;;

let dequeue ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> None
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      match Keeper_event_queue.dequeue cur with
      | None -> None
      | Some (stim, rest) ->
        if Atomic.compare_and_set entry.event_queue cur rest then Some stim else loop ()
    in
    loop ()
;;

let drain_board ?window_sec ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> []
  | Some entry ->
    let rec loop () =
      let cur = Atomic.get entry.event_queue in
      let board, rest = Keeper_event_queue.drain_board_window ?window_sec cur in
      if Atomic.compare_and_set entry.event_queue cur rest then board else loop ()
    in
    loop ()
;;
