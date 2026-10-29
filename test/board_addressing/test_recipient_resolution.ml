(* RFC-at-name-resolves-to-declared-recipient, layer 1: which of the names
   written after [@] are recipients.

   Pinned here:
   1. A candidate has the shape of a name. A token with a path separator or a
      dot is prose and never reaches the declaration, because a lookup builds
      file names from the candidate it is given.
   2. [resolve] sorts the answers of the caller's declaration into
      recipients, names the declaration does not know, and a failure. A
      failure ends the asking and leaves no partial result.
   3. The steps the board write path will take on a text, with a stand-in for
      the Keeper registry. The real lookup is not here: this leaf cannot
      import it. *)

open Alcotest
module Candidate = Recipient_resolution.Candidate

let strings = list string

(* A stand-in for the Keeper registry. It folds case as [Keeper_id.of_string]
   does and treats a name two Keepers claim as a failure, as the real alias
   lookup does. A Keeper's own name is one of its aliases, as in the Keeper
   settings. *)
type keeper =
  { name : string;
    aliases : string list }

type failure =
  | Ambiguous_alias of string
  | Unreadable of string

let failure_to_string = function
  | Ambiguous_alias alias -> "ambiguous alias " ^ alias
  | Unreadable name -> "unreadable metadata of " ^ name

let keepers =
  [ { name = "alice"; aliases = [ "alice"; "al" ] };
    { name = "bob"; aliases = [ "bob" ] };
    { name = "carol"; aliases = [ "carol"; "shared" ] };
    { name = "dave"; aliases = [ "dave"; "shared" ] } ]

let registry candidate =
  let wanted = String.lowercase_ascii (Candidate.to_string candidate) in
  match List.filter (fun keeper -> List.mem wanted keeper.aliases) keepers with
  | [] -> Ok None
  | [ keeper ] -> Ok (Some keeper.name)
  | _ :: _ :: _ -> Error (Ambiguous_alias wanted)

(* [declared] with a log of the spellings it was asked, oldest first. *)
let recording declared =
  let asked = ref [] in
  let declared candidate =
    asked := Candidate.to_string candidate :: !asked;
    declared candidate
  in
  declared, fun () -> List.rev !asked

let candidate_exn name =
  match Candidate.of_string name with
  | Some candidate -> candidate
  | None -> failf "%S should be a candidate" name

let resolve_with declared names =
  Recipient_resolution.resolve ~equal:String.equal ~declared
    (List.map candidate_exn names)

let check_resolve ?(declared = registry) label ~recipients ~unresolved names =
  match resolve_with declared names with
  | Ok { Recipient_resolution.recipients = actual; unresolved = actual_unresolved } ->
    check strings (label ^ ": recipients") recipients actual;
    check strings (label ^ ": unresolved") unresolved actual_unresolved
  | Error failure -> failf "%s: the lookup failed: %s" label (failure_to_string failure)

let check_failure ?(declared = registry) label expected names =
  match resolve_with declared names with
  | Ok _ -> failf "%s: expected the lookup to fail" label
  | Error actual ->
    check string label (failure_to_string expected) (failure_to_string actual)

let test_candidate_shape () =
  let shape name = Option.map Candidate.to_string (Candidate.of_string name) in
  let name_or_none = option string in
  check name_or_none "plain name" (Some "alice") (shape "alice");
  check name_or_none "case is preserved" (Some "MiXeD-Agent") (shape "MiXeD-Agent");
  check name_or_none "digits, underscore and hyphen" (Some "a_1-b") (shape "a_1-b");
  check name_or_none "empty" None (shape "");
  check name_or_none "npm scope" None (shape "types/node");
  check name_or_none "parent directory" None (shape "../x");
  check name_or_none "dot" None (shape "a.b");
  check name_or_none "colon" None (shape "a:b");
  check name_or_none "possessive" None (shape "alice's");
  check name_or_none "space" None (shape "a b");
  (* RFC §3.2: an alias with Hangul or a space cannot be written after an [@]. *)
  check name_or_none "Hangul" None (shape "리더");
  check name_or_none "a non-ASCII letter" None (shape "caf\xc3\xa9");
  (* The shape has no length bound. The lookup answers for a name it cannot
     hold, so a long name is a candidate and the lookup says it is not declared. *)
  let long = String.make 300 'a' in
  check name_or_none "a name longer than any Keeper name" (Some long) (shape long)

