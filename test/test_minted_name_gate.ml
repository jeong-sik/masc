(** Behavioral guard for the auth-fallback gate after deleting
    [Client_name_kind].

    The replacement,
    [Mcp_server_eio_caller_identity.minted_name_is_transient], is a total
    match over the carried origin [minted_name]. Only typed [Ephemeral]
    values are token-rewrite candidates. Caller-supplied or cached
    [Resolved_external] names must not be reclassified by string shape,
    because generated-looking explicit aliases are still explicit caller
    identities. *)

open Alcotest

module Caller = Masc.Mcp_server_eio_caller_identity
module Nickname = Nickname

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

let test_resolved_external_never_transient_by_shape () =
  List.iter
    (fun name ->
      check bool
        (Printf.sprintf "Resolved_external %S is not shape-transient" name)
        false
        (Caller.minted_name_is_transient (Caller.Resolved_external name)))
    [
      "alice";
      "gemini";
      "keeper-sangsu-agent";
      "admin-board-keeper";
      "agent-foo";
      "role-swift-fox";
    ]

let test_resolved_external_real_nickname () =
  (* A nickname actually produced by [Nickname.generate] / [generate_unique]
     remains non-transient when it arrives as a caller-supplied external
     identity. *)
  let nick = Nickname.generate "role" in
  check bool
    (Printf.sprintf "Nickname.generate %S is a dictionary nickname" nick)
    true
    (Nickname.is_dictionary_generated_nickname nick);
  check bool
    (Printf.sprintf "Resolved_external %S (generated) is not transient" nick)
    false
    (Caller.minted_name_is_transient (Caller.Resolved_external nick));
  let nick_u = Nickname.generate_unique "role" in
  check bool
    (Printf.sprintf "Nickname.generate_unique %S is a dictionary nickname" nick_u)
    true
    (Nickname.is_dictionary_generated_nickname nick_u);
  check bool
    (Printf.sprintf "Resolved_external %S (generated unique) is not transient" nick_u)
    false
    (Caller.minted_name_is_transient (Caller.Resolved_external nick_u))

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
        ; test_case "Resolved_external ignores string shape" `Quick
            test_resolved_external_never_transient_by_shape
        ; test_case "Resolved_external real Nickname sample" `Quick
            test_resolved_external_real_nickname
        ; test_case "minted_name_to_string total" `Quick test_to_string_total
        ] )
    ]
