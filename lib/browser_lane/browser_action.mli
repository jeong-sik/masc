(** Closed Firefox interactions. Arguments are parsed before any browser effect. *)
type key = Enter | Tab | Escape | Backspace | Delete | ArrowUp | ArrowDown | ArrowLeft | ArrowRight | Home | End
type same_site = Strict | Lax | Same_site_none
(** A cookie the caller sets for the page's own host. The domain is never a
    parameter: the browser scopes the cookie to the tab's current document. *)
type cookie = { name : string; value : string; path : string; secure : bool; http_only : bool;
  same_site : same_site option; max_age_sec : int option }
val max_cookie_age_sec : int
(** A cookie lives at most this long; without a lifetime it is a session cookie. *)

val max_cookie_value_bytes : int
val same_site_wire : same_site -> string
type geolocation = { latitude : float; longitude : float; accuracy_m : float }
(** A tab's reported environment. Each part is optional, at least one is set;
    [Clear_emulation] restores its location, language and time zone overrides only.
    Setting geolocation grants the current origin permission in the owned browser
    session; clearing overrides leaves permissions unchanged. The grant persists
    until that session closes. *)
type emulation = { geolocation : geolocation option; locale : string option; timezone : string option }
val default_accuracy_m : float
val max_accuracy_m : float
(** Where an upload puts its files: [File_input] is a CSS selector for one
    [<input type=file>]; [Chooser_opener] is a CSS selector for the one
    control whose click opens the page's file chooser, as a button that
    makes its input only when clicked does. *)
type upload_target = File_input of string | Chooser_opener of string
type interaction =
  | Upload of { target : upload_target; paths : string list }
  | Set_cookie of cookie
  | Delete_cookie of string
  | Set_emulation of emulation
  | Clear_emulation
  | Block_requests of string list
      (** Requests from the tab and its frames to these exact lowercase hosts
          fail as network errors until [Unblock_requests] lifts every block on
          the tab or the owned browser session closes. Nothing is answered or
          changed in their place. *)
  | Unblock_requests
  | Accept_dialog of string option | Dismiss_dialog
  | Back | Forward | Reload | Close_tab
(** Who holds an ego task space. [Hand_off] gives the whole space to the
    operator for a step only a person can take, such as a sign-in or a
    captcha; [Take_over] takes it back, once the operator has said they are
    done. Nothing checks that they said so. *)
type control_wait = { interval_ms : float option; timeout_ms : float option }
(** Positive finite SDK milliseconds. A missing timeout becomes the action's
    reply window at the Ego peer, which refuses a longer one; a missing
    interval keeps the SDK default. *)
val control_wait_to_json : control_wait -> Yojson.Safe.t
type keep_pages = Keep_all | Keep_labels of string list
(** Native terminal retention policy. [Keep_all] retains all current Pages,
    including Pages discovered by the SDK at completion, without closing the
    Space. [Keep_labels []] is the default completion policy. *)
val keep_pages_to_json : keep_pages -> Yojson.Safe.t
type control = Hand_off | Take_over | Space_status | Finish_space of keep_pages | Wait_for_control of control_wait
  | Adopt_tab of { tab_id : int; label : string option }
  | Release_tab of int
(** [Space_status] reads metadata on the exact bound numeric Space, even when
    delegated, without Page calls or changing control. It is not admission.
    [Finish_space keep] explicitly completes a successful task through the SDK,
    closing only agent-created Pages whose labels are absent from [Keep_labels].
    Unknown-origin managed Pages and unmanaged tabs remain open, even with an
    empty label list. [Keep_all] forwards the native literal policy rather than
    enumerating a possibly stale list of labels. Completion ends all managed Page labels, including those
    of retained Pages.
    Connection retirement never implies task completion.
    [Wait_for_control] calls the native SDK within the current agent-owned
    Space. It does not claim or take over a user-held Space, clear uncertain
    input state, or authorize later commands.
    [Adopt_tab] explicitly brings an observed unmanaged tab in this exact
    Space under the SDK Page lifecycle; [None] lets Ego assign its label.
    [Release_tab] returns an unknown-origin managed Page without closing it.
    Neither transfers Space control or changes the Page's origin. *)
type t = Open_tab of string | Open_window of string | Control of control
  | On_tab of { tab_id : int; frame_path : string list; interaction : interaction }
(** Reply observation window shared by built-in and Add-on action callers.
    Expiry does not prove that a dispatched browser effect did not happen. *)
val reply_timeout_sec : t -> float
val parse : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val key_name : key -> string
val webdriver_key : key -> string
val parse_frame_path : Yojson.Safe.t -> (string list, string) result
