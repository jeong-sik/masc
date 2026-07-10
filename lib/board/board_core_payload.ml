module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Board_core_payload — Post payload normalization.

    Handles title derivation, metadata shape validation, and content
    normalization before persistence.

    @since God file decomposition — extracted from board_core.ml *)

type meta_parse_error = Meta_not_assoc of Yojson.Safe.t

let normalize_meta_json (meta_json : Yojson.Safe.t option) :
    (Yojson.Safe.t option, meta_parse_error) Stdlib.Result.t =
  (* Parse-don't-validate: a non-[`Assoc] meta payload is a malformed
     submission, not "meta absent". The pre-2026-05-15 implementation
     silently coerced [Some (`Int _)] / [Some (`String _)] / etc. to
     [fields = []], absorbing malformed JSON into an empty meta object.
     We now surface those payloads as a typed [Meta_not_assoc] error so
     callers must decide explicitly (reject, log, repair) instead of
     letting structural drift reach [board_posts.jsonl]. *)
  let parsed_fields =
    match meta_json with
    | None -> Stdlib.Result.Ok []
    | Some (`Assoc assoc) -> Stdlib.Result.Ok assoc
    | Some other -> Stdlib.Result.Error (Meta_not_assoc other)
  in
  match parsed_fields with
  | Stdlib.Result.Error _ as err -> err
  | Stdlib.Result.Ok [] -> Stdlib.Result.Ok None
  | Stdlib.Result.Ok fields -> Stdlib.Result.Ok (Some (`Assoc fields))

let derive_post_title (body : string) =
  let first_line =
    body
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.find_opt (fun line -> not (String.equal line ""))
    |> Option.value ~default:"Untitled post"
  in
  (* UTF-8-safe truncation: byte-based String.sub used to split multi-byte
     characters, producing invalid UTF-8 lines in board_posts.jsonl
     (Issue #7690). utf8_safe returns a variant so future callers can
     observe/meter truncation events; here we just materialize. *)
  String_util.utf8_safe ~max_bytes:80 ~suffix:"..." first_line
  |> String_util.to_string

let normalize_post_payload ~content ?title ?body ~post_kind ?meta_json () =
  let raw_body = Option.value body ~default:content in
  let normalized_body = String.trim raw_body in
  let normalized_title =
    match title with
    | Some value ->
        let trimmed = String.trim value in
        if not (String.equal trimmed "") then trimmed
        else derive_post_title normalized_body
    | None -> derive_post_title normalized_body
  in
  match normalize_meta_json meta_json with
  | Stdlib.Result.Error _ as err -> err
  | Stdlib.Result.Ok merged_meta ->
      Stdlib.Result.Ok
        (normalized_title, normalized_body, post_kind, merged_meta)
