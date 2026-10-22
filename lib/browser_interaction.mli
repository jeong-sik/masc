(** Closed browser actions; selectors and text remain data. *)
type request = { route : Browser_selection.preference; tab_id : int;
  expected_url : string option; action : Browser_lane.interaction }
val parse : Yojson.Safe.t -> (request, string) result
val perform : request -> (Yojson.Safe.t, string) result
(** Dispatch once to the explicitly selected lane/client/tab. No automatic retry. *)
val script : string
(** Fixed DOM implementation. WebDriver supplies the parsed action as argument
    zero; the live extension uses the same function with JSON-encoded data. *)
val pointer_guard_script : string
val keyboard_guard_script : string
(** Read-only URL, observed document and focus guard for native keyboard
    input. Typing additionally requires an enabled editable focus target. *)

(** What a pointer action reports once the browser has taken it: url, title
    and scroll offsets. *)
val pointer_receipt_script : string
(** Validate screenshot identity and geometry before native WebDriver pointer input. *)

val pointer_target_script : string
(** Resolve visible, unobstructed semantic click/hover/drag targets to current
    viewport geometry and URL. Click checks disabled/ARIA-disabled activation
    targets, including labels. A drag destination may additionally provide
    [arrival], a distinct point inside the same visible, hit-tested destination
    rectangle. Does not scroll or dispatch page events. *)
val resolve_pointer_action : Browser_lane.interaction -> Yojson.Safe.t ->
  (Browser_lane.interaction, string) result
(** Decode one pre-input semantic resolution into native pointer input. *)

(** Read-only URL guard for an action that moves no pointer and no focus. *)
val url_guard_script : string

(** What a viewport resize reports once the browser has taken it: url, title,
    inner size and device pixel ratio. *)
val viewport_receipt_script : string
