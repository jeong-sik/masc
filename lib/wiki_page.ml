(** The wiki page contract: header values, the [source] vocabulary, the
    frontmatter a page carries and how a page is rendered. Pure: it reads and
    writes no file, so a tool and the lint read a page by one definition
    (RFC-wiki-lint-and-page-contracts §4.4, step 1a). Moved out of
    [Tool_wiki] without changing a line of its behaviour. *)

open Printf

(** The page [source] vocabulary. [source_to_string] is the one place the
    spelling is written: [valid_source_strings] and [source_of_string_opt] are
    derived from it over [all_of_wiki_source], so a new constructor is a
    non-exhaustive match there and nowhere else in this module.
    masc_wiki_create's schema writes the same strings as a literal enum in
    config/tools/masc_wiki_create.toml; the "wiki source enum" case in
    test_enum_mirror_sync compares that enum with [valid_source_strings]. *)
type wiki_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation
[@@deriving enumerate]

let source_to_string = function
  | Direct_experience -> "direct_experience"
  | Research -> "research"
  | Experiment -> "experiment"
  | Observation -> "observation"

let valid_source_strings = List.map source_to_string all_of_wiki_source

let source_of_string_opt raw =
  List.find_opt
    (fun source -> String.equal (source_to_string source) raw)
    all_of_wiki_source

(* Header values. Each is written on one line as [key: value] and read back
   trimmed. A [Line.t] comes back as it went in: not blank, one line, nothing
   to trim. Both ways into this module, the tool arguments and a page on
   disk, build one with [Line.of_string], and the page writer takes nothing
   else, so a header value nobody checked does not type. *)
module Line : sig
  type t = private string

  type problem =
    | Blank
    | Spans_lines
    | Outer_whitespace

  val of_string : string -> (t, problem) result

  val of_calendar_date : year:int -> month:int -> day:int -> t
  (** [YYYY-MM-DD]. *)
end = struct
  type t = string

  type problem =
    | Blank
    | Spans_lines
    | Outer_whitespace

  let of_string value =
    let trimmed = String.trim value in
    if String.equal trimmed ""
    then Error Blank
    else if String.contains value '\n' || String.contains value '\r'
    then Error Spans_lines
    else if not (String.equal trimmed value)
    then Error Outer_whitespace
    else Ok value

  let of_calendar_date ~year ~month ~day = sprintf "%04d-%02d-%02d" year month day
end

(* The tags line is [tags: \[a, b\]]. A tag is a header value with no comma:
   a comma would come back as two tags. [of_line] reads what [to_line] wrote
   and nothing looser: a value outside the brackets, or an empty piece between
   two commas, is not cut down to the pieces that happen to parse. *)
module Tag : sig
  type t = private string

  type problem =
    | Not_a_line of Line.problem
    | Has_comma

  val of_string : string -> (t, problem) result
  val to_line : t list -> string
  val of_line : string -> t list option
end = struct
  type t = string

  type problem =
    | Not_a_line of Line.problem
    | Has_comma

  let of_string value =
    match Line.of_string value with
    | Error problem -> Error (Not_a_line problem)
    | Ok _ when String.contains value ',' -> Error Has_comma
    | Ok _ -> Ok value

  let to_line tags = "[" ^ String.concat ", " tags ^ "]"

  let of_line value =
    let raw = String.trim value in
    let len = String.length raw in
    if len < 2 || not (Char.equal raw.[0] '[' && Char.equal raw.[len - 1] ']')
    then None
    else (
      let inner = String.sub raw 1 (len - 2) in
      if String.equal (String.trim inner) ""
      then Some []
      else
        String.split_on_char ',' inner
        |> List.fold_left
             (fun read piece ->
                match read, of_string (String.trim piece) with
                | Some tags, Ok tag -> Some (tag :: tags)
                | None, _ | _, Error _ -> None)
             (Some [])
        |> Option.map List.rev)
end

(* YAML frontmatter parsing. Every field a writer sets and a reader projects
   is required: a page missing one does not read, rather than reading as an
   empty string. [updated] is written but nothing reads it. *)
type frontmatter = {
  title: Line.t;
  summary: Line.t;
  source: wiki_source;
  author: Line.t;
  created: Line.t;
  revision: int;
  tags: Tag.t list;
}

