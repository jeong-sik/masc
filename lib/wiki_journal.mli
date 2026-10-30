(** The wiki's two own files: [index.md] and [log.md].

    They sit in the wiki directory beside the pages (RFC
    library-becomes-a-wiki, D5 and D6, after Karpathy's llm-wiki).

    - [index.md] has one line per page: its title, its file and its one-line
      summary. It is rebuilt from the pages after every write, so nobody edits
      it by hand.
    - [log.md] has one line per create or update, oldest first. Lines are only
      appended.

    This module renders and writes the two files. It does not read pages:
    {!Tool_wiki} hands it what each page says. *)

val index_file : string
(** ["index.md"]. *)

val log_file : string
(** ["log.md"]. *)

val is_own_file : string -> bool
(** Whether a file name in the wiki directory is one of the two above, and so
    not a page. *)

(** What the index says about one file in the wiki directory. *)
type entry =
  | Page of
      { file : string  (** [<page>.md] *)
      ; title : string
      ; summary : string
      }
  | Unreadable of
      { file : string
      ; reason : string  (** Why its header does not read. *)
      }

val render_entry : entry -> string
(** One entry's line: [- \[title\](file) — summary] for a page,
    [- file (reason)] for a file whose header does not read. *)

val render_index : entry list -> string
(** The heading and one {!render_entry} line per entry in the order given. No
    entries renders the heading and a line saying the wiki is empty. *)

val write_index : wiki_root:string -> entry list -> (unit, string) result
(** Replace [index.md] by rename. *)

type action =
  | Created
  | Updated

val log_line :
  time:Unix.tm -> action:action -> revision:int -> page:string -> author:string
  -> note:string -> string
(** [## \[YYYY-MM-DD HH:MM\] create r1 | page | author | note], without a
    newline. Every line starts with [## \[], so [grep "^## \\\["] lists the
    changes. *)

val append_log : wiki_root:string -> string -> (unit, string) result
(** Append one line to [log.md], creating the file on first use. *)
