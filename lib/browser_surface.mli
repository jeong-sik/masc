(** Read-only browser page observations from the selected source. *)
type source = Browser_lane.Lane_name.t = Live | Automation | Stagehand
type request = { route : Browser_selection.preference; tab_id : int option }
val parse_request : Yojson.Safe.t -> (request, string) result
(** [window_id] names the browser window a tab is in, when the browser says which. Tabs that share a
    [window_id] share a window. It is opaque, and only comparable within one connection. *)
type tab = { id : int; title : string; url : string; active : bool; window_id : int option }

(** Which tab a read answers for. [None_active] means no tab was requested
    and none is active, so the answer carries [page = null] and reads nothing. *)
type selection = Requested of tab | Active of tab | None_active
val select : tab_id:int option -> tab list -> (selection, string) result
(** Why a read returned no observation. [Unselected] is a request that named
    no browser to ask, before or after its target was resolved; a caller that
    reports it names the connected browsers and the host configuration.
    [Unobserved] is an answer that is not the observation asked for.
    [Unavailable] is an absent or timed-out browser transport. *)
type failure = Unselected of Browser_lane.selection_error | Unchosen of Browser_selection.error
  | Unobserved of string | Unavailable of string
val failure_message : failure -> string

val choose_browser : verb:Browser_lane.verb -> request -> (Browser_selection.selected, failure) result
val resolve_target : ?required_actions:Browser_capabilities.operation list -> verb:Browser_lane.verb -> request ->
  (Browser_selection.selected * Browser_lane.target, failure) result
(** Selection performs no browser command; resolution binds a concrete connection.
    An observed tab requires its original explicit browser identity. *)

val observe_answer : lane:Browser_lane.Lane_name.t -> Browser_lane.answer -> (Yojson.Safe.t, failure) result
(** Typed observation boundary: absent and timed-out transports remain
    dependency failures rather than invalid page observations. *)

val read : request -> (Yojson.Safe.t, failure) result
(** Tabs, [selection] as "requested" | "active" | "none_active", the page of the
    selected tab or null, source, clientId and elapsed_ms. A partial inventory
    additionally carries [complete=false] and [unavailableTabs], retaining the
    IDs and errors of tabs whose metadata could not be read, including when
    that list is empty. Naming one of
    those tabs refuses the read without substituting another tab. *)
type read_plan
val prepare_read : tab_id:int option -> Yojson.Safe.t -> (read_plan, failure) result
val selected_tab : read_plan -> tab option
val project_read : read_plan -> binding:Browser_binding.t -> started:int64 ->
  page:Yojson.Safe.t option -> (Yojson.Safe.t, failure) result
(** Pure inventory/selection and page projection shared by transports. A partial
    inventory never substitutes another tab. No browser source is selected here. *)

(** [lane] names the lane the answer came from, so an absent backend is
    reported the way that lane is set up. *)
val decode_answer : lane:Browser_lane.Lane_name.t -> Browser_lane.answer -> (Yojson.Safe.t, string) result

val parse_capture_request : Yojson.Safe.t -> (request, string) result
(** Capture requires an explicit tab ID; it never falls back to an active tab. *)
val capture : request -> (Yojson.Safe.t, failure) result
(** Viewport PNG as bare base64, source/tab identity, URL/title and elapsed time. *)
val capture_from : binding:Browser_binding.t -> tab_id:int -> started:int64 ->
  Yojson.Safe.t -> (Yojson.Safe.t, failure) result

val parse_client_id : Yojson.Safe.t -> (Browser_lane.client_id option, string) result
val source_name : Browser_lane.route -> string
(** The lane name ({!Browser_lane.Lane_name.to_wire}) a result carries as [source]. *)
