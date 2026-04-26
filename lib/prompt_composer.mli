(** Prompt_composer — structured prompt assembly from typed sections.

    Replaces ad-hoc Printf.sprintf prompt construction with composable,
    typed sections that can be combined in any order.

    @since 3.0.0 *)

(** A section of a composed prompt. *)
type section =
  | Identity of
      { name : string
      ; role : string
      ; model : string
      }
  | TeamContext of Team_context.team_context
  | AvailableTools of string list
  | Guidelines of string list
  | Task of string
  | FreeText of string

(** Compose a list of sections into a single prompt string.
    Sections are joined with double newlines. Empty sections are omitted. *)
val compose : section list -> string

(** Render a single section to string. Returns [""] for empty sections. *)
val render_section : section -> string
