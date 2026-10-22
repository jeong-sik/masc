(** Whether the workspace has a browser Add-on and what its worker last
    published. Since #44295 browser hosts register with that worker, not with
    the server process, so the Lanes rows and the browser lane check both read
    here. *)

(** Why the reading says nothing of the hosts, kept typed so each surface
    renders it for whoever reads that surface. *)
type unavailable =
  | Refused of Lane_addon_runtime.export_refusal
      (** The runtime refused the cached observation. *)
  | Observation_unreadable of string
      (** The worker published an observation this build does not read; why. *)
  | Declarations_incomplete
      (** There is no observation and the Lane Add-on declarations could not
          all be read, so which absence it is is not known. *)

type t =
  | Observed of Browser_addon_observation.published
  | Absent  (** No browser Add-on is declared. *)
  | Off  (** A browser Add-on is declared and switched off. *)
  | Not_running  (** One is declared on and the runtime runs no installation of it. *)
  | Unavailable of unavailable

(** Decide from what {!Lane_addon_runtime.observation_for_export} answered for
    the browser tool. With no observation, the declarations say which absence
    it is; an incomplete declaration snapshot proves none. *)
val of_export :
  declarations:Lane_addon_config.snapshot ->
  (Lane_addon_runtime.export_observation option, Lane_addon_runtime.export_refusal) result -> t

(** Ask the runtime for the browser Add-on's cached observation and decide.
    It runs on the Lane Add-on owner domain and waits for no browser command. *)
val read : config:Workspace.config -> declarations:Lane_addon_config.snapshot -> t

(** The reason in words any reader may be shown: a refusal through
    {!Lane_addon_runtime.export_refusal_message}. *)
val unavailable_message : unavailable -> string

(** The reason with each failure rendered, through
    {!Lane_addon_runtime.export_refusal_operator_message}. Only a surface
    served to the operator alone uses it, such as the lane inventory. *)
val unavailable_operator_message : unavailable -> string

(** The same reading as the browser lane launcher states it. The launcher's
    texts reach [GET /api/v1/dashboard/browser-lane/clients], which a
    read-state caller may read, so an unreadable Add-on carries
    {!unavailable_message}. *)
val polling : t -> Browser_lane_launcher.polling
