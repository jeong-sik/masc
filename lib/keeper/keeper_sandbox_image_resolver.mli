(** The build a Keeper's container starts from.

    A Keeper's [sandbox_image] is a name in this host's image catalog
    ({!Keeper_sandbox_image_catalog}). {!resolve} reads the catalog file on
    every call and keeps nothing, so a [masc sandbox-image promote] reaches
    the next caller that asks. A caller that starts and later stops a
    container resolves once for that decision and keeps the answer, so the
    two never look at different builds. A catalog that cannot be read is a
    refusal: there is no image to fall back to that anyone chose.

    RFC keeper-sandbox-images-have-versions (#38699) §2.4. *)

type error =
  | Not_declared  (** The Keeper's [sandbox_image] is absent or blank. *)
  | Catalog_unreadable of Keeper_sandbox_image_catalog.load_error
  | Unknown_image of { name : string; known : string list }
      (** The catalog has no such name. [known] lists the names it has. *)
  | Not_built_on_host of { name : string; store : Keeper_sandbox_image_catalog.store }
      (** The name is in the catalog, and nothing is promoted for it in the
          store this Keeper's containers start from. *)
  | No_image_store of { keeper : string; sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile }
      (** The profile starts no container ([remote_ssh]), or it is [microvm]
          with no [microvm_backend], so there is no store to look in. *)

val error_to_string : error -> string
(** What is wrong and, where the operator can fix it, the commands to run. *)

val resolve :
  config_root:string ->
  store:Keeper_sandbox_image_catalog.store ->
  string option ->
  (Keeper_sandbox_image_catalog.pinned, error) result
(** [resolve ~config_root ~store declared] reads
    [<config_root>/sandbox-images.toml] and returns the build promoted for
    [declared] on [store]. *)

val resolve_in_workspace :
  base_path:string ->
  store:Keeper_sandbox_image_catalog.store ->
  string option ->
  (Keeper_sandbox_image_catalog.pinned, error) result
(** {!resolve} in the config root the server resolves for [base_path], so
    [MASC_CONFIG_DIR] counts. *)

val for_keeper :
  base_path:string ->
  Keeper_meta_contract.keeper_meta ->
  (Keeper_sandbox_image_catalog.pinned, error) result
(** {!resolve_in_workspace} for a Keeper's own [sandbox_image]: the store is
    Docker's for [sandbox_profile = "docker"] and the Keeper's
    [microvm_backend] for [microvm]. *)
