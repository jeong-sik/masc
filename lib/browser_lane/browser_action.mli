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
type interaction =
  | Upload of { selector : string; paths : string list }
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
type t = Open_tab of string | Open_window of string | On_tab of { tab_id : int; frame_path : string list; interaction : interaction }
(** Reply observation window shared by built-in and Add-on action callers.
    Expiry does not prove that a dispatched browser effect did not happen. *)
val reply_timeout_sec : t -> float
val parse : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val key_name : key -> string
val webdriver_key : key -> string
val parse_frame_path : Yojson.Safe.t -> (string list, string) result
