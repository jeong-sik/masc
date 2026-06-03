(** Board-owned side-effect hooks.

    Board mutations emit neutral effects here instead of depending directly on
    agent economy or selection models. The composition layer installs concrete
    handlers. *)

type earn_kind =
  | Board_post
  | Upvote

type vote_direction =
  | Up
  | Down

type observer = {
  earn :
    base_path:string ->
    agent_name:string ->
    kind:earn_kind ->
    reason:string ->
    unit ->
    (unit, string) result;
  record_vote : agent_name:string -> direction:vote_direction -> unit;
}

let noop_observer = {
  earn =
    (fun ~base_path:_ ~agent_name:_ ~kind:_ ~reason:_ () -> Ok ());
  record_vote = (fun ~agent_name:_ ~direction:_ -> ());
}

let observer = Atomic.make noop_observer

let set_observer hooks = Atomic.set observer hooks
let reset_for_test () = Atomic.set observer noop_observer

let earn ~base_path ~agent_name ~kind ~reason () =
  (Atomic.get observer).earn ~base_path ~agent_name ~kind ~reason ()

let record_vote ~agent_name ~direction =
  (Atomic.get observer).record_vote ~agent_name ~direction
