(** The wiki page contract: header values, the [source] vocabulary and the
    frontmatter a page carries. Pure: no file is read or written here. The
    prose contract is in {!Tool_wiki}. *)

(** {1 Wiki source} *)

(** The kind of work a wiki page came from. *)
type wiki_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation

val source_to_string : wiki_source -> string
(** The spelling written to, and read back from, a page's [source]. *)

val valid_source_strings : string list
(** Every spelling [masc_wiki_create] accepts for [source], derived from
    {!wiki_source}. Handler error messages list it. *)

val source_of_string_opt : string -> wiki_source option
(** The inverse of {!source_to_string}: the constructor whose spelling is
    exactly the argument. *)

(** {1 Header values} *)

(** A value that fits one header line and reads back unchanged. *)
module Line : sig
  type t = private string

  type problem =
    | Blank  (** Empty once trimmed. *)
    | Spans_lines  (** Holds a line feed or a carriage return. *)
    | Outer_whitespace  (** The reader would trim it. *)

  val of_string : string -> (t, problem) result

  val of_calendar_date : year:int -> month:int -> day:int -> t
  (** [YYYY-MM-DD], from a calendar date as people write it (year 2026, month
      10, day 13). *)
end

(** One tag: a {!Line.t} with no comma. *)
module Tag : sig
  type t = private string

  type problem =
    | Not_a_line of Line.problem
    | Has_comma  (** Would read back as two tags. *)

  val of_string : string -> (t, problem) result

  val to_line : t list -> string
  (** The value of the [tags] line: [\[a, b\]], or [\[\]] for none. *)

  val of_line : string -> t list option
  (** Reads what {!to_line} wrote, and for every list of tags
      [of_line (to_line tags) = Some tags]. [None] for anything else: no
      brackets around the value, or an empty piece between commas. *)
end

(** {1 Pages} *)

type frontmatter = {
  title : Line.t;
  summary : Line.t;  (** One line saying what the page holds. *)
  source : wiki_source;
  author : Line.t;
  created : Line.t;
  revision : int;  (** 1 when created; one more after each update. *)
  tags : Tag.t list;
}

type frontmatter_error
(** Why a page does not read: no frontmatter, a block with no closing
    delimiter, a required field absent or empty, a [source] outside
    {!wiki_source}, a [revision] that is not a whole number from 1, a [tags]
    value {!Tag.of_line} does not read, or a carriage return inside a value. *)

val parse_frontmatter : string -> (frontmatter, frontmatter_error) result

val frontmatter_error_to_string : frontmatter_error -> string
(** The reason as a reader sees it. An unknown [source] is quoted as written. *)

val describe_unreadable : string -> frontmatter_error -> string
(** [describe_unreadable path error] is ["<basename> (<reason>)"], the line
    every wiki surface prints for a page that does not read. *)

val render_page : frontmatter -> updated:Line.t -> body:string -> string
(** The page file as written: the header, a blank line, then [body]. *)

val page_body : string -> string
(** The body as the writer sent it: everything after the header, without the
    blank line {!render_page} puts between the two. *)
