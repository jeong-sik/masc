(** The cwd an official client runs its native tools in for one Keeper.

    base_path is the operator's own checkout, so it is never the cwd (#39444).
    A Keeper whose sandbox mounts its host tree runs in that tree. Every other
    Keeper runs in
    [<base_path>/.masc/official-clients/<client folder>/<sha256 of the Keeper name>],
    a 0700 directory owned by the current user. *)

type client =
  | Codex_app_server  (** folder [codex-workspaces] *)
  | Acp  (** folder [acp-workspaces], shared by every ACP driver *)

val resolve
  :  base_path:string
  -> keeper_name:string
  -> sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile option
  -> client
  -> (string, string) result
(** Resolves and creates the directory without following symbolic links or
    changing a path another user owns. [Error] is the reason it cannot be
    used. *)
