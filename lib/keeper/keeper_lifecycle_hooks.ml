(** Implementation of Keeper_lifecycle_hooks. See .mli for contract. *)

type event =
  | Phase_transition of {
      from_phase : Keeper_state_machine.phase;
      to_phase   : Keeper_state_machine.phase;
    }
  | Tombstone_reaped

type hook = keeper_id:string -> event -> unit

(* Atomic-backed list, append-on-register. Read on the hot path is
   Atomic.get → list iteration. No mutex, no contention. *)
let hooks : hook list Atomic.t = Atomic.make []

let register (h : hook) : unit =
  let rec loop () =
    let cur = Atomic.get hooks in
    let next = cur @ [ h ] in
    if Atomic.compare_and_set hooks cur next then ()
    else loop ()
  in
  loop ()

let run ~keeper_id (ev : event) : unit =
  let hs = Atomic.get hooks in
  List.iter
    (fun h ->
      try h ~keeper_id ev
      with exn ->
        Log.Server.warn
          "[KeeperLifecycleHooks] hook raised on keeper_id=%s: %s"
          keeper_id (Printexc.to_string exn))
    hs

let registered_count () : int = List.length (Atomic.get hooks)

let reset_for_testing () : unit = Atomic.set hooks []
