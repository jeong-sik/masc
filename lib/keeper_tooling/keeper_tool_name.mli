(** Keeper-owned MCP tool-name vocabulary.

    Lives on the keeper side of the Tool/Keeper boundary: the tool dispatch
    substrate routes opaque tool names and the keeper subsystem owns the typed
    vocabulary of its own tools. Dependency direction is keeper -> tool, never
    the reverse. See the implementation header for the #19797 history. *)

type t =
  | Execute
  | Board_comment
  | Board_comment_vote
  | Board_curation_read
  | Board_curation_submit
  | Board_post_get
  | Board_list
  | Board_post
  | Board_search
  | Board_stats
  | Board_sub_board_create
  | Board_sub_board_delete
  | Board_sub_board_get
  | Board_sub_board_list
  | Board_sub_board_update
  | Board_vote
  | Broadcast
  | Context_status
  | Fs_edit
  | Fs_write
  | Fs_read
  | Ide_annotate
  | Handoff
  | Library_read
  | Library_search
  | Memory_search
  | Memory_write
  | Search_files
  | Surface_read
  | Surface_post
  | Person_note_set
  | Task_claim
  | Task_create
  | Task_done
  | Tasks_audit
  | Tasks_list
  | Time_now
  | Tool_search
  | Tools_list
  | Persona_create
  | Persona_update
  | Voice_agent
  | Voice_listen
  | Voice_session_end
  | Voice_session_start
  | Voice_sessions
  | Voice_speak

val all : t list
(** All keeper tool-name variants. *)

val to_string : t -> string
val of_string : string -> t option
val pp : Format.formatter -> t -> unit

val masc_board_name_of_keeper_tool : t -> Tool_name.Board_name.t option
(** Typed mapping from keeper-owned board wrapper names to the public
    [masc_board_*] board tool vocabulary. Non-board keeper names return
    [None]. *)

val masc_board_name_of_keeper_name : string -> Tool_name.Board_name.t option
(** Parse a [keeper_board_*] string and return the corresponding typed
    public board tool name. *)

(** Public MCP names intentionally served outside the keeper descriptor spine.
    Keep this exact allowlist on the keeper side so prefix canonicalisation
    does not depend on the MCP catalog hand-list. *)
val public_mcp_non_descriptor_names : string list

(** Returns true for keeper board wrapper names and legacy public
    [masc_board_*] names without depending on the central [Tool_name] enum. *)
val is_board_surface_name : string -> bool

(** Returns true for mutating board write surfaces that require extra keeper
    board-write guard accounting. Handles keeper-owned names, legacy
    [masc_board_*] names, and the MCP transport prefix. *)
val is_board_write_surface_name : string -> bool
