(** Build identity for the running server process.

    Captures release version, git commit, start time, and uptime.
    Commit is resolved at startup from [MASC_BUILD_GIT_COMMIT] env var
    or by probing the git repository. *)

type t = {
  release_version : string;
  commit : string option;
  commit_unix_ts : float option;
    (** Unix timestamp of the resolved git commit (probed at startup
        via [git log -1 --format=%ct <commit>]).  [None] when commit
        could not be resolved or git probe failed.  Exposed on
        [/health] so operators / dashboards can compute
        [now - commit_unix_ts] and surface stale-binary deploy gaps
        without an external git fetch from the dashboard side. *)
  commit_age_seconds : int option;
    (** Convenience field: [Some (now - commit_unix_ts)] when both
        are available, [None] otherwise.  Recomputed on every
        [current ()] call so the value tracks wall clock as the
        process keeps running on a stale binary. *)
  executable_path : string;
    (** Absolute best-effort path to the running executable.  Exposed on
        [/health] so operators can distinguish a root-lane binary from a
        worktree binary. *)
  executable_dir : string;
    (** Directory containing [executable_path]. *)
  repo_root : string option;
    (** Git root resolved from the executable path first, then cwd. *)
  started_at : string;
  uptime_seconds : int;
}

val to_yojson : t -> Yojson.Safe.t
(** PPX-generated serializer. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** PPX-generated deserializer. *)

val current : unit -> t
(** Snapshot of the running build identity with current uptime. *)

val repo_root : unit -> string option
(** Git root used for the running server binary, preferring the executable
    directory over the process cwd.  This is separate from the MASC base path,
    which may intentionally point at a different workspace such as [~/me]. *)

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

val parse_commit_unix_ts_output : string -> float option
(** Parse raw [git log -1 --format=%ct] output. Pure — exposed for unit
    testing. *)

module For_testing : sig
  val observe_probe_failure : site:string -> exn -> unit
  val probe_commit_unix_ts : string option -> float option
end
