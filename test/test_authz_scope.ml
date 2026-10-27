(* Pure checks for the authorization id and scope types: which strings become
   ids, and the intersection algebra that every filter of design 6.2 relies on.
   No files, clock, or network. *)

open Authz_types

module Test_id = Authz_id.Make ()

let id_error_to_string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too_long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid_byte@%d" index
  | Authz_id.Path_segment -> "path_segment"
;;

let id_outcome raw =
  match Test_id.of_string raw with
  | Ok id -> "ok:" ^ Test_id.to_string id
  | Error error -> id_error_to_string error
;;

(* Letters, digits, and . _ : - are the alphabet. Everything else is rejected at
   the offset of the first offending byte, and so are . and .. alone. The
   runtime ids the repository already uses (codex.gpt-5.4, claude_code.sonnet,
   codex:test) all fit. *)
let id_cases =
  [ "plain", "alice", "ok:alice"
  ; "every kind of allowed character", "Az09._:-", "ok:Az09._:-"
  ; "existing runtime id", "anthropic.claude-opus-5-5", "ok:anthropic.claude-opus-5-5"
  ; "dots inside are fine", "a..b", "ok:a..b"
  ; "empty", "", "empty"
  ; "as long as allowed", String.make Authz_id.max_length 'a', "ok:" ^ String.make Authz_id.max_length 'a'
  ; "one byte too long", String.make (Authz_id.max_length + 1) 'a', "too_long"
  ; "one dot", ".", "path_segment"
  ; "two dots", "..", "path_segment"
  ; "slash", "a/b", "invalid_byte@1"
  ; "traversal", "../x", "invalid_byte@2"
  ; "backslash", "a\\b", "invalid_byte@1"
  ; "at sign", "a@b", "invalid_byte@1"
  ; "visible punctuation outside the alphabet", "a!", "invalid_byte@1"
  ; "leading space", " a", "invalid_byte@0"
  ; "inner space", "a b", "invalid_byte@1"
  ; "newline", "a\nb", "invalid_byte@1"
  ; "tab", "a\tb", "invalid_byte@1"
  ; "nul", "ab\000", "invalid_byte@2"
  ; "delete", "abc\127", "invalid_byte@3"
  ; "non-ascii", "caf\xc3\xa9", "invalid_byte@3"
  ]
;;

