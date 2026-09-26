(** The build a Keeper's container starts from.

    A Keeper's [sandbox_image] is a name in this host's image catalog
    ({!Keeper_sandbox_image_catalog}). {!resolve} reads shipped names and the
    host's promoted builds on every call and keeps nothing, so a
    [masc sandbox-image promote] reaches
    the next caller that asks. A caller that starts and later stops a
    container resolves once for that decision and keeps the answer, so the
    two never look at different builds. A catalog that cannot be read is a
    refusal: there is no image to fall back to that anyone chose.

    RFC keeper-sandbox-images-have-versions (#38699) §2.4. *)

type error =
  | Not_declared  (** The Keeper's [sandbox_image] is absent or blank. *)
  | Catalog_unreadable of Keeper_sandbox_image_catalog.load_error
  | Unresolved of Keeper_sandbox_image_catalog.missing
      (** The catalog found no promoted build. Carries its exact typed reason. *)

val error_to_string : error -> string
(** What is wrong and, where the operator can fix it, the commands to run. *)

val resolve :
  config_root:string ->
  store:Keeper_sandbox_image_catalog.store ->
  string option ->
  (Keeper_sandbox_image_catalog.pinned, error) result
(** [resolve ~config_root ~store declared] reads shipped names and
    [<config_root>/sandbox-images.toml] builds, then returns the build promoted
    for [declared] on [store]. An absent host file means no build is promoted. *)
