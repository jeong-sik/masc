(** Isolated review runner used by the adversarial review tool. *)

let run_adversarial_review ~runtime_id ~prompt =
  Keeper_turn_driver.run_named
    ~runtime_id
    ~goal:prompt
    ~max_turns:1
    ~temperature:0.5
    ~max_tokens:500
    ~approval:Approval_callbacks.auto_approve
    ()
;;
