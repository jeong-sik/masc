(* RFC-0393: Keeper_identity.Keeper_id structural self-identity.
   (Distinct from test_keeper_id.ml, which covers the registry-level
   Keeper_id.Uid/Trace_id runtime identifier wrappers.)

   The contract pinned here replaces the RFC-0232 canonicalizer goldens:
   an author id is its own trimmed, case-folded string. No wrapper or
   prefix spelling denotes a keeper any more — [keeper-alice-agent] and
   [alice] are two different identities, and whether a string names a
   keeper is a registry/meta lookup at the caller, never a property of
   the string's shape. *)

open Alcotest

module Kid = Masc.Keeper_identity.Keeper_id
module MS = Masc.Keeper_world_observation_message_scope

let id_str value =
  match Kid.of_string value with
  | Some id -> Some (Kid.to_string id)
  | None -> None

(* ── Goldens ── *)

let test_of_string_goldens () =
  check (option string) "bare name" (Some "alice") (id_str "alice");
  check (option string) "wrapper spelling is its own identity"
    (Some "keeper-alice-agent")
    (id_str "keeper-alice-agent");
  check (option string) "underscore wrapper is its own identity"
    (Some "keeper_alice_agent")
    (id_str "keeper_alice_agent");
  check (option string) "keeper- prefix form is its own identity"
    (Some "keeper-alice")
    (id_str "keeper-alice");
  check (option string) "case folded" (Some "keeper-dreamer-agent")
    (id_str "Keeper-Dreamer-Agent");
  check (option string) "whitespace trimmed" (Some "alice") (id_str "  alice  ");
  check (option string) "human author keeps its folded form" (Some "vincent")
    (id_str "Vincent");
  check (option string) "@-form keeps its folded form" (Some "@alice")
    (id_str "@alice");
  check (option string) "empty is None" None (id_str "");
  check (option string) "whitespace-only is None" None (id_str "   ")

let test_of_string_idempotent_on_goldens () =
  List.iter
    (fun input ->
      match Kid.of_string input with
      | None -> ()
      | Some id ->
        check (option string)
          (Printf.sprintf "of_string idempotent for %S" input)
          (Some (Kid.to_string id))
          (id_str (Kid.to_string id)))
    [ "alice"; "keeper-alice-agent"; "keeper_alice_agent"; "keeper-alice"
    ; "Vincent"; "@alice"
    ]

(* ── Self identity ── *)

let is_self ~name author =
  let self_ids = List.filter_map Kid.of_string [ name ] in
  match Kid.of_string author with
  | None -> false
  | Some author_id -> List.exists (Kid.equal author_id) self_ids

let test_self_is_name_only () =
  check bool "the name itself is self" true (is_self ~name:"alice" "alice");
  check bool "case-folded name is self" true (is_self ~name:"alice" "ALICE");
  check bool "trimmed name is self" true (is_self ~name:"alice" "  alice ");
  check bool "the wrapper spelling is not self" false
    (is_self ~name:"alice" "keeper-alice-agent");
  check bool "the prefix form is not self" false
    (is_self ~name:"alice" "keeper-alice");
  check bool "a foreign author is not self" false (is_self ~name:"alice" "vincent");
  check bool "empty is not self" false (is_self ~name:"alice" "")

let test_message_scope_surface () =
  let ids = List.filter_map Kid.of_string [ "alice" ] in
  check bool "the keeper name is self over the MS surface" true
    (MS.is_self_author ~self_ids:ids "alice");
  check bool "the wrapper spelling is a foreign author" false
    (MS.is_self_author ~self_ids:ids "keeper-alice-agent");
  check bool "a foreign author is not self" false
    (MS.is_self_author ~self_ids:ids "vincent")

let () =
  run "keeper_identity_id"
    [
      ( "of_string",
        [
          test_case "goldens" `Quick test_of_string_goldens;
          test_case "idempotent" `Quick test_of_string_idempotent_on_goldens;
        ] );
      ( "self",
        [
          test_case "self is the name only" `Quick test_self_is_name_only;
          test_case "message scope" `Quick test_message_scope_surface;
        ] );
    ]
