(** Typed, terminal-safe projection of the Keeper status sandbox observation. *)

type t

type image_issue =
  | Image_not_declared
  | Image_catalog_unreadable
  | Image_unknown_name
  | Image_not_promoted
  | Image_no_store
  | Image_issue_unclassified

val image_issue : t -> image_issue option

type guest_size_issue = Guest_size_unresolved | Guest_size_unclassified
val guest_size_issue : t -> guest_size_issue option

type kata_host_alignment =
  | Host_selectors_match
  | Host_selectors_differ
  | Host_selectors_unavailable

val kata_host_alignment : t -> kata_host_alignment option

type inventory_decision =
  | Remote_execution_unobserved
  | Remote_inventory_inconsistent
  | Inventory_context_unavailable of string
  | Inventory_backend_unresolved of string
  | Inventory_failed of string
  | Inventory_unreported
  | Inventory_observed of { total : int; running : int; unknown : int }

val inventory_decision : t -> inventory_decision

type name_report

type load_result =
  | Inventory_result of (t, string) result
  | Name_result of (name_report, string) result

type partial

val empty_partial : partial
val add_partial : partial -> load_result -> partial
val partial_complete : partial -> bool
val partial_results : partial ->
  (t, string) result option * (name_report, string) result option
val decode_name :
  sanitize:(string -> string) -> keeper_name:string -> Yojson.Safe.t ->
  (name_report, string) result
val partial_view_lines :
  sanitize:(string -> string) -> ko:bool -> width:int -> partial -> string list
(** Independent inventory and name reads retain either result when the other
    is pending or unavailable. The two observations do not establish that
    matching names identify the same guest. *)

type kata_name_observation =
  | Kata_not_applicable
  | Kata_name_absent
  | Kata_name_expected_runtime
  | Kata_name_other_runtime
  | Kata_name_runtime_unreported
  | Kata_name_unavailable

val kata_name_observation : t -> kata_name_observation option
val kata_scoped_name_seen : t -> bool option

type kata_status_decision =
  | Kata_not_observed
  | Kata_inapplicable
  | Kata_scoped_name_seen
  | Kata_unscoped_expected_runtime
  | Kata_other_runtime
  | Kata_unreported_runtime
  | Kata_absent
  | Kata_unavailable

val kata_status_decision : t -> kata_status_decision
(** The scoped listing and name listing are separate observations. Even
    [Kata_scoped_name_seen] does not establish ownership. *)

val decode :
  sanitize:(string -> string) -> Yojson.Safe.t -> (t, string) result
(** Decode the [sandbox_live] block from the Keeper status response. Missing
    observations stay missing; malformed observed fields fail closed. Every
    fetched string is passed through [sanitize] before it enters TUI state.

    A present [resource_config] object must include
    [work_volume_discard_default], null for an inapplicable backend or an exact
    [{state,error}] object. The closed states are [set]/[absent] with null error
    and [unreadable] with a nonblank diagnostic. Duplicate, unknown or missing
    observation keys and contradictory state/error combinations are refused. *)

val decode_for_keeper :
  sanitize:(string -> string) -> keeper_name:string -> Yojson.Safe.t -> (t, string) result
(** Require both the status and inventory Keeper names to match the requested
    Keeper before accepting the observation. *)

val view_lines : ?ko:bool -> width:int -> t -> string list
(** Render an operator-facing observation, configured resources and filesystem
    locations, then CPU/memory/network facts when an instance was observed.
    Internal projection names and server explanations are deliberately absent.
    Unobserved facts remain explicit rather than being inferred. [width] is the available
    content width, so long diagnostics wrap instead of disappearing at the
    pane edge. Kata name and scoped inventory are distinct observations and
    neither is proof of ownership. *)

type logs

type log_location = Local_log_stream | Remote_ssh_logs | Unknown_log_location

val log_location : logs -> log_location

val logs_kata_host_alignment : logs -> kata_host_alignment option

val decode_logs :
  sanitize:(string -> string) -> Yojson.Safe.t -> (logs, string) result
(** Decode the authenticated host-runtime log response. Log payloads are split
    into lines before each line is terminal-sanitized. The three server states
    decode into distinct values: a backend with instances, a backend with
    none, and a Keeper whose profile keeps no stream on this host, which
    carries the server's sentence saying where the logs are. A state whose
    backend or instance list contradicts it is refused. *)

val logs_view_lines : ?ko:bool -> width:int -> logs -> string list
(** Render the log pane for one Keeper, distinct from Keeper activity and
    tool-call history: Docker or Apple Container stdout/stderr when a local
    stream exists, and otherwise the sentence saying where the logs are.
    A Keeper with no local stream previously drew the red fetch-failure row;
    it now gets that sentence in the informational tone, and no backend name
    or tail count, because there is no stream for either to describe. *)
