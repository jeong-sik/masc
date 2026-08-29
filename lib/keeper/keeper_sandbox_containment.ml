(** Keeper_sandbox_containment — see .mli for contract. *)

let check_target ~config ~sandbox_roots ~target =
  match
    Keeper_alerting_path.resolve_keeper_target_path
      ~config
      ~sandbox_roots
      ~raw_path:target
  with
  | Ok _ -> Ok ()
  | Error rejection ->
    Error (Keeper_alerting_path.rejection_to_user_message rejection)

let check_read_target ~config ~meta ~target =
  check_target
    ~config
    ~sandbox_roots:(Keeper_alerting_path.sandbox_roots ~meta)
    ~target