let id_tests =
  List.map
    (fun (name, raw, expected) ->
      Alcotest.test_case name `Quick (fun () ->
        Alcotest.(check string) name expected (id_outcome raw)))
    id_cases
;;

(* Two ids of different kinds never compare through a shared type: that is a
   compile-time property, so the runtime check is only that equal strings give
   equal ids of one kind. *)
let id_equality () =
  let make raw =
    match Test_id.of_string raw with
    | Ok id -> id
    | Error error -> Alcotest.failf "id %S rejected: %s" raw (id_error_to_string error)
  in
  Alcotest.(check bool) "same string" true (Test_id.equal (make "a") (make "a"));
  Alcotest.(check bool) "different string" false (Test_id.equal (make "a") (make "b"));
  Alcotest.(check bool)
    "set membership follows equality"
    true
    (Test_id.Set.mem (make "a") (Test_id.Set.of_list [ make "a"; make "b" ]))
;;

module Int_element = struct
  type t = int

  module Set = Set.Make (Int)
end

module Scope = Authz_scope.Make (Int_element)

let universe = [ 1; 2; 3 ]

let rec subsets = function
  | [] -> [ [] ]
  | x :: rest ->
    let without = subsets rest in
    without @ List.map (fun subset -> x :: subset) without
;;

(* Every scope over [universe]: Empty, All, and Only for each non-empty subset.
   The empty subset goes through [only] and comes back as Empty. *)
let scopes =
  Scope.empty
  :: Scope.all
  :: List.map (fun subset -> Scope.only (Int_element.Set.of_list subset)) (subsets universe)
;;

let show scope =
  match scope with
  | Scope.Empty -> "Empty"
  | Scope.All -> "All"
  | Scope.Only set ->
    "Only{" ^ String.concat "," (List.map string_of_int (Int_element.Set.elements set)) ^ "}"
;;

let scope_testable = Alcotest.testable (fun fmt s -> Format.pp_print_string fmt (show s)) Scope.equal

let for_all_pairs check =
  List.iter (fun a -> List.iter (fun b -> check a b) scopes) scopes
;;

let for_all_triples check =
  List.iter (fun a -> for_all_pairs (fun b c -> check a b c)) scopes
;;

let scope_laws () =
  for_all_pairs (fun a b ->
    Alcotest.check scope_testable "commutative" (Scope.inter a b) (Scope.inter b a));
  for_all_triples (fun a b c ->
    Alcotest.check
      scope_testable
      "associative"
      (Scope.inter (Scope.inter a b) c)
      (Scope.inter a (Scope.inter b c)));
  List.iter
    (fun a ->
      Alcotest.check scope_testable "idempotent" a (Scope.inter a a);
      Alcotest.check scope_testable "All is the identity" a (Scope.inter a Scope.all);
      Alcotest.check scope_testable "Empty absorbs" Scope.empty (Scope.inter a Scope.empty))
    scopes
;;

(* The scope of an intersection allows exactly what both sides allow. *)
let intersection_membership () =
  for_all_pairs (fun a b ->
    List.iter
      (fun x ->
        Alcotest.(check bool)
          (Printf.sprintf "%s & %s on %d" (show a) (show b) x)
          (Scope.mem x a && Scope.mem x b)
          (Scope.mem x (Scope.inter a b)))
      universe)
;;

let empty_set_is_empty_scope () =
  Alcotest.check scope_testable "only {} is Empty" Scope.empty (Scope.only Int_element.Set.empty);
  Alcotest.(check bool)
    "Empty allows nothing"
    false
    (List.exists (fun x -> Scope.mem x Scope.empty) universe)
;;

let uncovered_is_what_mem_rejects () =
  List.iter
    (fun scope ->
      List.iter
        (fun subset ->
          let set = Int_element.Set.of_list subset in
          let expected = Int_element.Set.filter (fun x -> not (Scope.mem x scope)) set in
          Alcotest.(check (list int))
            (Printf.sprintf "%s uncovers" (show scope))
            (Int_element.Set.elements expected)
            (Int_element.Set.elements (Scope.uncovered scope set)))
        (subsets universe))
    scopes
;;

let runtime_id raw =
  match Runtime_id.of_string raw with
  | Ok id -> id
  | Error error -> Alcotest.failf "id %S rejected: %s" raw (id_error_to_string error)
;;

let authorization_scope_is_dimensionwise () =
  let rt = runtime_id "rt-1" in
  let narrow =
    { Authorization_scope.runtimes = Runtime_scope.only (Runtime_id.Set.singleton rt)
    ; channels = Channel_scope.only (Channel.Set.of_list [ Channel.Direct; Channel.Retry ])
    ; allowed_effects = Effect_scope.all
    }
  in
  let other =
    { Authorization_scope.runtimes = Runtime_scope.all
    ; channels = Channel_scope.only (Channel.Set.singleton Channel.Retry)
    ; allowed_effects = Effect_scope.only (Effect.Set.singleton Effect.Use_tool)
    }
  in
  let both = Authorization_scope.inter narrow other in
  Alcotest.(check bool) "runtime kept" true (Runtime_scope.mem rt both.runtimes);
  Alcotest.(check bool) "channel narrowed" false (Channel_scope.mem Channel.Direct both.channels);
  Alcotest.(check bool) "channel shared" true (Channel_scope.mem Channel.Retry both.channels);
  Alcotest.(check bool) "effect narrowed" false (Effect_scope.mem Effect.Invoke_model both.allowed_effects);
  Alcotest.(check bool) "effect shared" true (Effect_scope.mem Effect.Use_tool both.allowed_effects);
  Alcotest.(check bool)
    "All is the identity"
    true
    (Channel_scope.equal narrow.channels (Authorization_scope.inter narrow Authorization_scope.all).channels)
;;

let not_pat_limits_nothing () =
  let all = Pat_binding.scope Pat_binding.Not_pat in
  Alcotest.(check bool) "runtimes" true (Runtime_scope.equal all.runtimes Runtime_scope.all);
  Alcotest.(check bool) "channels" true (Channel_scope.equal all.channels Channel_scope.all);
  Alcotest.(check bool) "effects" true (Effect_scope.equal all.allowed_effects Effect_scope.all)
;;

let neutral_direct_is_direct_only () =
  let neutral = Delegate_policy.neutral_direct in
  Alcotest.(check bool) "every runtime" true (Runtime_scope.equal neutral.runtimes Runtime_scope.all);
  Alcotest.(check bool) "every effect" true (Effect_scope.equal neutral.allowed_effects Effect_scope.all);
  Alcotest.(check bool) "direct" true (Channel_scope.mem Channel.Direct neutral.channels);
  Alcotest.(check bool) "nothing but direct" false (Channel_scope.mem Channel.Delegate neutral.channels)
;;

let effect_request_is_never_empty () =
  let single = Effect_request.to_set (Effect_request.make Effect.Read_state []) in
  Alcotest.(check int) "one effect" 1 (Effect.Set.cardinal single);
  let repeated =
    Effect_request.to_set (Effect_request.make Effect.Use_tool [ Effect.Use_tool; Effect.Read_state ])
  in
  Alcotest.(check int) "duplicates collapse" 2 (Effect.Set.cardinal repeated)
;;

(* The six effects that need a named PAT scope, and the four that do not. Every
   effect is placed by an exhaustive match in the library, so a new effect
   cannot reach this question unanswered. *)
let management_effects_are_the_state_changing_ones () =
  let expected =
    Effect.
      [ Read_state, false
      ; Invoke_model, false
      ; Use_tool, false
      ; Manage_own_provider, true
      ; Manage_own_runtime, true
      ; Manage_own_grant, true
      ; Manage_own_keeper, true
      ; Manage_machine_shared, true
      ; Admin_disable_block, true
      ; Read_audit_metadata, false
      ]
  in
  List.iter
    (fun (kind, management) ->
      Alcotest.(check bool) (Effect.to_string kind) management (Effect.is_management kind))
    expected
;;

let () =
  Alcotest.run
    "authz_scope"
    [ "id", id_tests @ [ Alcotest.test_case "equality" `Quick id_equality ]
    ; ( "scope"
      , [ Alcotest.test_case "laws" `Quick scope_laws
        ; Alcotest.test_case "intersection membership" `Quick intersection_membership
        ; Alcotest.test_case "empty set is Empty" `Quick empty_set_is_empty_scope
        ; Alcotest.test_case "uncovered" `Quick uncovered_is_what_mem_rejects
        ] )
    ; ( "authorization_scope"
      , [ Alcotest.test_case "dimension-wise" `Quick authorization_scope_is_dimensionwise
        ; Alcotest.test_case "Not_pat" `Quick not_pat_limits_nothing
        ; Alcotest.test_case "neutral Direct" `Quick neutral_direct_is_direct_only
        ; Alcotest.test_case "Effect_request" `Quick effect_request_is_never_empty
        ; Alcotest.test_case "management effects" `Quick management_effects_are_the_state_changing_ones
        ] )
    ]
;;
