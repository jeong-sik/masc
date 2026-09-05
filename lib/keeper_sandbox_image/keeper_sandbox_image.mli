(** The general Keeper sandbox image, as a recipe the binary carries.

    A Keeper on [sandbox_profile = "docker"] runs each turn in a container, and
    until now the only image MASC described was its own development
    environment: OCaml and this repository's opam dependencies, buildable only
    from a checkout. A host that installed a release had no image it could make
    and no image that fit work other than MASC's own.

    This is the other one — bash, ripgrep and git on a Debian base, which is
    what a turn needs to read, search and edit a repository. It is deliberately
    not polyglot: a project's toolchain belongs in that project's image, named
    per Keeper with [sandbox_image], because the container is read-only and a
    turn cannot install what it finds missing. *)

val default_tag : string
(** ["masc-sandbox:general"] — the tag {!build_argv} uses when the caller names
    none. Not yet the runtime default; a Keeper reaches it through
    [sandbox_image] or [MASC_KEEPER_SANDBOX_DOCKER_IMAGE]. *)

val dockerfile : string
(** The recipe, carrying no [COPY]: it builds from stdin with no context, which
    is what lets an installed binary build it with no checkout anywhere. *)

val build_argv : tag:string -> string list
(** Arguments after the docker command for [docker build -t <tag> -]. The
    trailing ["-"] is the context: the caller feeds {!dockerfile} to stdin. *)
