(** Docker credential mount/env resolution.

    Translates [git_creds_enabled] into the Docker [-v] mount fragments
    and [-e] env fragments needed to forward the keeper's resolved
    identity into a container.  Pure logic: no I/O, no container state. *)

open Keeper_types

let resolve ~config ~meta ~git_creds_enabled =
  if not git_creds_enabled
  then Ok ([], [])
  else (
    (* Credential composition is centralised in
       [Keeper_host_config_provider.resolve].  It selects either the
       keeper's explicit GitHub identity bundle or the MASC-owned
       root bundle.  Ambient operator GH_TOKEN/GITHUB_TOKEN,
       ~/.config/gh, ~/.ssh, and keychain probes are not part of
       keeper execution. *)
    match Keeper_host_config_provider.resolve ~config ~identity:meta.name with
    | Error err -> Error (Keeper_credential_provider.pp_error err)
    | Ok binding ->
      let mounts =
        List.concat_map
          (fun (m : Keeper_credential_provider.ro_mount) ->
             [ "-v"; m.host ^ ":" ^ m.container ^ ":ro" ])
          binding.ro_mounts
      in
      let envs =
        List.concat_map
          (fun (k, v) -> [ "-e"; k ^ "=" ^ v ])
          binding.env
      in
      Ok (mounts, envs))
;;
