(** The two hand-kept task_status lists, compared.

    [types_core.ml] documents that only one axis is left unguarded:

      The remaining hand-coded axis is the witness list's length —
      [test_types.ml] pins it at 6, so adding a constructor without adding a
      witness here breaks that test.

    There is no test_types.ml. And a length pin would not have caught the
    mistake it describes: adding a constructor bumps nothing until a witness
    is added, so the count simply stays where it was.

    What is actually at risk is that two lists carry the same vocabulary and
    neither forces the other. [task_status_to_string] is exhaustive, so a new
    constructor must be given a string. Nothing makes anyone add it to
    [task_status_schema_witnesses], and nothing makes anyone give it an arm in
    [task_status_of_yojson]. The witnesses become
    [valid_task_status_strings], which is the enum
    [tool_shard_types_schemas_taskboard] publishes — so a forgotten witness
    tells a model the status is not a legal value while the parser happily
    accepts it.

    This reads the parser's arms out of the source and requires every status
    it accepts to be one the schema advertises, and every advertised status to
    be one the parser recognises. *)

open Alcotest

module D = Masc_domain

(* The runtest action runs in the test directory; the stanza stages the source
   beside it under the build root. *)
let types_core_path = "../lib/types/types_core.ml"

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

(* Index of [needle] in [haystack] at or after [from], if present. *)
let find_from haystack needle from =
  let hn = String.length haystack and nn = String.length needle in
  let rec go i =
    if i + nn > hn then None
    else if String.sub haystack i nn = needle then Some i
    else go (i + 1)
  in
  go from
;;

(* Status tags [task_status_of_yojson] dispatches on: the quoted arms between
   its definition and its unknown-status fallback. *)
let parser_status_tags () =
  let source = read_file types_core_path in
  match find_from source "let task_status_of_yojson" 0 with
  | None -> []
  | Some start ->
    let stop =
      match find_from source "Unknown task status" start with
      | Some stop -> stop
      | None -> String.length source
    in
    String.sub source start (stop - start)
    |> String.split_on_char '\n'
    |> List.concat_map (fun line ->
      let trimmed = String.trim line in
      (* Arms may be or-patterns: | "todo" | "deferred" -> ... Take every
         quoted tag on the line, not the first. *)
      if String.length trimmed > 4 && String.starts_with ~prefix:"| \"" trimmed
      then (
        let rec quoted acc i =
          match String.index_from_opt trimmed i '"' with
          | None -> List.rev acc
          | Some opening ->
            (match String.index_from_opt trimmed (opening + 1) '"' with
             | None -> List.rev acc
             | Some closing ->
               quoted
                 (String.sub trimmed (opening + 1) (closing - opening - 1) :: acc)
                 (closing + 1))
        in
        quoted [] 0)
      else [])
;;

(* A guard that extracts nothing passes for the wrong reason. *)
let test_extraction_finds_the_parser_arms () =
  let tags = parser_status_tags () in
  check bool
    (Printf.sprintf "%s yields parser arms" types_core_path)
    true
    (tags <> []);
  check bool "todo is among them" true (List.mem "todo" tags)
;;

let test_every_parsed_status_is_advertised () =
  List.iter
    (fun tag ->
      check bool
        (Printf.sprintf "parser tag %S is in valid_task_status_strings" tag)
        true
        (List.mem tag D.valid_task_status_strings))
    (parser_status_tags ())
;;

(* The reverse: a status the schema offers that the parser rejects outright
   would be advertised and unusable. Field-level errors are fine here -- the
   probe omits payload fields on purpose; only the unknown-tag branch matters. *)
let test_every_advertised_status_is_recognised () =
  List.iter
    (fun status ->
      let probe = `Assoc [ ("status", `String status) ] in
      match D.task_status_of_yojson probe with
      | Ok _ -> ()
      | Error message ->
        check bool
          (Printf.sprintf "%S is a status the parser knows (%s)" status message)
          false
          (String.length message >= 19 && String.sub message 0 19 = "Unknown task status"))
    D.valid_task_status_strings
;;

let test_witnesses_and_parser_agree_in_size () =
  let tags = List.sort_uniq String.compare (parser_status_tags ()) in
  let advertised = List.sort_uniq String.compare D.valid_task_status_strings in
  check (list string) "parser tags equal the advertised statuses" advertised tags
;;

let () =
  Alcotest.run
    "Task status vocabulary"
    [ ( "extraction"
      , [ test_case "finds the parser arms" `Quick test_extraction_finds_the_parser_arms ] )
    ; ( "agreement"
      , [ test_case "every parsed status is advertised" `Quick
            test_every_parsed_status_is_advertised
        ; test_case "every advertised status is recognised" `Quick
            test_every_advertised_status_is_recognised
        ; test_case "the two sets are equal" `Quick test_witnesses_and_parser_agree_in_size
        ] )
    ]
;;
