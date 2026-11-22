(** Desktop clipboard reader (images) and writer (local tools + OSC 52). *)

type error =
  | No_reader of { tried : string list }
  | No_image of { reader : string }
  | Unreadable of { reader : string; detail : string }

type reader

val readers : reader list
val reader_name : reader -> string
val reader_command : reader -> dest:string -> string
val read_image : unit -> (string, error) result
val error_to_string : error -> string

type writer

val writers : writer list
val writer_name : writer -> string

type copy_session =
  | Local
  | Multiplexed
  | Remote

val copy_session : (string -> string option) -> copy_session

type copy_route =
  | Through_tools of {
      first : writer;
      rest : writer list;
      also_terminal : bool;
    }
  | Terminal_only

val copy_route : copy_session -> installed:(string -> bool) -> copy_route

type terminal_reason =
  | Not_tried
  | Tools_failed of string * string list
  | Not_staged of string

type copy_outcome =
  | Copied_by of string
  | Copied_by_and_sent_to_terminal of string
  | Sent_to_terminal of terminal_reason

val osc52_sequence : ?in_tmux:bool -> string -> string
(** Encode [text] as an OSC 52 clipboard escape sequence using Base64 (wrapped
    in tmux DCS passthrough when [~in_tmux:true]). *)

val copy_text :
  copy_session -> write_osc52:(string -> unit) -> string -> copy_outcome

val copy_outcome_say : copy_outcome -> Masc_tui_core.Say.t
val copy_outcome_text : copy_outcome -> string
val copy_outcome_text_korean : copy_outcome -> string