type frontmatter_field =
  | Title
  | Summary
  | Source
  | Author
  | Created
  | Revision
  | Tags

let frontmatter_field_key = function
  | Title -> "title"
  | Summary -> "summary"
  | Source -> "source"
  | Author -> "author"
  | Created -> "created"
  | Revision -> "revision"
  | Tags -> "tags"

(* Why a page's header does not read as a wiki page. The raw value
   of an unknown source is kept only to name it back to the reader. *)
type frontmatter_error =
  | No_frontmatter
  | Unclosed_frontmatter
  | Missing_field of frontmatter_field
  | Unknown_source of string
  | Bad_revision of string
  | Bad_tags of string
  | Not_one_line of frontmatter_field

let parse_frontmatter content =
  match Frontmatter.read content with
  | Frontmatter.Absent -> Error No_frontmatter
  | Frontmatter.Unclosed -> Error Unclosed_frontmatter
  | Frontmatter.Closed parsed ->
    let open Result.Syntax in
    let lookup field =
      List.assoc_opt (frontmatter_field_key field) parsed.Frontmatter.fields
    in
    (* A scalar that is present but empty says nothing, so it reads as absent.
       [tags] is a list, and [tags: []] is a page with no tags. *)
    let scalar field =
      match lookup field with
      | Some value when not (String.equal value "") -> Ok value
      | Some _ | None -> Error (Missing_field field)
    in
    (* The reader trims a value, so the only [Line] problem left for one that
       is present is a carriage return inside it. *)
    let line field =
      let* value = scalar field in
      match Line.of_string value with
      | Ok line -> Ok line
      | Error Line.Blank -> Error (Missing_field field)
      | Error (Line.Spans_lines | Line.Outer_whitespace) -> Error (Not_one_line field)
    in
    let* title = line Title in
    let* summary = line Summary in
    let* raw_source = scalar Source in
    let* source =
      Option.to_result ~none:(Unknown_source raw_source) (source_of_string_opt raw_source)
    in
    let* author = line Author in
    let* created = line Created in
    let* raw_revision = scalar Revision in
    let* revision =
      match int_of_string_opt raw_revision with
      | Some revision when revision >= 1 -> Ok revision
      | Some _ | None -> Error (Bad_revision raw_revision)
    in
    let* tags =
      match lookup Tags with
      | Some value -> Option.to_result ~none:(Bad_tags value) (Tag.of_line value)
      | None -> Error (Missing_field Tags)
    in
    Ok { title; summary; source; author; created; revision; tags }
;;

(* The raw source is quoted as written: [%S] would escape a non-ASCII value
   into decimal byte codes the reader cannot recognise. *)
let frontmatter_error_to_string = function
  | No_frontmatter -> "no frontmatter"
  | Unclosed_frontmatter -> "frontmatter has no closing ---"
  | Missing_field field -> sprintf "no %s in frontmatter" (frontmatter_field_key field)
  | Unknown_source raw ->
    sprintf "source \"%s\" is not one of: %s" raw (String.concat ", " valid_source_strings)
  | Bad_revision raw -> sprintf "revision \"%s\" is not a whole number from 1" raw
  | Bad_tags raw -> sprintf "tags \"%s\" is not a list of tags" raw
  | Not_one_line field ->
    sprintf "%s in frontmatter is not one line" (frontmatter_field_key field)

(* The one line list, read and search print for a page whose header does
   not read: its filename and the reason. *)
let describe_unreadable path error =
  sprintf "%s (%s)" (Filename.basename path) (frontmatter_error_to_string error)

let render_page (header : frontmatter) ~(updated : Line.t) ~body =
  let body_end = if String.ends_with ~suffix:"\n" body then "" else "\n" in
  sprintf {|---
title: %s
summary: %s
source: %s
author: %s
created: %s
updated: %s
revision: %d
tags: %s
---

%s%s|}
    (header.title :> string)
    (header.summary :> string)
    (source_to_string header.source)
    (header.author :> string)
    (header.created :> string)
    (updated :> string)
    header.revision (Tag.to_line header.tags) body body_end

(* The body as the writer sent it: everything after the header, without the
   blank line [render_page] puts between the two. *)
let page_body content =
  let body = (Frontmatter.parse content).Frontmatter.body in
  if String.starts_with ~prefix:"\n" body
  then String.sub body 1 (String.length body - 1)
  else body
