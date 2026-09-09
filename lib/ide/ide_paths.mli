(** IDE store path SSOT.

    Centralises the [.masc-ide/] subdirectory name and store path
    construction used by the IDE bridge and HTTP query modules.

    RFC-0378 §5.2: the store holds addressed code facts only, laid out
    as [by-url/<codebase-slug>/]. A store directory is named by the
    slug directly — the same wire key the scope, the co-view context,
    and the address mint carry — so keeper writes from a sandbox clone
    and IDE reads against the user's working tree join on the same
    codebase identity. *)

val store_path : base_dir:string -> string
(** [store_path ~base_dir] returns [base_dir/.masc-ide]. *)

val code_store_dir : base_dir:string -> codebase:string -> string
(** [code_store_dir ~base_dir ~codebase] returns
    [base_dir/.masc-ide/by-url/<codebase>]. The caller passes a
    canonical slug — {!canonical_url_of_remote} output, or a scope value
    validated by the same acceptance. *)

val canonical_url_of_remote : string -> string option
(** [canonical_url_of_remote remote] normalises a git remote string
    into a host_path slug, e.g.
    [https://github.com/jeong-sik/masc(.git)?] and
    [git@github.com:jeong-sik/masc(.git)?] both produce
    [Some "github.com_jeong-sik_masc"].

    Returns [None] when:
    - the input is empty
    - it lacks a host
    - it lacks a path
    - any segment contains a character outside [a-z0-9._-]
    - any segment begins with [..] (path traversal guard)

    The function is total (never raises) and deterministic. The same
    upstream resolves to the same slug regardless of which transport
    the remote was registered with. *)
