(** Typed keeper path rejection contract and user-facing prefixes. *)

type keeper_path_rejection =
  | Path_required
  | Allowed_paths_normalized_empty of { count : int }
  | Outside_sandbox of { raw : string }

let rejection_to_user_message = function
  | Path_required -> "path_required"
  | Allowed_paths_normalized_empty { count } ->
    Printf.sprintf
      "allowed_paths_normalized_empty: %d entries provided, none resolved to a \
       valid path"
      count
  | Outside_sandbox { raw } ->
    Printf.sprintf "path_outside_sandbox: %s" raw
;;
