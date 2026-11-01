(** One explicitly named BasePath, captured before Board operations start.
    This is path and physical-root evidence, not a process ownership lease. *)

type t
type observation

type rejection =
  | Base_path_missing of string
  | Base_path_not_directory of string
  | Root_binding_changed of string
  | Workspace_directory_changed of string
  | Workspace_boundary_refused of Fs_compat.owned_directory_chain_rejection
  | Raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

val capture : base_path:string -> t
(** Anchor a relative spelling synchronously, then capture the existing root
    and its lexical [.masc] boundary without creating files or directories.
    A BasePath alias is allowed; an alias inside its owned chain is refused.
    The immutable attempt retains any physical capture refusal. Creating the
    missing root later requires a new capture.

    @raise Invalid_argument if [base_path] is exactly empty.
    Relative anchoring propagates an unavailable cwd's original exception;
    there is then no absolute path projection or filesystem effect. *)

val workspace_masc_dir : t -> string
(** Derive the captured state path. On a failed capture this is only the
    requested absolute path projection; it grants no filesystem authority. *)

val observe : t -> (observation, rejection) result
(** Recheck the captured physical root and the no-follow state-directory chain.
    A successful observation retains the current state-directory identity when
    present. Retain that returned observation for later revalidation; observing
    a newly created directory does not mutate the original capture attempt.
    An original capture failure cannot become a successful observation. *)

val revalidate : t -> observation -> (unit, rejection) result
(** Recheck the root and state-directory identities represented by this actual
    observation. No Board mutex or lifetime lease is acquired. *)

val same_root : observation -> observation -> bool
(** Compare canonical BasePath and physical root identities. This does not
    compare payloads or establish atomicity across filesystem operations. *)
val workspace_directory_missing : observation -> bool
(** The actual directory observation was Missing. This is not permission to
    create a directory or an initialized-source verdict. *)

val rejection_to_string : rejection -> string
val raised : rejection -> (exn * Printexc.raw_backtrace) option
(** Retain the original exception and backtrace for the caller's settlement
    policy. Ordinary rejections return [None]. *)
