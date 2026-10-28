(** A finite list of native Ego Page/Download calls followed by one native snapshot.
    Locators and waits belong to the SDK. This is a browser capability, not
    host JavaScript, a ref registry or a composition interpreter. *)
type element_state = Attached | Detached | Visible | Hidden
type load_state = Dom_content_loaded | Load | Network_idle
type option_match = { value : string option; label : string option; index : int option }
type option_choice = Text of string | Match of option_match
type selection = Clear | One of option_choice | Many of option_choice list
type clipboard_content = { text : string; html : string option }
type page_code = Expression of string | Call of { source : string; argument : Yojson.Safe.t }
type url_matcher = Glob of string | Regexp of { source : string; flags : string option }
(** Native URL matcher data. RegExp syntax and flags are interpreted by the
    SDK's JavaScript engine; the host never evaluates caller function source. *)
(** Validated SDK options for their exact method, excluding caller host paths.
    Fetch [saveAs] names an artifact file; the worker supplies the private path. *)
type native_options
type action =
  | Click of string | Double_click of string | Hover of string
  | Drag_and_drop of { selector : string; destination : string }
  | Mouse_click of { x : float; y : float }
  | Mouse_move of { x : float; y : float }
  | Mouse_wheel of { x : float; y : float }
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : string }
  | Focus of string | Reload
  | Keyboard_type of string | Keyboard_insert_text of string
  | Keyboard_paste of clipboard_content | Keyboard_press of string
  | Select_option of { selector : string; selection : selection }
  | Goto of string | Wait_for_url of url_matcher
  | Wait_for_selector of { selector : string; state : element_state }
  | Wait_for_load_state of load_state option
  | Evaluate of page_code
  | Wait_for_function of page_code
  | Fetch of string
  | Cancel_download of string
  | Url | Title | Info | Snapshot
  | Events
  | Wait_for_timeout of float
type step = { action : action; options : native_options option }
type snapshot_scope = Viewport | Full_page
type t = private { tab_id : int; expected_url : string; steps : step list;
  snapshot_scope : snapshot_scope; max_chars : int }

(** Strict decoder, with no fallback for unknown methods/fields. [maxChars]
    must be supplied after the caller applies its existing snapshot size policy.
    [options] uses the native SDK names and is validated for the exact method.
    Omission preserves SDK defaults. Methods with no options reject that field.
    [selectionJson] carries the SDK's string/object/array/null selection form.
    [waitForURL] takes exactly one of [url] (a nonempty string/glob) or
    [urlRegex] with string [source] and optional string [flags]. Empty regex
    source is valid; omission of flags preserves the native default.
    Paste passes plain text and optional
    HTML to the SDK, which restores the native clipboard. Focus and all keyboard
    calls are effects, including when a method fails before returning a receipt.
    [evaluate] and [waitForFunction] take [source] as a browser expression;
    with [argumentJson], it is called as a function with that parsed JSON value.
    Source is sent only to the SDK's Page expression channel and is never
    evaluated by Node or the host. Page code and fetch count as possible effects,
    including state-wait predicates. Fetch forwards validated browser options.
    [saveAs] is a nonempty filename, with no directory separators or control
    characters. The worker maps it to a fresh private UUID path and returns a
    download ID. Retrieve its bytes through the same tab's download reader;
    a completed save in a stopped workflow is not permission to repeat fetch.
    [download.cancel] takes a canonical [downloadId] previously observed on
    this exact Page in the same SDK process. It calls the native Download
    handle's [cancel()] once. Its [cancelReturned] receipt reports only that
    the call returned, not that transfer interruption was observed: completion
    can win the race. Re-read the same Page's downloads; never replay after a
    lost result. Fetch saves and completed/foreign downloads are refused before
    calling the SDK. The handle and save/delete lifecycle remain worker-owned.
    [snapshot] forwards all SDK snapshot options, including subtree root and
    action-mark/stable-locator choices; the workflow still ends with its usual
    final snapshot. [url], [title], [info] and [snapshot] return their native
    values as step receipts. [events] reads and clears this SDK process's Page
    event buffer, so it is an effect and a lost result must not be replayed.
    It is not a cross-process event history. [waitForTimeout] takes finite,
    nonnegative milliseconds; elapsed time is not evidence of page readiness.
    There is no MASC step-count or cumulative execution-time limit. *)
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val fetch_save_name : step -> string option
(** Requested artifact filename for a saving Fetch; [None] for every other
    step. This is display metadata and never a caller-selected host path. *)
val is_effect : action -> bool
(** May leave a pointer button or key held when the SDK result is lost or
    interrupted by a dialog. Paste uses the SDK's ControlOrMeta+V sequence. *)
val holds_input : action -> bool

val method_name : action -> string
