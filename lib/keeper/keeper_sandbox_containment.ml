(** Keeper_sandbox_containment — see .mli for contract. *)

let normalize p =
  Keeper_alerting_path.normalize_path_for_check_stripped p

let starts_with ~prefix s = String.starts_with ~prefix s

(** Build the absolute, normalized playground bundle root for [meta]
    under [config.base_path]. *)
let playground_root_abs ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) =
  Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize

let target_is_inside_playground ~playground ~target =
  let playground = playground in
  target = playground || starts_with ~prefix:(playground ^ "/") target

let is_hardened_profile = function
  | Keeper_types.Docker -> true
  | Keeper_types.Local -> false

let check_target ~operation ~config ~meta ~target =
  if not (is_hardened_profile meta.Keeper_types.sandbox_profile) then
    Ok ()
  else
    let playground = playground_root_abs ~config ~meta in
    let target_norm = normalize target in
    if target_is_inside_playground ~playground ~target:target_norm then Ok ()
    else
      Error
        (Printf.sprintf
           "symmetric_sandbox_blocked: target %s is outside keeper playground \
            %s. Keepers with sandbox_profile=docker may only %s inside \
            their playground. Clone the source into your playground via \
            keeper_shell op=git_clone, or operate inside %s/repos/."
           target_norm playground operation playground)

let check_read_target ~config ~meta ~target =
  check_target ~operation:"read" ~config ~meta ~target

let check_write_target ~config ~meta ~target =
  check_target ~operation:"write" ~config ~meta ~target
