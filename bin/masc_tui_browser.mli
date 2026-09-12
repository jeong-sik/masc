(** Hand a URL to whatever opens links on this machine.

    The consent URL an OAuth login produces is about nine hundred characters.
    A terminal pane truncates it, and a truncated URL is not a URL -- an
    operator cannot select it, cannot copy it, and the login stops there.

    So the TUI opens it rather than printing it and hoping. The URL is still
    printed, wrapped, because an opener can be absent and then the wrapped
    text is the only way through. *)

type opener = Open | Xdg_open
(** The two commands this module knows. [Open] is macOS's, [Xdg_open] the
    freedesktop one. Exactly one is chosen per machine; a refusal from the
    chosen one is reported, not retried with the other. *)

type kernel = Darwin | Linux
(** What [uname -s] can answer that maps to an opener. *)

val kernel_of_uname : string -> (kernel, string) result
(** Parses the [uname -s] line, surrounding whitespace ignored. Any other
    kernel name is an [Error] that quotes it -- there is no opener to guess. *)

val opener_for : kernel -> opener
(** [Darwin] gets [Open], [Linux] gets [Xdg_open]. Total. *)

val opener_command : opener -> string
(** The executable name the shell is given. *)

val command_for : opener:string -> url:string -> string
(** The shell command for one opener. The URL is quoted: it carries [&] and
    [?] by construction, and an unquoted one would reach the shell as
    several commands. *)

val open_url_with :
  run:(string -> Unix.process_status) -> kernel:kernel -> string -> (string, string) result
(** [open_url] with the kernel already answered and the shell supplied.
    [run] is given exactly one command, the chosen opener's, and its exit
    status is the result: [Ok opener_name] on 0, otherwise [Error] with the
    opener, the status and the URL. No other opener is run. *)

val open_url : string -> (string, string) result
(** Asks [uname -s] once, then [open_url_with] on the real shell. [Error]
    names what refused: an unknown kernel, a failed [uname], or the opener's
    exit status with the URL it was given -- something an operator can act
    on. *)

type undrawn_image = { title : string; page_url : string; image_url : string }
(** A web image the TUI could not, or does not, draw inline. [title] is the
    display line, indented for the screen, and is never a location.
    [page_url] is the link the operator chose. [image_url] is the preview
    picture fetched for that link -- the thing that failed. *)

val browser_url : undrawn_image -> string
(** The one URL a browser gets for an [undrawn_image]: [page_url]. The
    picture that could not be drawn is not what the operator asked for, and
    the display title is not a URL at all. *)
