(** Build identity for the running server process.

    Captures release version, git commit, start time, and uptime.
    [commit] is kept as a backwards-compatible field, but callers that
    need binary freshness must inspect [binary_commit] / [commit_source]
    rather than treating a runtime git probe as compile-time proof. *)

type t = {
  release_version : string;
  binary_version : string;
    (** Alias for [release_version], named explicitly for callers that
        compare the running executable against [repo_version]. *)
  repo_version : string option;
    (** Package version read from the runtime checkout's [dune-project],
        when available.  This is runtime repo truth, not binary truth. *)
  commit : string option;
    (** Backwards-compatible identity field.  Uses [binary_commit] when
        the build-time stamp is present, otherwise falls back to
        [repo_head_commit].  Inspect [commit_source] before using this as
        deploy proof. *)
  commit_source : string option;
    (** [Some "embedded"] when [commit] came from the build-time stamp,
        [Some "runtime_repo_head"] when it came from probing the current
        checkout, [None] when unknown. *)
  binary_commit : string option;
    (** Commit stamped into the binary at build time, when available.  This
        is the only commit field that operators should use as binary-build
        identity in this module. *)
  binary_commit_source : string option;
  binary_commit_unix_ts : float option;
  binary_commit_age_seconds : int option;
  repo_head_commit : string option;
    (** Current checkout HEAD probed at runtime from [repo_root], when
        available.  Useful operational context, but not proof that the
        executable was built from this commit. *)
  repo_head_commit_source : string option;
  repo_head_commit_unix_ts : float option;
  repo_head_commit_age_seconds : int option;
  executable_path : string;
    (** Absolute best-effort path to the running executable.  Exposed on
        [/health] so operators can distinguish a root-lane binary from a
        worktree binary. *)
  executable_dir : string;
    (** Directory containing [executable_path]. *)
  repo_root : string option;
    (** Git root resolved from the executable path first, then cwd. *)
  runtime_instance_id : string;
    (** Process-unique UUIDv7 minted once when this module initializes. Unlike
        [started_at], this remains collision-free across same-second restarts
        of the same binary and is the server-process identity for evidence. *)
  started_at : string;
  uptime_seconds : int;
}

val to_yojson : t -> Yojson.Safe.t
(** PPX-generated serializer. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** PPX-generated deserializer. *)

val current : unit -> t
(** Snapshot of the running build identity with current uptime. *)

type executable_provenance = {
  binary_commit : string;
  build_input_fingerprint : string;
  executable_sha256 : string;
}

val parse_executable_provenance :
  expected_binary_commit:string ->
  expected_executable_sha256:string ->
  string ->
  (executable_provenance, string) result
(** Decode the exact sidecar written beside a content-addressed local
    executable. The sidecar is accepted only when its commit and executable
    digest match the independently observed values. *)

val repo_root : unit -> string option
(** Git root used for the running server binary, preferring the executable
    directory over the process cwd.  This is separate from the MASC base path,
    which may intentionally point at a different workspace such as [~/me]. *)

val resolve_commit :
  embedded:string option ->
  probe:(unit -> string option) ->
  string option
(** Resolve commit hash: build-time embedded stamp first, then the probe
    function. Exposed for testing. *)

type commit_resolution = {
  commit : string option;
  commit_source : string option;
  binary_commit : string option;
  binary_commit_source : string option;
  repo_head_commit : string option;
  repo_head_commit_source : string option;
}

val resolve_commit_details :
  embedded:string option ->
  probe:(unit -> string option) ->
  commit_resolution
(** Resolve the compatibility [commit] plus the source-specific binary and
    runtime repo-head fields. [binary_commit] carries the build-time
    embedded stamp (source ["embedded"]); the repo-head probe never
    populates it because the source tree next to the process moves
    independently of the binary. Exposed for testing. *)

val pick_repo_candidates :
  exe_dir:string -> cwd:string -> string list
(** Ordered list of directories to probe for a git repo. Places [exe_dir]
    before [cwd] so the binary's own source tree wins when the process is
    launched from an unrelated cwd. Returns a single entry when both
    arguments are equal. Pure — exposed for unit testing. *)

val parse_commit_unix_ts_output : string -> float option
(** Parse raw [git log -1 --format=%ct] output. Pure — exposed for unit
    testing. *)

val parse_dune_project_version : string -> string option
(** Parse the top-level [(version ...)] field from [dune-project] contents. *)

module For_testing : sig
  val observe_probe_failure : site:string -> exn -> unit
  val probe_commit_unix_ts : string option -> float option
  val runtime_cwd : unit -> string
end
