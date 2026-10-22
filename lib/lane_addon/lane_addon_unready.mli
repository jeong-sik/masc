(** A visible installation that cannot serve right now, and why. Selectors
    that return usable exports or services return these beside them from the
    same read, so a caller that finds no export can name the installation
    instead of reporting that none exists. *)

type reason =
  | Starting  (** The worker has not finished starting. *)
  | Stopping  (** The worker is being retired before its detach begins. *)
  | Detaching  (** Cleanup of the worker is in progress. *)
  | Failed of string  (** The installation failed; the text is its failure. *)

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
(** The one rendering every caller uses, e.g.
    ["Add-on installation browser-work (package browser) failed: <detail>"]. *)

val declaring : name:string -> t list -> t list
(** The installations whose package declares the exported tool [name]. *)

val summary : t list -> string option
(** [None] for no installation; otherwise every {!message}, joined. *)
