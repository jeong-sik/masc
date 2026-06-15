(* RFC-0232 P3: Keeper_identity.Keeper_id structural self-identity.
   (Distinct from test_keeper_id.ml, which covers the registry-level
   Keeper_id.Uid/Trace_id runtime identifier wrappers.)

   Two things are pinned here:

   1. [Keeper_id.of_string] canonicalization goldens — every accepted
      identity shape (bare name, the four [keeper-X-agent] wrapper
      separator variants, [keeper-] prefix form) mints the same
      canonical id, and unrecognized inputs keep their case-folded raw
      form.

   2. Equivalence with the legacy token-set intersection that
      [is_self_author] used before this change.  The oracle below is a
      verbatim replica of the deleted [identity_tokens_of_value] /
      set-intersection algorithm, run against the same
      [Keeper_identity] canonicalizers.  The matrix crosses author
      forms with keeper identities; old and new must agree everywhere.
      (Mixed-case wrapper inputs are the one documented widening: the
      old code matched them only via the raw-token fallback, the new
      code canonicalizes them — goldens cover it.) *)

open Alcotest

module KI = Masc.Keeper_identity
module Kid = Masc.Keeper_identity.Keeper_id
module MS = Masc.Keeper_world_observation_message_scope

let id_str value =
  match Kid.of_string value with
  | Some id -> Some (Kid.to_string id)
  | None -> None

(* ── Legacy oracle (verbatim replica of the deleted algorithm) ── *)

let normalized_identity_token value =
  let trimmed = String.lowercase_ascii (String.trim value) in
  if trimmed = "" then None else Some trimmed

let legacy_tokens_of_value value =
  let trimmed = String.trim value in
  [ normalized_identity_token trimmed
  ; Option.bind
      (KI.canonical_keeper_name_from_agent_name trimmed)
      normalized_identity_token
  ; Option.bind (KI.canonical_keeper_name trimmed) normalized_identity_token
  ]
  |> List.filter_map (fun v -> v)
  |> List.sort_uniq String.compare

let legacy_is_self ~name ~agent_name author =
  let self_tokens =
    [ name; agent_name ]
    |> List.map legacy_tokens_of_value
    |> List.flatten
    |> List.sort_uniq String.compare
  in
  legacy_tokens_of_value author
  |> List.exists (fun token -> List.mem token self_tokens)

let new_is_self ~name ~agent_name author =
  let self_ids =
    List.filter_map Kid.of_string [ name; agent_name ]
    |> List.sort_uniq Kid.compare
  in
  match Kid.of_string author with
  | None -> false
  | Some author_id -> List.exists (Kid.equal author_id) self_ids

(* ── Goldens ── *)

let test_of_string_goldens () =
  check (option string) "bare name" (Some "dreamer") (id_str "dreamer");
  check (option string) "wrapper -/-" (Some "dreamer")
    (id_str "keeper-dreamer-agent");
  check (option string) "wrapper _/_" (Some "dreamer")
    (id_str "keeper_dreamer_agent");
  check (option string) "wrapper -/_" (Some "dreamer")
    (id_str "keeper-dreamer_agent");
  check (option string) "wrapper _/-" (Some "dreamer")
    (id_str "keeper_dreamer-agent");
  check (option string) "keeper- prefix form" (Some "dreamer")
    (id_str "keeper-dreamer");
  check (option string) "case folded before canonicalizing" (Some "dreamer")
    (id_str "Keeper-Dreamer-Agent");
  check (option string) "whitespace trimmed" (Some "dreamer")
    (id_str "  dreamer  ");
  check (option string) "human author keeps raw form" (Some "vincent")
    (id_str "Vincent");
  check (option string) "@-form is not a keeper shape, raw fallback"
    (Some "@dreamer") (id_str "@dreamer");
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
    [ "dreamer"
    ; "keeper-dreamer-agent"
    ; "keeper_dreamer_agent"
    ; "keeper-dreamer"
    ; "Vincent"
    ; "@dreamer"
    ]

(* ── Legacy equivalence matrix ── *)

let keeper_identities =
  [ ("dreamer", "keeper-dreamer-agent")
  ; ("sangsu", "keeper_sangsu_agent")
  ; ("analyst", "keeper-analyst-agent")
  ]

let author_forms name =
  [ name
  ; "keeper-" ^ name
  ; Printf.sprintf "keeper-%s-agent" name
  ; Printf.sprintf "keeper_%s_agent" name
  ; Printf.sprintf "keeper-%s_agent" name
  ; Printf.sprintf "keeper_%s-agent" name
  ]

let foreign_authors =
  [ "vincent"
  ; "operator"
  ; "other"
  ; "keeper-other-agent"
  ; "@dreamer"
  ; "email@dreamer.com"
  ; "dreamerx"
  ; ""
  ; "   "
  ]

let test_legacy_equivalence_matrix () =
  List.iter
    (fun (name, agent_name) ->
      let authors =
        author_forms name
        @ List.concat_map
            (fun (other, _) -> author_forms other)
            keeper_identities
        @ foreign_authors
      in
      List.iter
        (fun author ->
          let expected = legacy_is_self ~name ~agent_name author in
          let actual = new_is_self ~name ~agent_name author in
          check bool
            (Printf.sprintf "self(%s/%s) author=%S" name agent_name author)
            expected actual)
        authors)
    keeper_identities

let test_self_form_always_matches () =
  List.iter
    (fun (name, agent_name) ->
      List.iter
        (fun author ->
          check bool
            (Printf.sprintf "%S is self of %s" author name)
            true
            (new_is_self ~name ~agent_name author))
        (author_forms name))
    keeper_identities

(* The documented widening over the legacy behavior: mixed-case forms
   canonicalize instead of depending on the raw-token fallback. *)
let test_case_fold_widening () =
  check bool "mixed-case wrapper is self (legacy matched via raw token)"
    true
    (new_is_self ~name:"dreamer" ~agent_name:"keeper-dreamer-agent"
       "Keeper-Dreamer-Agent");
  check bool "uppercase bare name is self" true
    (new_is_self ~name:"dreamer" ~agent_name:"keeper-dreamer-agent" "DREAMER")

let test_message_scope_surface () =
  let ids = List.filter_map Kid.of_string [ "dreamer" ] in
  check bool "is_self_author over MS surface" true
    (MS.is_self_author ~self_ids:ids "keeper-dreamer-agent");
  check bool "foreign author is not self" false
    (MS.is_self_author ~self_ids:ids "vincent")

let () =
  run "keeper_identity_id"
    [
      ( "of_string",
        [
          test_case "goldens" `Quick test_of_string_goldens;
          test_case "idempotent" `Quick test_of_string_idempotent_on_goldens;
        ] );
      ( "legacy_equivalence",
        [
          test_case "matrix" `Quick test_legacy_equivalence_matrix;
          test_case "self forms match" `Quick test_self_form_always_matches;
          test_case "case-fold widening" `Quick test_case_fold_widening;
        ] );
      ( "surface",
        [ test_case "message scope" `Quick test_message_scope_surface ] );
    ]
