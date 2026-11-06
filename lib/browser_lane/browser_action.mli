(** Closed browser interactions. Arguments are parsed before any browser effect. *)
type key = Enter | Tab | Escape | Backspace | Delete | ArrowUp | ArrowDown | ArrowLeft | ArrowRight | Home | End
type geolocation = { latitude : float; longitude : float; accuracy_m : float }
(** A tab's reported environment. Each part is optional, at least one is set;
    [Clear_emulation] restores its location, language and time zone overrides
    only. On an ego connection each part is a CDP override on that Page, and
    setting geolocation also grants the page's origin geolocation in the ego
    profile; clearing leaves that grant. Overrides and grant end with the ego
    SDK process that set them. *)
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
  | Set_emulation of emulation
  | Clear_emulation
  | Block_requests of string list
      (** Exact lowercase host names or IPv4 addresses, at least one. On an
          ego connection the Page's CDP session blocks its own and its
          same-process frames' subresource requests to them; navigations and
          cross-site frames are not blocked. The block adds to the Page's
          earlier ones and ends with the ego SDK process. *)
  | Unblock_requests
      (** Lifts every block on the tab. *)
  | Accept_dialog of string option | Dismiss_dialog
  | Back | Forward | Reload
  | Stop_loading
      (** Native Ego recovery through the selected managed Page's CDP session
          without first reading that Page. The result acknowledges command
          return, not document readiness, URL identity or input release.
          Other backends refuse it. *)
  | Close_tab
(** Who holds an ego task space. [Hand_off] gives the whole space to the
    operator for a step only a person can take, such as a sign-in or a
    captcha; [Take_over] takes it back, once the operator has said they are
    done. Nothing checks that they said so. *)
type control_wait = { interval_ms : float option; timeout_ms : float option }
(** Positive finite SDK milliseconds. The caller's options are forwarded
    unchanged and executor-owned: an omitted timeout keeps the SDK default
    wait, an omitted interval keeps the SDK default poll, and no reply-window
    clamp or upper refusal is applied at this boundary. *)
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
type t = Open_tab of string | Control of control
  | On_tab of { tab_id : int; interaction : interaction }
val is_take_over : t -> bool
(** The one control a live lane answers without a client: reclaiming the ego
    task space whose task ended while the operator held it. *)
(** Reply observation window shared by built-in and Add-on action callers.
    Expiry does not prove that a dispatched browser effect did not happen. *)
val reply_timeout_sec : t -> float
val parse : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val key_name : key -> string
val webdriver_key : key -> string
