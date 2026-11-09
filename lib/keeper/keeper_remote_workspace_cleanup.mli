(** Sweeps a Remote_ssh Keeper's workspace root on its endpoint
    (RFC-remote-keeper-workspace-entries-are-swept-on-their-endpoint).

    The rules live in the embedded payload
    [config/scripts/keeper-remote-workspace-cleanup.py]: an entry goes only
    when nobody touched it within the retention, no live process uses it,
    and removing it loses no commit or stash. *)

type report = {
  removed : int;
  skipped : int;
  failed : int;
  freed_kib : int;
      (** The endpoint's free space after the sweep minus before it. Other
          writers on a shared volume move it too, so it can be negative. *)
  available_kib : int;  (** Free space after the sweep. *)
}

val report_of_string : string -> (report, string) result
(** Decode the payload's [--apply] report. A payload that refused to sweep
    (it could not read [/proc]) returns its reason as an error, not as an
    empty success. An entry result outside [removed | skipped | failed] is
    an invalid report. *)

val payload_argv : root:string -> retention_sec:float -> string list
(** [python3 - --root <root> --retention-sec <n> --apply]. The server always
    applies; a report-only run is the same payload started by hand. *)

val cleanup :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  retention_sec:float ->
  timeout_sec:float ->
  unit ->
  (report, string) result
(** An error names the declared profile when [meta] is not Remote_ssh: the
    caller picked this step from an earlier read that said Remote_ssh, so a
    different profile now is a disagreement to show, not a Keeper to pass
    over.
    It runs beside the Keeper's turns, not in its Maintenance slot: the
    payload leaves alone an entry a live process is inside or that was
    touched within the retention.
    The endpoint is built without the disk preflight: that preflight refuses
    a full disk, which is when this sweep matters most.
    [timeout_sec] is the endpoint's run limit for the payload. When it
    passes, the endpoint stops the payload and this returns an error; the
    entries removed before then stay removed. *)
