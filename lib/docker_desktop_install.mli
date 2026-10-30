(** Explicit Docker Desktop acquisition/install actions for macOS. Catalog reads
    never call these effects. No action accepts Docker's license or proves a guest. *)
type verified_artifact
type error = Unsupported_host | Invalid_checksum | Download_failed | Invalid_file
  | Digest_mismatch | Signature_rejected | Mount_failed | Installer_failed
  | Invalid_completion | Cleanup_required of string
val error_message : error -> string
type runner = string list -> (string, unit) result
val acquire : host:Sandbox_readiness.host -> run:runner -> (verified_artifact, error) result
val to_json : verified_artifact -> Yojson.Safe.t
val remove : verified_artifact -> unit

type cleanup = Cleaned | Pending of string
type completion = { cleanup : cleanup }
val completion_to_json : completion -> Yojson.Safe.t
val install_privileged : run:runner -> source:string -> sha256:string -> size:int -> (completion, error) result
(** Root-only: stage an inaccessible-to-user copy, verify and mount it read-only,
    verify Docker's app identity/notarization, invoke its installer without any
    license flag, detach and clean. A cleanup warning does not undo installation. *)
type action_result = { completion : completion; service : Sandbox_readiness.entry }
val install : executable_path:string -> run:runner -> host:Sandbox_readiness.host ->
  probe_run:Sandbox_readiness.runner -> require_rootless:bool -> require_userns:bool ->
  verified_artifact -> (action_result, error) result
(** Elevates the canonical packaged executable and then rechecks service access
    under the invoking user's environment. Caller wires the internal command
    [sandbox-install-docker-verified] to [install_privileged]. *)
val launch_and_recheck : run:runner -> host:Sandbox_readiness.host ->
  probe_run:Sandbox_readiness.runner -> require_rootless:bool -> require_userns:bool ->
  unit -> (Sandbox_readiness.entry, error) result
(** User-selected launch only: Docker presents its own license/startup flow.
    An immediate failed probe means refresh is needed, never implied readiness. *)
module For_testing : sig
  val install_staged : temp_dir:string -> run:runner -> source:string -> sha256:string -> size:int -> (completion, error) result
end
