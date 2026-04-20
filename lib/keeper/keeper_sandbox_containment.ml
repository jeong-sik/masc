(** Keeper_sandbox_containment — see .mli for contract. *)

let normalize p =
  Keeper_alerting_path.normalize_path_for_check p
  |> Keeper_alerting_path.strip_trailing_slashes

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(** Build the absolute, normalized playground bundle root for [meta]
    under [config.base_path]. *)
let playground_root_abs ~(config : Coord.config) ~(meta : Keeper_types.keeper_meta) =
  let project_root = Keeper_alerting_path.project_root_of_config config in
  let bundle_rel = Keeper_alerting_path.playground_path_of_keeper meta.name in
  Filename.concat project_root bundle_rel |> normalize

let target_is_inside_playground ~playground ~target =
  let playground = playground in
  target = playground || starts_with ~prefix:(playground ^ "/") target

let is_hardened_profile = function
  | Keeper_types.Docker_hardened
  | Keeper_types.Docker_with_git -> true
  | Keeper_types.Legacy_local -> false

let check_read_target ~config ~meta ~target =
  if not (is_hardened_profile meta.Keeper_types.sandbox_profile)
     || not (Env_config_keeper.KeeperSandbox.symmetric_read_containment ())
  then Ok ()
  else
    let playground = playground_root_abs ~config ~meta in
    let target_norm = normalize target in
    if target_is_inside_playground ~playground ~target:target_norm then Ok ()
    else
      Error
        (Printf.sprintf
           "symmetric_sandbox_blocked: target %s is outside keeper playground \
            %s. Hardened keepers (sandbox_profile=docker_hardened or \
            docker_with_git) with MASC_KEEPER_SYMMETRIC_SANDBOX=true may only \
            read inside their playground. Clone the source into your \
            playground via keeper_shell op=git_clone, or operate inside \
            %s/repos/."
           target_norm playground playground)
