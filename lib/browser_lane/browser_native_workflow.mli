(** A finite list of native Ego Page calls followed by one native snapshot.
    Locators and waits belong to the SDK. This is a browser capability, not
    host JavaScript, a ref registry or a composition interpreter. *)
type element_state = Attached | Detached | Visible | Hidden
type load_state = Dom_content_loaded | Load | Network_idle
type selection = One of string | Many of string list
type clipboard_content = { text : string; html : string option }
type page_code = Expression of string | Call of { source : string; argument : Yojson.Safe.t }
(** Validated native fetch options, excluding host filesystem paths. *)
type fetch_options
type action =
  | Click of string | Double_click of string | Hover of string
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : string }
  | Focus of string | Reload
  | Keyboard_type of string | Keyboard_insert_text of string
  | Keyboard_paste of clipboard_content | Keyboard_press of string
  | Select_option of { selector : string; selection : selection }
  | Goto of string | Wait_for_url of string
  | Wait_for_selector of { selector : string; state : element_state }
  | Wait_for_load_state of load_state
  | Evaluate of page_code
  | Wait_for_function of { code : page_code; polling_ms : int option }
  | Fetch of { url : string; options : fetch_options }
type step = { action : action; timeout_ms : int option }
type snapshot_scope = Viewport | Full_page
type t = private { tab_id : int; expected_url : string; steps : step list;
  snapshot_scope : snapshot_scope; max_chars : int }

(** Strict decoder, with no fallback for unknown methods/fields. [maxChars]
    must be supplied after the caller applies its existing snapshot size policy.
    Optional nonnegative JavaScript-safe [timeoutMs] values are forwarded to
    the native SDK method unchanged; omission preserves the SDK default.
    Keyboard calls accept no [timeoutMs]. Paste passes plain text and optional
    HTML to the SDK, which restores the native clipboard. Focus and all keyboard
    calls are effects, including when a method fails before returning a receipt.
    [evaluate] and [waitForFunction] take [source] as a browser expression;
    with [argumentJson], it is called as a function with that parsed JSON value.
    Source is sent only to the SDK's Page expression channel and is never
    evaluated by Node or the host. Page code and fetch count as possible effects,
    including state-wait predicates. Fetch forwards validated browser options;
    [saveAs] requires a download-broker path and is refused here.
    There is no MASC step-count or cumulative execution-time limit. *)
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val is_effect : action -> bool

val method_name : action -> string
