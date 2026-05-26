(** Pin every [Cascade_routing_policy.default_routing_policies] entry to
    a defined [tier-groups.X] section in the canonical phonebook fixture.

    Catches three classes of drift:
    - typo'd policy strings ("cross_verify" vs "cross-verify")
    - removal of a tier-group from the fixture while a policy still
      references it
    - addition of a new policy entry without adding the fixture section

    Out of scope: production [config/cascade.toml] currently has no
    phonebook sections at all (RFC-0181 §9 — implementation deferred).
    A separate gate would be needed to assert that. *)

open Alcotest
open Masc_mcp.Cascade_routing_policy

let fixture_path = "test/fixtures/cascade-phonebook.toml"

(* Read [tier-groups.*] table keys directly via otoml.

   We intentionally bypass [Cascade_phonebook_parser.parse_phonebook]
   here. The parser performs full cross-reference validation
   (providers ↔ models ↔ tier-groups) and currently rejects the
   fixture due to in-flight RFC-0177 vendor-substitution desync —
   unrelated to the policy/tier-group binding we are guarding here.

   This test asks one question: do the tier-group string literals in
   [default_routing_policies] match section names actually present in
   the canonical fixture? Section-key presence is sufficient signal. *)
let load_fixture_tier_group_names () : string list =
  let toml = Otoml.Parser.from_file fixture_path in
  match Otoml.find_opt toml Fun.id [ "tier-groups" ] with
  | Some tg_tbl ->
    (match Otoml.get_table tg_tbl with
     | exception Otoml.Type_error _ -> []
     | entries -> List.map fst entries)
  | None -> []

let test_all_policies_target_existing_tier_groups () =
  let defined = load_fixture_tier_group_names () in
  List.iter
    (fun (p : task_routing_policy) ->
      if not (List.mem p.primary_tier_group defined)
      then
        Alcotest.failf
          "default_routing_policies entry for %s references tier-group %S, \
           but no [tier-groups.%s] section in %s (defined: %s)"
          (task_use_to_string p.task)
          p.primary_tier_group
          p.primary_tier_group
          fixture_path
          (String.concat ", " defined))
    default_routing_policies

let test_fixture_has_at_least_one_tier_group () =
  let defined = load_fixture_tier_group_names () in
  if defined = []
  then
    Alcotest.failf
      "fixture %s parsed but yielded zero tier-groups — fixture corrupted"
      fixture_path

let () =
  Alcotest.run
    "cascade_routing_policy_targets_exist"
    [ ( "intent_to_fixture"
      , [ test_case
            "fixture has tier-groups"
            `Quick
            test_fixture_has_at_least_one_tier_group
        ; test_case
            "every default_routing_policies entry targets a defined tier-group"
            `Quick
            test_all_policies_target_existing_tier_groups
        ] )
    ]
