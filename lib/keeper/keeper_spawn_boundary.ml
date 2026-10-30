type t =
  | Starts_in_container
  | Refuses_start of { detail : string }

let of_sandbox_profile (profile : Keeper_types_profile_sandbox.sandbox_profile) =
  match profile with
  | Keeper_types_profile_sandbox.Docker -> Starts_in_container
  | Keeper_types_profile_sandbox.Micro_vm ->
    (* A microvm guest owns its tree and is reached through the shim over
       [container exec] (RFC-0400). *)
    Refuses_start
      { detail =
          "spawn does not cross the microvm boundary: the guest's tree lives on \
           its work volume and the exec shim speaks a framed protocol over one \
           connection, so there is no argv to background. Run the command with \
           Execute."
      }
  | Keeper_types_profile_sandbox.Remote_ssh ->
    Refuses_start
      { detail =
          "spawn does not cross the remote_ssh boundary: the exec shim speaks a \
           framed protocol over one connection, so there is no argv to background. \
           Run the command with Execute."
      }
;;
