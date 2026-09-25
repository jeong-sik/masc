(** Whether a Keeper may boot on the image its [sandbox_image] names.

    A Keeper whose profile starts a container of its own ([docker], and
    [microvm], whose guest the Keeper boots itself) names an image in this
    host's catalog. When that name is not in the catalog, when nothing is
    promoted for it in the store the Keeper's container starts from, or when
    the catalog cannot be read, every turn would be refused the same way. The
    Keeper is refused before it boots instead, next to the refusal of a
    missing [sandbox_image] (#37523). [remote_ssh] runs on a host the
    operator provisioned and starts no container, so it is not asked.

    Keeper up asks the same question before it has a meta, from the profile
    it is about to write ([Keeper_turn_up_args.parse]).

    RFC keeper-sandbox-images-have-versions (#38699) §2.4. *)

val boot_refusal :
  base_path:string ->
  Keeper_meta_contract.keeper_meta ->
  Keeper_sandbox_image_resolver.error option
(** [Some error] when [meta]'s image does not resolve for the store its
    container starts from; [None] when it does, or when the profile starts no
    container.

    [meta] must be effective
    ({!Keeper_meta_contract.effective_meta_of_profile_defaults}). Durable meta
    carries no [microvm_backend], so a [microvm] Keeper read from disk has no
    store to look in and is refused. *)
