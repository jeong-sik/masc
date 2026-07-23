(** Board-owned side-effect hooks.

    Board mutations emit neutral effects here instead of depending directly on
    selection models. The composition layer installs concrete handlers. *)

type vote_direction =
  | Up
  | Down

type observer = {
  record_vote : agent_name:string -> direction:vote_direction -> unit;
}

let noop_observer = {
  record_vote = (fun ~agent_name:_ ~direction:_ -> ());
}

let observer = Atomic.make noop_observer

let set_observer hooks = Atomic.set observer hooks

let record_vote ~agent_name ~direction =
  (Atomic.get observer).record_vote ~agent_name ~direction
