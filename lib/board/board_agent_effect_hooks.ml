(** Agent-selection adapter for neutral Board side-effect hooks. *)

let thompson_direction = function
  | Board_effect_hooks.Up -> `Up
  | Board_effect_hooks.Down -> `Down

let install () =
  Board_effect_hooks.set_observer
    {
      record_vote =
        (fun ~agent_name ~direction ->
           Thompson_sampling.record_vote
             ~agent_name
             ~direction:(thompson_direction direction));
    }
