(** Table declarations TOML 1.0 forbids and Otoml reads without complaint.

    A line editor adds a setting by opening a [\[table\]] header when it finds
    none. Two shapes of an existing file make that header a second definition
    of a table that already has one:

    - the table, or a table above it, is written as an inline table
      ([runtime = { default = "a" }] then [\[runtime.assignments\]]). TOML 1.0
      closes an inline table where it is written;
    - the table is defined by dotted keys ([runtime.default = "a"] then
      [\[runtime\]]). TOML 1.0 lets a table be defined once.

    Otoml merges both, so the loader keeps working while a strict reader
    (Python's [tomllib], [taplo]) refuses the whole file. This module reads
    the same declarations the way TOML 1.0 does, so a writer can refuse the
    text before it replaces the file.

    Every declaration is read through the grammar: a header by
    {!Toml_line_editor.header_of_line}, an assignment by parsing that one
    statement, whose value says whether it is an inline table and whose key
    path says which tables its dots define. No line is matched by its
    spelling.

    This is not a TOML 1.0 validator. It reports the two shapes above and
    nothing else; a dotted key that reaches into a table a header defined
    elsewhere is also forbidden and is not reported, because no writer here
    produces one. *)

type declaration =
  | Header of string list  (** [\[a.b\]] or [\[\[a.b\]\]], by key path. *)
  | Dotted_key of string list
      (** A dotted key, by the path of the table its dots reach. *)

type violation =
  | Inline_table_extended of
      { inline_table : string list
      ; by : declaration
      }
      (** [by] adds to [inline_table], or to a table inside it. *)
  | Dotted_table_reopened of string list
      (** A header opens the table that dotted keys already define. *)

type located =
  { line : int  (** One-based line of the forbidden declaration. *)
  ; first_defined_at : int
      (** One-based line of the inline table or the dotted key it collides
          with. *)
  ; violation : violation
  }

type unreadable =
  { unreadable_line : int
  ; detail : string
  }
(** An assignment that does not parse on its own. A document that parses as a
    whole has none; the caller decides what a text it cannot judge means. *)

val violations : string -> (located list, unreadable) result
(** The forbidden declarations of a document, in file order. An entry of an
    array of tables is its own scope: what one [\[\[a\]\]] entry declares does
    not collide with the next. *)

val same_violation : located -> located -> bool
(** Whether two reports name the same declaration, wherever its line is. A
    writer comparing a text with the one it replaces uses this, since an
    edit above a declaration moves its line. *)

val to_string : located -> string
(** One sentence naming both lines and what to write instead. *)

val unreadable_to_string : unreadable -> string