(* Every string up to length 5 over name characters, a path separator, a dot,
   a backslash, NUL, a colon, a space and the first byte of a multi-byte
   character. Whatever passes is not empty and holds nothing that steps out
   of a directory, and every non-empty string over the name characters passes. *)
let test_candidate_cannot_leave_a_directory () =
  let alphabet = [ 'a'; '-'; '_'; '/'; '.'; '\\'; '\000'; ':'; ' '; '\xc3' ] in
  let path_significant = [ '/'; '.'; '\\'; '\000' ] in
  let checked = ref 0 in
  let accepted = ref 0 in
  let rec extend reversed remaining =
    let name = String.of_seq (List.to_seq (List.rev reversed)) in
    incr checked;
    (match Candidate.of_string name with
     | None -> ()
     | Some candidate ->
       incr accepted;
       check string "the candidate is the name" name (Candidate.to_string candidate);
       if String.equal name "" then fail "an empty name became a candidate";
       String.iter
         (fun character ->
            if List.mem character path_significant
            then failf "%S became a candidate with %C in it" name character)
         name);
    if remaining > 0
    then List.iter (fun character -> extend (character :: reversed) (remaining - 1)) alphabet
  in
  extend [] 5;
  check bool "every name was tried" true (!checked > 100_000);
  (* Strings of length 1 to 5 over the three name characters: 3 + 9 + 27 + 81 + 243. *)
  check int "every name made of name characters was accepted" 363 !accepted

let test_resolve_sorts_the_answers () =
  check_resolve "a Keeper name" ~recipients:[ "alice" ] ~unresolved:[] [ "alice" ];
  check_resolve "an alias" ~recipients:[ "alice" ] ~unresolved:[] [ "al" ];
  check_resolve "a name nobody declared" ~recipients:[] ~unresolved:[ "check" ] [ "check" ];
  check_resolve "no candidates" ~recipients:[] ~unresolved:[] [];
  let long = String.make 300 'a' in
  check_resolve "a name too long for any Keeper is prose" ~recipients:[]
    ~unresolved:[ long ] [ long ]

(* The samples are in neither ascending nor descending order, so a sort cannot
   pass for "the order written". *)
let test_resolve_order () =
  check_resolve "recipients follow the order written" ~recipients:[ "carol"; "alice"; "bob" ]
    ~unresolved:[] [ "carol"; "alice"; "bob" ];
  check_resolve "unresolved sits beside recipients, each in the order written"
    ~recipients:[ "carol"; "alice"; "bob" ] ~unresolved:[ "runtest"; "check"; "lint" ]
    [ "runtest"; "carol"; "check"; "alice"; "lint"; "bob" ]

let test_resolve_merges_duplicates () =
  check_resolve "one name written twice" ~recipients:[ "alice" ] ~unresolved:[]
    [ "alice"; "alice" ];
  check_resolve "a name and its alias" ~recipients:[ "alice" ] ~unresolved:[]
    [ "alice"; "al" ];
  check_resolve "an unknown name written twice" ~recipients:[] ~unresolved:[ "check" ]
    [ "check"; "check" ];
  (* A duplicate between two other names keeps the place of its first mention. *)
  check_resolve "a recipient written again after another one" ~recipients:[ "alice"; "bob" ]
    ~unresolved:[] [ "alice"; "bob"; "al" ];
  check_resolve "an unknown name written again after another one" ~recipients:[]
    ~unresolved:[ "check"; "lint" ] [ "check"; "lint"; "check" ]

let test_resolve_case () =
  check_resolve "the declaration folds case, so two spellings are one recipient"
    ~recipients:[ "alice" ] ~unresolved:[] [ "Alice"; "alice" ];
  check_resolve "unresolved keeps the spelling" ~recipients:[] ~unresolved:[ "Check" ]
    [ "Check" ];
  check_resolve "two spellings of an unknown name are two entries" ~recipients:[]
    ~unresolved:[ "Check"; "check" ] [ "Check"; "check" ]

