(** Whether the workspace has browser Add-ons and what their workers last
    published, read per lane. Since #44295 browser hosts register with a
    worker, not with the server process, so the Lanes rows and the browser
    lane check both read here. *)

(** Why the reading says nothing of the hosts, kept typed so each surface
    renders it for whoever reads that surface. *)
type unavailable =
  | Refused of Lane_addon_runtime.export_refusal
      (** The runtime refused the cached observation. *)
  | Observation_unreadable of string
      (** The worker published an observation this build does not read; why. *)
  | Declarations_incomplete
      (** There is no observation, no readable browser declaration is
          switched on, and the Lane Add-on declarations could not all be
          read: one that was not read may be a browser Add-on switched on, so
          which absence it is is not known. *)

type t =
  | Observed of Browser_addon_observation.published
  | Absent  (** No browser Add-on is declared. *)
  | Off
      (** A browser Add-on is declared and switched off, and every
          declaration was read, so none is switched on. *)
  | Not_running of Browser_lane_launcher.not_running
      (** One is declared on and the runtime runs no installation of it that
          the reader can see, with what is known of why. *)
  | Unavailable of unavailable

(** One reading of every browser installation, from which each lane is
    decided. *)
type reading

(** A reading of these observations ({!Lane_addon_runtime.browser_observations}).
    [applications] is asked only when a lane's browser Add-on is declared on
    and none runs: it answers how the configuration maintenance pass last
    applied each declaration ({!Lane_addon_runtime.inventory}), or nothing for
    a reader that may not see that. *)
val of_observations :
  declarations:Lane_addon_config.snapshot ->
  applications:(unit -> Lane_addon_runtime.configuration_application list) ->
  Lane_addon_runtime.browser_observation list -> reading

(** Ask the runtime for the browser installations' cached observations. It
    runs on the Lane Add-on owner domain and waits for no browser command.
    [access] is the reader's: an installation it cannot see is not read, so
    the reading never names one to a caller who could not list it. Native
    browser hosts register with the installation
    {!Lane_addon_sources.Operator_configuration} sees. Only that access reads
    how a declaration was applied, which is operator metadata, so only it
    tells a failed attach. *)
val read :
  config:Workspace.config -> access:Lane_addon_sources.access ->
  declarations:Lane_addon_config.snapshot -> reading

(** The lane as the installations of its sources say: their observations
    merged ({!Browser_addon_observation.merge}), the way the host uses them,
    or why there is none. A source whose observation is refused or
    unreadable, including one two installations serve
    ({!Lane_addon_runtime.Ambiguous_installations}), leaves out only what it
    would publish, and its own package row says why. The lane is unavailable
    only when none of them published, for the first refusal or unreadable
    observation. With nothing published and nothing withheld, the
    declarations of that lane's browser Add-ons say which absence it is; an
    incomplete declaration snapshot proves none. The other lanes are decided
    apart. *)
val lane : reading -> Browser_lane.Lane_name.t -> t

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
