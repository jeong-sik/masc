(** Agent/economy adapter for neutral Board side-effect hooks. *)

let economy_kind = function
  | Board_effect_hooks.Board_post -> Economy.Earn_board_post
  | Board_effect_hooks.Upvote -> Economy.Earn_upvote

let thompson_direction = function
  | Board_effect_hooks.Up -> `Up
  | Board_effect_hooks.Down -> `Down

let install () =
  Board_effect_hooks.set_observer
    {
      earn =
        (fun ~base_path ~agent_name ~kind ~reason () ->
           match
             Economy.earn
               ~base_path
               ~agent_name
               ~kind:(economy_kind kind)
               ~reason
               ()
           with
           | Ok _ -> Ok ()
           | Error _ as error -> error);
      record_vote =
        (fun ~agent_name ~direction ->
           Thompson_sampling.record_vote
             ~agent_name
             ~direction:(thompson_direction direction));
    }
