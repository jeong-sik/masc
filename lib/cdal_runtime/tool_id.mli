(** Typed tool identifier for the CDAL runtime (RFC-0005 Phase 1 §3.1
    follow-up).

    Each constructor names a tool the CDAL runtime can recognise without
    a string lookup. [Mode_enforcer.default_tool_entries] used to seed
    classifications for these names but was emptied by RFC-OAS-012 — the
    Variant is kept because future register-side APIs may take
    [Tool_id.t] for compile-time exhaustiveness, and because a closed
    Variant remains the cheapest way to ensure the registry never silently
    diverges from a known catalogue.

    Public APIs of [Mode_enforcer] (e.g. [classify_tool],
    [register_tool_class]) remain string-typed because plugin tools
    register at runtime by name. The variant only types the
    *compile-time-known* default table.

    @stability Evolving
    @since 0.19.17 *)

type t =
  (* Read-only — file & code navigation *)
  [ `Read
  | `Glob
  | `Grep
  | `Search
  | `List_dir
  | `Find_file
  | `Read_file
  | `Find_symbol
  | `Get_symbols_overview
  | `Find_referencing_symbols
  | `Search_for_pattern
  | (* Read-only — notebook *)
      `Notebook_read
  | (* Read-only — browser observation *)
      `Read_console_messages
  | `Read_network_requests
  | `Get_page_text
  | `Read_page
  | `Tabs_context_mcp
  | (* Read-only — task queries *)
      `Task_list
  | `Task_get
  | `Task_output
  | (* Local mutation — file editing *)
      `Write
  | `Edit
  | `Create_text_file
  | `Replace_content
  | `Rename_symbol
  | `Insert_after_symbol
  | `Insert_before_symbol
  | `Replace_symbol_body
  | `Notebook_edit
  | (* Local mutation — task & team management *)
      `Task_create
  | `Task_update
  | `Task_stop
  | `Team_create
  | `Team_delete
  | (* External effect — HITL *)
      `Ask_user_question
  | (* External effect — web & research *)
      `Web_fetch
  | `Web_search
  | (* External effect — browser interaction *)
      `Navigate
  | `Computer
  | `Find
  | `Form_input
  | `Javascript_tool
  | `Tabs_create_mcp
  | `Upload_image
  | (* Shell-dynamic — runtime input analysis required *)
      `Bash
  | `Execute_shell_command
  | (* Plugin / unknown — fallback that preserves the wire-format string. *)
    `Other_tool of string
  ]

(** Project a [t] to its canonical wire-format string. *)
val to_string : t -> string

(** Parse a wire-format string into [t]. Unknown names map to
    [`Other_tool s] (lowercased) — fail-open with provenance preserved
    for downstream classification. *)
val of_string : string -> t

(** Same as [of_string] but normalised: input is lowercased and trimmed
    before lookup. Matches the lowercasing convention used by
    [Mode_enforcer.register_tool_class]. *)
val of_string_normalised : string -> t

(** All known constructors (excludes [`Other_tool _]). Useful for
    enumerating the built-in classification table and for tests that
    assert round-trip stability. *)
val known : t list
