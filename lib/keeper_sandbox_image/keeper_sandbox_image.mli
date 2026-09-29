(** The general Keeper sandbox image, as a recipe the binary carries.

    A Keeper on [sandbox_profile = "docker"] runs each turn in a container, and
    until now the only image MASC described was its own development
    environment: OCaml and this repository's opam dependencies, buildable only
    from a checkout. A host that installed a release had no image it could make
    and no image that fit work other than MASC's own.

    This is the other one — what a turn needs to read, search and edit a
    repository, and to hand the result back: bash, ripgrep and git on a
    Debian base, plus [gh] and [python3].

    Those last two are not a toolchain choice. MASC mounts a GitHub CLI
    config into the guest and points [GH_CONFIG_DIR] at it, and MASC's own
    repository-checkout probe runs [python3 -c] there. Shipping neither
    program left a Keeper holding credentials it could not use and reporting
    its own workspace as unreadable.

    Which language toolchain a Keeper needs is the operator's, named per
    Keeper with [sandbox_image] — the container is read-only, so a turn
    cannot install what it finds missing. *)

val dockerfile : string
(** The recipe, read at build time from [sandbox-images/base/Dockerfile]. It
    carries no [COPY]: it builds from stdin with no context, which
    is what lets an installed binary build it with no checkout anywhere. *)

val build_argv : ?labels:(string * string) list -> tag:string -> unit -> string list
(** Arguments after the docker command for [docker build -t <tag> -]. The
    trailing ["-"] is the context: the caller feeds {!dockerfile} to stdin.
    Each label becomes one [--label key=value]. *)

val context_directory_build_argv :
  ?labels:(string * string) list ->
  tag:string -> dockerfile:string -> context:string -> unit -> string list
(** Arguments after a runtime command that takes a directory rather than
    stdin: [build -t <tag> -f <dockerfile> <context>]. Apple's [container
    build] is one — its usage line takes a context directory and it offers no
    [-] — so the caller writes the recipe to a file and names it here.
    Which runtimes need this is {!Keeper_microvm_backend.recipe_delivery}'s
    answer, not this module's: it knows the recipe, not the fleet. *)
