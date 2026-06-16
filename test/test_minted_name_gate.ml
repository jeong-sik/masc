(** Behavioral guard for the auth-fallback gate after deleting
    [Client_name_kind].

    The deleted classifier decided transience with
    [is_transient name =
       String.starts_with name ~prefix:"agent-"
       || Nickname.is_dictionary_generated_nickname name]
    re-derived from the name string at read time. The replacement,
    [Mcp_server_eio_caller_identity.minted_name_is_transient], is a total
    match over the carried origin [minted_name].

    This test pins the new total match to the OLD truth table per
    constructor, including a real dictionary nickname produced by
    [Nickname], so a future edit to the gate that diverges from the
    laundering-era behavior fails here rather than silently in auth. *)

open Alcotest

module Caller = Masc.Mcp_server_eio_caller_identity
module Nickname = Nickname

(* The exact predicate the deleted [Client_name_kind.is_transient]
   computed on a bare string. Kept here ONLY as the oracle this test
   checks the typed gate against — it is not used in production. *)
let old_is_transient name =
  String.starts_with name ~prefix:"agent-"
  || Nickname.is_dictionary_generated_nickname name

let check_external_arm_matches_old name =
  (* [Resolved_external] is the only arm that still consults the string:
     it must reproduce the old [is_transient] exactly. *)
  check bool
    (Printf.sprintf "Resolved_external %S matches old is_transient" name)
    (old_is_transient name)
    (Caller.minted_name_is_transient (Caller.Resolved_external name))

let test_stable_never_transient () =
  (* [Stable] is produced exactly when the caller supplied [_agent_name];
     the old gate short-circuited on [not has_explicit_agent_name], so it
     was never transient regardless of the string. *)
  List.iter
    (fun name ->
      check bool
        (Printf.sprintf "Stable %S is never transient" name)
        false
        (Caller.minted_name_is_transient (Caller.Stable name)))
    [ "gemini"; "agent-xxxx"; "swift-fox"; "role-swift-fox"; "" ]

let test_ephemeral_always_transient () =
  (* [Ephemeral] is the system-minted origin (own ["agent-…"] fallback or
     a [`System_fallback] identity). The old gate reached these via the
     ["agent-"] prefix and always fired. *)
  List.iter
    (fun name ->
      check bool
        (Printf.sprintf "Ephemeral %S is always transient" name)
        true
        (Caller.minted_name_is_transient (Caller.Ephemeral name)))
    [ "agent-abcd1234"; "agent-anon"; "agent-deadbeef" ]

let test_resolved_external_reproduces_old () =
  (* External names: the gate must equal the old [is_transient] string
     test (this is the option-(b) reserved-prefix arm — the substring is
     one arm of a total match, not a standalone classifier). *)
  (* Non-transient externals. *)
  check_external_arm_matches_old "alice";
  check_external_arm_matches_old "gemini";
  check_external_arm_matches_old "keeper-sangsu-agent";
  check_external_arm_matches_old "admin-board-keeper";
  (* Reserved-prefix edge: a tool-domain agent_name spelling "agent-…"
     stays transient under the old rule and under the new arm. *)
  check_external_arm_matches_old "agent-foo";
  check bool "Resolved_external agent-foo is transient (reserved prefix)" true
    (Caller.minted_name_is_transient (Caller.Resolved_external "agent-foo"));
  (* Dictionary nickname: hardcoded sample drawn from the word lists. *)
  check_external_arm_matches_old "role-swift-fox";
  check bool "Resolved_external dict nickname is transient" true
    (Caller.minted_name_is_transient (Caller.Resolved_external "role-swift-fox"))

let test_resolved_external_real_nickname () =
  (* A nickname actually produced by [Nickname.generate] / [generate_unique]
     must classify as transient via the [Resolved_external] arm, matching
     the old [is_dictionary_generated_nickname] path. *)
  let nick = Nickname.generate "role" in
  check bool
    (Printf.sprintf "Nickname.generate %S is a dictionary nickname" nick)
    true
    (Nickname.is_dictionary_generated_nickname nick);
  check_external_arm_matches_old nick;
  check bool
    (Printf.sprintf "Resolved_external %S (generated) is transient" nick)
    true
    (Caller.minted_name_is_transient (Caller.Resolved_external nick));
  let nick_u = Nickname.generate_unique "role" in
  check bool
    (Printf.sprintf "Nickname.generate_unique %S is a dictionary nickname" nick_u)
    true
    (Nickname.is_dictionary_generated_nickname nick_u);
  check_external_arm_matches_old nick_u

let test_to_string_total () =
  check string "Stable lowers to its string" "x"
    (Caller.minted_name_to_string (Caller.Stable "x"));
  check string "Ephemeral lowers to its string" "y"
    (Caller.minted_name_to_string (Caller.Ephemeral "y"));
  check string "Resolved_external lowers to its string" "z"
    (Caller.minted_name_to_string (Caller.Resolved_external "z"))

let () =
  run "minted_name_gate"
    [ ( "gate truth table"
      , [ test_case "Stable never transient" `Quick test_stable_never_transient
        ; test_case "Ephemeral always transient" `Quick
            test_ephemeral_always_transient
        ; test_case "Resolved_external reproduces old is_transient" `Quick
            test_resolved_external_reproduces_old
        ; test_case "Resolved_external real Nickname sample" `Quick
            test_resolved_external_real_nickname
        ; test_case "minted_name_to_string total" `Quick test_to_string_total
        ] )
    ]
