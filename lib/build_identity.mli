(** Build identity for the running server process.

    Captures release version, git commit, start time, and uptime.
    Commit is resolved at startup from [MASC_BUILD_GIT_COMMIT] env var
    or by probing the git repository. *)

type t = {
  release_version : string;
  commit : string option;
  started_at : string;
  uptime_seconds : int;
}

val to_yojson : t -> Yojson.Safe.t
(** PPX-generated serializer. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** PPX-generated deserializer. *)

val current : unit -> t
(** Snapshot of the running build identity with current uptime. *)

val resolve_commit :
  env_value:string option -> probe:(unit -> string option) -> string option
(** Resolve commit hash from env var or probe function.
    Exposed for testing. *)

val pick_repo_candidates :
  exe_dir:string -> cwd:string -> string list
(** Ordered list of directories to probe for a git repo. Places [exe_dir]
    before [cwd] so the binary's own source tree wins when the process is
    launched from an unrelated cwd. Returns a single entry when both
    arguments are equal. Pure — exposed for unit testing. *)
