(** The dashboard's persona lookup keys off the keeper name it recovers from an
    agent name, and it used to recover it with its own affix arithmetic:
    [String.sub s 7] for a "keeper-" prefix and [String.sub s (len - 6) 6] for
    an "-agent" suffix. Keeper_identity enumerates four accepted spellings, and
    its own comment records the failure mode of knowing a spelling in one place
    and not another — an alias that no keeper name can be derived from.

    So these cases are less about the four strings than about the two functions
    agreeing: [agrees_with_the_canonical_parser] fails the moment the dashboard
    grows a second opinion. *)

module Helpers = Dashboard_execution_helpers
module Identity = Masc.Keeper_identity
open Alcotest

let spellings =
  [ "keeper-sangsu-agent"; "keeper_sangsu_agent"; "keeper-sangsu_agent"
  ; "keeper_sangsu-agent"
  ]
;;

let test_every_spelling_reaches_the_same_persona () =
  List.iter
    (fun agent_name ->
      check string agent_name "sangsu" (Helpers.extract_persona_name agent_name))
    spellings
;;

(* The old arithmetic knew only the first spelling; the other three kept their
   affixes and sent the persona lookup after a directory named for the alias. *)
let test_mixed_spellings_are_not_left_with_affixes () =
  List.iter
    (fun agent_name ->
      let persona = Helpers.extract_persona_name agent_name in
      check bool (agent_name ^ ": no keeper prefix") false
        (String.starts_with ~prefix:"keeper-" persona
         || String.starts_with ~prefix:"keeper_" persona);
      check bool (agent_name ^ ": no agent suffix") false
        (String.ends_with ~suffix:"-agent" persona
         || String.ends_with ~suffix:"_agent" persona))
    spellings
;;

(* A name that is not a keeper alias is returned unchanged — the persona lookup
   then searches for it verbatim, which is the documented behaviour. *)
let test_non_alias_passes_through () =
  List.iter
    (fun name -> check string name name (Helpers.extract_persona_name name))
    [ "claude-agent-abc"; "claude-swift-fox"; "sangsu"; "" ]
;;

let test_agrees_with_the_canonical_parser () =
  List.iter
    (fun name ->
      let want =
        match Identity.keeper_name_of_agent_alias name with
        | Some keeper_name -> keeper_name
        | None -> name
      in
      check string name want (Helpers.extract_persona_name name))
    (spellings @ [ "claude-agent-abc"; "keeper-x-agent"; "keeper_"; "-agent"; "" ])
;;

let () =
  Alcotest.run
    "Dashboard persona name"
    [ ( "extract_persona_name"
      , [ test_case "every spelling reaches the same persona" `Quick
            test_every_spelling_reaches_the_same_persona
        ; test_case "mixed spellings are not left with affixes" `Quick
            test_mixed_spellings_are_not_left_with_affixes
        ; test_case "a non-alias passes through" `Quick test_non_alias_passes_through
        ; test_case "agrees with the canonical parser" `Quick
            test_agrees_with_the_canonical_parser
        ] )
    ]
;;
