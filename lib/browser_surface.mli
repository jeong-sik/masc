(** Read-only browser page observations from the selected source. *)
type source = Browser_lane.Lane_name.t = Live | Automation | Stagehand
type request = { route : Browser_selection.preference; tab_id : int option }
val parse_request : Yojson.Safe.t -> (request, string) result
type dialog_kind = Alert | Confirm | Prompt | Beforeunload
val dialog_kind_to_wire : dialog_kind -> string
val dialog_kind_of_wire : string -> dialog_kind option
(** A JavaScript dialog a tab is blocked on, as the browser reported it. [message] is page text and
    can say anything. *)
type dialog = { kind : dialog_kind; message : string; default_value : string option }
val dialog_json : dialog -> Yojson.Safe.t
type ego_page_origin = Agent_created | Unknown_origin
type ego_page = { label : string option; target_id : string; opened_by : ego_page_origin }
(** SDK Page provenance observed in a tab inventory. A missing label means the
    tab is unmanaged. [target_id] is ephemeral, not durable Page identity.
    Origin does not grant control or permission to close/adopt a page. *)
val ego_page_to_json : ego_page -> Yojson.Safe.t
val ego_page_of_json : Yojson.Safe.t -> (ego_page, string) result
(** [window_id] names the browser window a tab is in, when the browser says which. Tabs that share a
    [window_id] share a window. It is opaque, and only comparable within one connection. *)
type tab = { id : int; title : string; url : string; active : bool; window_id : int option;
  dialog : dialog option; ego_page : ego_page option }

(** Which tab a read answers for. [None_active] means no tab was requested
    and none is active, so the answer carries [page = null] and reads nothing. *)
type selection = Requested of tab | Active of tab | None_active
val select : tab_id:int option -> tab list -> (selection, string) result
type read_plan
val prepare_read : tab_id:int option -> Yojson.Safe.t -> (read_plan, string) result
val selected_tab : read_plan -> tab option
val project_read : read_plan -> binding:Browser_binding.t -> started:int64 ->
  page:Yojson.Safe.t option -> (Yojson.Safe.t, string) result
(** Pure inventory/selection and page projection. The answer carries the tabs,
    [selection] as "requested" | "active" | "none_active", the page of the
    selected tab or null, source, clientId and elapsed_ms. A partial inventory
    additionally carries [complete=false] and [unavailableTabs], retaining the
    IDs and errors of tabs whose metadata could not be read, including when
    that list is empty. Naming one of those tabs refuses the read without
    substituting another tab. No browser source is selected here. *)

val parse_capture_request : Yojson.Safe.t -> (request, string) result
(** Capture requires an explicit tab ID; it never falls back to an active tab. *)
val parse_screenshot_request : Yojson.Safe.t ->
  (request * Browser_lane.Capture.t option, string) result
(** Capture request plus optional screenshotOptions. Native options select a
    separate image contract; no caller-owned filesystem path is accepted. *)
val capture_from : binding:Browser_binding.t -> tab_id:int -> started:int64 ->
  Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Viewport PNG as bare base64, source/tab identity, URL/title and elapsed time. *)
val native_capture_from : binding:Browser_binding.t -> tab_id:int -> started:int64 ->
  options:Browser_lane.Capture.t -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Native PNG with exact requested options and scope=page. It carries no
    viewport coordinate frame, including when options are explicitly empty. *)

val parse_client_id : Yojson.Safe.t -> (Browser_lane.client_id option, string) result
val source_name : Browser_lane.route -> string
(** The lane name ({!Browser_lane.Lane_name.to_wire}) a result carries as [source]. *)
