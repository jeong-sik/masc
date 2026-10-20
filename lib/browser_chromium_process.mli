(** Pure Chromium launch arguments and debugging endpoint decoding.
    The browser Add-on owns the actual child through its native guardian and
    original kernel lease; this module neither observes nor signals processes. *)

(** Where launch arguments point the browser: a fresh private allocation, or
    an operator profile. Admission and preservation belong to the caller. *)
type profile = Private_profile of string | Operator_profile of string

val profile_path : profile -> string

(** [argv ~chrome ~profile ~extension_id ~headless].

    [--remote-debugging-port=0] lets Chrome pick a free port and write it to
    [DevToolsActivePort] in the profile, so nothing races for a port.
    [--enable-unsafe-extension-debugging] lets CDP load the extension.
    [--remote-allow-origins] admits the extension's own websocket and nothing
    else: the extension connects back to the CDP URL it is given, with its
    [chrome-extension://<id>] origin, while masc's client sends no origin.
    A private profile also gets a mock Keychain and a basic password store,
    so a fresh profile asks macOS nothing; an operator's profile keeps its
    own. *)
val argv : chrome:string -> profile:profile -> extension_id:string -> headless:bool -> string list

(** The name of the file Chrome writes its debugging port and browser
    websocket path into, inside the profile. *)
val devtools_port_file : string

(** Reads [DevToolsActivePort]: the port on the first line, the browser
    target's websocket path on the second. *)
val devtools_endpoint_of_string : string -> (int * string, string) result

(** The loopback websocket URL of the browser target. *)
val browser_ws_url : port:int -> path:string -> string