let test_resolve_asks_once_per_spelling () =
  let declared, asked = recording registry in
  check_resolve ~declared "a mix" ~recipients:[ "alice" ] ~unresolved:[ "check" ]
    [ "alice"; "check"; "alice"; "Alice"; "check" ];
  check strings "each spelling once, in the order written" [ "alice"; "check"; "Alice" ]
    (asked ())

let test_resolve_failure () =
  check_failure "two Keepers claim the alias" (Ambiguous_alias "shared")
    [ "alice"; "shared"; "bob" ];
  let unreadable candidate =
    match Candidate.to_string candidate with
    | "erin" -> Error (Unreadable "erin")
    | _ -> registry candidate
  in
  let declared, asked = recording unreadable in
  check_failure ~declared "an unreadable Keeper is a failure, not prose"
    (Unreadable "erin") [ "alice"; "erin"; "bob"; "check" ];
  check strings "nothing is asked after the failure" [ "alice"; "erin" ] (asked ());
  let declared, asked = recording registry in
  check_resolve ~declared "no candidates ask nothing" ~recipients:[] ~unresolved:[] [];
  check strings "nothing was asked" [] (asked ())

(* What the board write path will do with a text: the grammar finds the names,
   the shape check keeps the ones that can be names, [resolve] asks the
   declaration. *)
let resolve_text declared text =
  let candidates =
    match Board_addressing.parse text with
    | Board_addressing.Raw_targets names ->
      List.filter_map Candidate.of_string names
    | Board_addressing.No_explicit_address
    | Board_addressing.Broadcast_all
    | Board_addressing.Unsupported_broadcast _ -> []
  in
  match Recipient_resolution.resolve ~equal:String.equal ~declared candidates with
  | Ok { Recipient_resolution.recipients; unresolved } -> recipients, unresolved
  | Error failure -> failf "the lookup failed: %s" (failure_to_string failure)

let check_text label ~recipients ~unresolved ~asked text =
  let declared, log = recording registry in
  let actual_recipients, actual_unresolved = resolve_text declared text in
  check strings (label ^ ": recipients") recipients actual_recipients;
  check strings (label ^ ": unresolved") unresolved actual_unresolved;
  check strings (label ^ ": asked") asked (log ())

let test_names_in_a_text () =
  check_text "a dune alias beside a recipient" ~recipients:[ "alice" ]
    ~unresolved:[ "check" ] ~asked:[ "check"; "alice" ]
    "dune build @check, then ask @alice";
  check_text "a name in a code span is not asked" ~recipients:[ "bob" ] ~unresolved:[]
    ~asked:[ "bob" ] "`dune build @check` finished, @bob please look";
  check_text "an npm scope never reaches the declaration" ~recipients:[ "alice" ]
    ~unresolved:[] ~asked:[ "alice" ] "@types/node is outdated, @alice";
  check_text "an email address names no one" ~recipients:[] ~unresolved:[] ~asked:[]
    "mail me at a@alice.com";
  check_text "a person who is not declared" ~recipients:[] ~unresolved:[ "jeong-sik" ]
    ~asked:[ "jeong-sik" ] "@jeong-sik reviewed it";
  check_text "case and an alias" ~recipients:[ "alice" ] ~unresolved:[]
    ~asked:[ "Alice"; "AL"; "alice" ] "@Alice, @AL and @alice"

let () =
  run "recipient_resolution"
    [ ( "candidate",
        [ test_case "shape" `Quick test_candidate_shape;
          test_case "cannot leave a directory" `Quick
            test_candidate_cannot_leave_a_directory ] );
      ( "resolve",
        [ test_case "sorts the answers" `Quick test_resolve_sorts_the_answers;
          test_case "order" `Quick test_resolve_order;
          test_case "merges duplicates" `Quick test_resolve_merges_duplicates;
          test_case "case" `Quick test_resolve_case;
          test_case "asks once per spelling" `Quick test_resolve_asks_once_per_spelling;
          test_case "failure" `Quick test_resolve_failure ] );
      ( "text", [ test_case "names in a text" `Quick test_names_in_a_text ] ) ]
