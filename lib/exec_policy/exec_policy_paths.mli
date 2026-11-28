(** Filesystem path normalization and allowlist checks for exec policy. *)

val resolve_path : ?base_dir:string -> string -> string

val is_within_dir : dir:string -> string -> bool
(** Whether a resolved path is [dir] itself or a descendant of it. Both
    arguments must already have come through {!resolve_path}: this compares
    text, so an unresolved [..] or a symlink would walk out of [dir] without
    the comparison noticing. *)
type extra_root_match = { root : string; path : string }
(** A path admitted by a declared endpoint root: [root] is that root and
    [path] the admitted path, both in lexical normal form. *)

val extra_root_match :
  ?workdir:string -> extra_roots:string list -> string -> extra_root_match option
(** {!extra_root_path} that also names the narrowest root in [extra_roots]
    the path lies within. A reader that opens the path on the endpoint checks
    what it opened against that root. *)

val extra_root_path :
  ?workdir:string -> extra_roots:string list -> string -> string option
(** [Some p] when [path] lies within one of [extra_roots] (endpoint-side
    roots such as an ssh endpoint's declared [allowed_paths]), [p] being the
    path's lexical normal form;
    [None] otherwise, and always [None] for [[]]. Both sides are normalized
    lexically, never through the host filesystem, because the roots name
    another machine's paths. This is the one judgement of "under a declared
    endpoint root": Execute's {!validate_path} and the remote keeper's file
    reads both ask it. *)

val validate_path :
  ?workdir:string -> extra_roots:string list -> string -> bool
(** Resolve symlinks and validate only objective cwd/host-sandbox containment.
    No caller identity or product metadata is accepted at this boundary.
    [extra_roots] are further allowed roots on the machine the command runs
    on (for an ssh target, the Keeper's root on the endpoint and the
    endpoint's declared [allowed_paths]; for a microVM target, the Keeper's
    root in the guest); they and the path are
    compared lexically, without host symlink resolution. So a symlink under
    an extra root that points elsewhere is not followed: on an endpoint that
    is this same machine, an extra root is weaker than the workdir, which is
    resolved. Pass [[]] for the default boundary. *)
