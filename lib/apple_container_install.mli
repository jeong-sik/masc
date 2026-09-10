(** Acquisition and installation of Apple's signed Container package.
    Both operations are effects: callers must obtain explicit user selection.
    Inspection of an action catalog must never invoke them. *)
type release
type verified_artifact
type error = Unsupported_host | Invalid_release | Download_failed | Invalid_file
  | Digest_mismatch | Signature_rejected | Publisher_mismatch | Installer_failed
type runner = string list -> (string, unit) result
type terminal_runner = string list -> (unit, unit) result
val release_of_json : Yojson.Safe.t -> (release, error) result
val expected_publisher : string
val verify : run:runner -> release:release -> path:string -> (verified_artifact, error) result
val acquire : host:Sandbox_readiness.host -> run:runner -> (verified_artifact, error) result
val install : executable_path:string -> run:runner -> elevate:terminal_runner -> verified_artifact -> (unit, error) result
(** [run] captures signature verification output; [elevate] preserves terminal
    input/output for the administrator password prompt.
    Elevates this same canonical packaged executable. The privileged command
    stages a root-owned copy and validates that copy before installation. *)

val install_privileged : run:runner -> source:string -> sha256:string -> size:int -> (unit, error) result
(** Root-only command implementation; never trust an unprivileged verification
    receipt. Copies, hashes, checks publisher/notarization, then installs only the
    root-owned copy. Always removes that private copy after completion. *)

val remove : verified_artifact -> unit
val to_json : verified_artifact -> Yojson.Safe.t
val error_message : error -> string

module For_testing : sig
  val install_staged : temp_dir:string -> run:runner -> source:string -> sha256:string -> size:int -> (unit, error) result
end
