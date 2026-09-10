(** Acquisition and installation of Apple's signed Container package.
    Both operations are effects: callers must obtain explicit user selection.
    Inspection of an action catalog must never invoke them. *)
type release
type verified_artifact
type error = Unsupported_host | Invalid_release | Download_failed | Invalid_file
  | Digest_mismatch | Signature_rejected | Publisher_mismatch | Installer_failed
type runner = string list -> (string, unit) result
val release_of_json : Yojson.Safe.t -> (release, error) result
val expected_publisher : string
val verify : run:runner -> release:release -> path:string -> (verified_artifact, error) result
val acquire : host:Sandbox_readiness.host -> run:runner -> (verified_artifact, error) result
val install : run:runner -> verified_artifact -> (unit, error) result
(** Rechecks digest, platform signature and publisher immediately before invoking
    the system installer through sudo. Success still requires service/guest checks. *)
val remove : verified_artifact -> unit
val to_json : verified_artifact -> Yojson.Safe.t
val error_message : error -> string
