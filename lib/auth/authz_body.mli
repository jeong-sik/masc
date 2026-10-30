(* HIGH-RISK-UNREVIEWED: this module writes the bytes that the hashes of the
   authorization log cover. A change to what it writes makes every line already
   on disk fail verification. *)

(** The body of an authorization log record: JSON that every reader reads the
    same way.

    A body holds null, booleans, integers, strings, lists, and objects. It
    holds no float, because the text of a float is the printer's choice and
    [nan] has none. An integer lies between -(2^53 - 1) and 2^53 - 1, the
    range that RFC 8259 section 6 calls interoperable: a reader that parses
    numbers as doubles reads each of them exactly. A string and an object
    member name are valid UTF-8 (RFC 8259 section 8.1). The member names of one
    object are unique, because readers disagree on which value wins when a name
    repeats (RFC 8259 section 4).

    A value of type {!t} can only be made through the functions below, so a
    value that exists satisfies all of this.

    {!to_string} is the single printer of the log. Its output is part of the file
    format and does not depend on the version of any library. It writes no
    spaces and keeps the members in the order given. A quote, a backslash,
    a backspace, a form feed, a line feed, a carriage return, and a tab get
    their short backslash escapes. Every other character below the space
    (U+0000 to U+001F) is written as a backslash, the letter u, and four
    lowercase hex digits. Every other character, DEL included, is written as
    its UTF-8 bytes. A string comes out as RFC 8785 section 3.2.2.2 writes it,
    which is also what JSON.stringify and the json module of Python write. Only
    the string rule is RFC 8785: the members are not sorted, so a tool that must
    write the same bytes keeps the order given. *)

type t = private
  | Null
  | Bool of bool
  | Int of int
  | String of string
  | List of t list
  | Object of (string * t) list

type error =
  | Float_not_allowed
  | Integer_out_of_range
  | Invalid_utf8
  | Repeated_name of string  (** The smallest name that appears twice. *)

val error_to_string : error -> string
val null : t
val bool : bool -> t
val int : int -> (t, error) result
val string : string -> (t, error) result
val list : t list -> t

(** The members keep the order given. *)
val object_ : (string * t) list -> (t, error) result

(** Reads a parsed JSON value. The first error found, depth first and in
    order, is the result. *)
val of_yojson : Yojson.Safe.t -> (t, error) result

val to_yojson : t -> Yojson.Safe.t

(** The canonical text of a body. *)
val to_string : t -> string

(** The canonical text of one string, quotes included, for text that is already
    known to be valid UTF-8, such as an identifier of the log's own
    vocabulary. It does not check that the text is valid UTF-8. *)
val string_literal : string -> string
