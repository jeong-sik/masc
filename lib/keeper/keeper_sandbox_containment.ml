(** Keeper_sandbox_containment — see .mli for contract. *)

let check_target ~config ~allowed_paths ~target =
  match
    Keeper_alerting_path.resolve_keeper_target_path
      ~config
      ~allowed_paths
      ~raw_path:target
  with
  | Ok _ -> Ok ()
  | Error rejection ->
    Error (Keeper_alerting_path.rejection_to_user_message rejection)

let check_read_target ~config ~meta ~target =
  check_target
    ~config
    ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
    ~target

let check_write_target ~config ~meta ~target =
  check_target
    ~config
    ~allowed_paths:(Keeper_alerting_path.effective_write_allowed_paths ~meta)
    ~target
