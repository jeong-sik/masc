(** A visible installation that cannot serve right now, and why. Selectors
    that return usable exports or services return these beside them from the
    same read, so a caller that finds no export can name the installation
    instead of reporting that none exists. *)

type reason =
  | Starting  (** The worker has not finished starting. *)
  | Stopping  (** The worker is being retired before its detach begins. *)
  | Detaching  (** Cleanup of the worker is in progress. *)
  | Failed of Lane_addon_lifecycle.failed
      (** The installation failed. This is the lifecycle's own failure, not a
          copy of it: {!message} only names the failure, {!operator_message}
          renders it. *)

type t = {
  installation : string;
      (** The declaration id, or the instance id of a manual attach. *)
  instance_id : string;
  package_id : string;
  declared_tools : string list;  (** The package's declared exported tools. *)
  service : Lane_addon_types.worker_service;
  reason : reason;
}

val message : t -> string
(** The rendering for any caller, e.g.
    ["Add-on installation browser-work (package browser) failed; the operator can read why in Lane Add-ons"].
    A failure is named, not explained. Its detail holds host facts (paths,
    owners, modes, worker errors) that only the operator can act on, and a
    message given to a Keeper travels to that Keeper's model provider. A
    caller with operator authority reads the same text, because callers such
    as the Candle appraiser read with operator authority on behalf of the
    Keeper that asked. *)

val operator_message : t -> string
(** {!message} with the lifecycle failure rendered. Only a surface that
    serves the operator alone uses it, such as the lane inventory. *)

val declaring : name:string -> t list -> t list
(** The installations whose package declares the exported tool [name]. *)

val summary : t list -> string option
(** [None] for no installation; otherwise every {!message}, joined. *)
