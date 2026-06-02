(** Identity helpers shared by workspace-facing tool surfaces. *)

type join_validation_error =
  { outcome : string
  ; detail : string
  }

let keeper_name_for_agent_name = Keeper_identity.keeper_name_from_agent_name
let canonicalize_if_keeper = Keeper_runtime.canonicalize_if_keeper

let validate_join_identity ~base_path ~agent_name =
  match
    Keeper_identity.normalize_all_names
      ~input_agent_name:agent_name
      ~base_path
      ~check_persona:true
      ()
  with
  | Ok bundle -> Ok bundle.keeper_name
  | Error err ->
    Error
      { outcome = Keeper_identity.validation_error_outcome_label err
      ; detail = Keeper_identity.show_validation_error err
      }
;;
