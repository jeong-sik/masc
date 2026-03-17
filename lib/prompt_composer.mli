(** Prompt_composer — structured prompt assembly from typed sections.

    Replaces ad-hoc Printf.sprintf prompt construction with composable,
    typed sections that can be combined in any order.

    Usage:
    {[
      let prompt = Prompt_composer.compose [
        Identity { name = "worker-1"; role = "developer"; model = "glm-4.7" };
        TeamContext team_ctx;
        AvailableTools tool_names;
        Guidelines ["verify changes"; "use tests"];
        Task "Implement feature X";
      ]
    ]}

    @since 3.0.0 *)

(** A section of a composed prompt. *)
type section =
  | Identity of { name : string; role : string; model : string }
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
