(** {!Keeper_volume_gc} on this host's Apple Container, for one workspace.

    The operator tool and the server's periodic report reach the volumes the
    same way: Apple Container answers first, the claims image resolves for
    the Apple store, every container command crosses the boundary each
    keeper CLI spawn crosses, and this workspace's keeper declarations say
    which keepers are registered. *)

(** ["base"]: the sandbox image catalog name the TUI's report and the
    server's periodic report run the claims-read helper on, so both judge
    the same way. [config/sandbox-images.toml] defines [base] as the general
    image; the helper only reads a marker file from the mounted work
    volume. *)
val claims_image : string

(** The limit for one container command when the caller gives none: the
    sandbox shell's I/O bucket. *)
val default_timeout_sec : unit -> float

(** [""] is no image: no marker is read, and every unowned keeper stays kept
    as unverified. Otherwise a sandbox image catalog name, resolved for the
    Apple store in [base_path]'s config root, or a [repository:tag]
    reference. Anything else is [Error]. *)
val resolve_claims_image : base_path:string -> string -> (string option, string) result

(** Apple Container answered the readiness check. Only
    {!apple_container_ready} makes one, so {!run} cannot start a volume
    command on a host without it. *)
type ready

(** Checks the host and asks Apple Container for its inventory. [Error]
    carries the readiness check's words for why this host has no answering
    Apple Container (a Linux host, an Intel Mac, a stopped service). *)
val apple_container_ready : unit -> (ready, string) result

(** {!Keeper_volume_gc.apple_keeper_volume_gc} with [base_path]'s keeper
    declarations as the registration answer. *)
val run :
  ready
  -> base_path:string
  -> claims_image:string option
  -> timeout_sec:float
  -> request:Keeper_volume_gc.request
  -> (Keeper_volume_gc.report, string) result
