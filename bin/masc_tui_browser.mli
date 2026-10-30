(** Hand a URL to whatever opens links on this machine.

    The consent URL an OAuth login produces is about nine hundred characters.
    A terminal pane truncates it, and a truncated URL is not a URL -- an
    operator cannot select it, cannot copy it, and the login stops there.

    So the TUI opens it rather than printing it and hoping. The URL is still
    printed, wrapped, because an opener can be absent and then the wrapped
    text is the only way through. *)

val openers : string list
(** The commands tried, in order. macOS first, then the freedesktop one;
    a machine with neither gets an error naming both rather than silence. *)

val command_for : opener:string -> url:string -> string
(** The shell command for one opener. The URL is quoted: it carries [&] and
    [?] by construction, and an unquoted one would reach the shell as
    several commands. *)

val open_url : string -> (string, string) result
(** [Ok opener] names the command that took it. [Error] says what was tried,
    because "the browser did not open" with no list is not something an
    operator can act on. *)

type undrawn_image = { title : string; page_url : string; image_url : string }
(** A web image the TUI could not, or does not, draw inline. [title] is the
    display line, indented for the screen, and is never a location.
    [page_url] is the link the operator chose. [image_url] is the preview
    picture fetched for that link -- the thing that failed. *)

val browser_url : undrawn_image -> string
(** The one URL a browser gets for an [undrawn_image]: [page_url]. The
    picture that could not be drawn is not what the operator asked for, and
    the display title is not a URL at all. *)
