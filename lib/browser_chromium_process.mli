(** The Chromium process one MASC server runs for its Stagehand lane
    (RFC-browser-lane-stagehand §3.5). Pure: nothing here starts, reads or
    stops a process.

    Like {!Browser_driver_process}, the server writes down the browser it
    started, and a server that died before stopping it leaves that record for
    the next server on the workspace to act on. *)

type owner = { pid : int; chrome : string; profile : string }
(** [pid] leads the browser's process group. [chrome] is the executable
    started and [profile] the [--user-data-dir] it was given. *)

val owner_record_path : masc_root:string -> string
val owner_to_string : owner -> string
val owner_of_string : string -> (owner, string) result

(** The profile a session without an operator-owned one uses. The server
    empties it before each launch. *)
val server_profile : masc_root:string -> string

(** [argv ~chrome ~profile ~extension_id ~headless].

    [--remote-debugging-port=0] lets Chrome pick a free port and write it to
    [DevToolsActivePort] in the profile, so nothing races for a port.
    [--enable-unsafe-extension-debugging] lets CDP load the extension.
    [--remote-allow-origins] admits the extension's own websocket and nothing
    else: the extension connects back to the CDP URL it is given, with its
    [chrome-extension://<id>] origin, while masc's client sends no origin. *)
val argv : chrome:string -> profile:string -> extension_id:string -> headless:bool -> string list

(** The name of the file Chrome writes its debugging port and browser
    websocket path into, inside the profile. *)
val devtools_port_file : string

(** Reads [DevToolsActivePort]: the port on the first line, the browser
    target's websocket path on the second. *)
val devtools_endpoint_of_string : string -> (int * string, string) result

(** The loopback websocket URL of the browser target. *)
val browser_ws_url : port:int -> path:string -> string

type leftover = Stop_recorded_browser of int | Not_the_recorded_browser

(** [command] is what the process table shows for [owner.pid] now, [None] when
    no such process exists. Only a process that is the recorded executable
    running on the recorded profile is stopped: a pid handed to another
    program since then is left alone. *)
val leftover : owner -> command:string option -> leftover
