(** Pure-function unit tests for [Feature_flag_registry].

    Audit P2 follow-up (2026-04-29 §3.1.2) — the registry was
    listed as "테스트 완전 부재" with the recommendation
    "exhaustive variant match test".  This suite pins:

    1. [lifecycle_to_string] covers all 3 variants
       ([Active], [Deprecated _], [Experimental]) without
       partial-match silent regression.
    2. Registry invariants: non-empty, env-var name uniqueness,
       no [Deprecated reason=""], every entry's category is one
       of the documented six.
    3. [find_opt] returns [Some] for registered flags and
       [None] for unknown names.
    4. [flag_to_json] emits the documented 8-field shape.
    5. [to_json] groups all flags into the 6 documented
       categories and the [total_flags] field equals
       [List.length all_flags].
    6. [deprecated_flags] / [overridden_flags] partition
       behaviour. *)

module R = Feature_flag_registry

(* ─── (1) lifecycle_to_string exhaustiveness ──────────────────── *)

let test_lifecycle_active () =
  assert (R.lifecycle_to_string R.Active = "active")

let test_lifecycle_experimental () =
  assert (R.lifecycle_to_string R.Experimental = "experimental")

let test_lifecycle_deprecated_with_reason () =
  let s =
    R.lifecycle_to_string (R.Deprecated "replaced by MASC_X")
  in
  assert (s = "deprecated: replaced by MASC_X")

let test_lifecycle_deprecated_empty_reason () =
  (* Documents the trailing-space + empty reason behaviour.
     Not a great UX but pinning current shape. *)
  let s = R.lifecycle_to_string (R.Deprecated "") in
  assert (s = "deprecated: ")

(* ─── (2) registry invariants ─────────────────────────────────── *)

let test_registry_nonempty () =
  assert (List.length R.all_flags > 0)

let test_env_names_unique () =
  let names = List.map (fun f -> f.R.env_name) R.all_flags in
  let unique = List.sort_uniq String.compare names in
  assert (List.length names = List.length unique)

let test_no_blank_deprecation_reason () =
  let bad =
    List.filter
      (fun f ->
        match f.R.lifecycle with
        | R.Deprecated "" -> true
        | _ -> false)
      R.all_flags
  in
  assert (List.length bad = 0)

let test_every_env_name_has_masc_prefix () =
  List.iter
    (fun f ->
      assert (String.length f.R.env_name >= 5);
      assert (
        String.sub f.R.env_name 0 5 = "MASC_"))
    R.all_flags

let test_every_category_in_documented_set () =
  let allowed =
    [ "transport"; "tool"; "keeper"; "dashboard"; "inference";
      "runtime" ]
  in
  List.iter
    (fun f ->
      if not (List.mem f.R.category allowed) then begin
        Printf.eprintf
          "flag %s has unexpected category %S\n"
          f.R.env_name f.R.category;
        assert false
      end)
    R.all_flags

(* ─── (3) find_opt ────────────────────────────────────────────── *)

let test_find_opt_unknown () =
  match R.find_opt "MASC_THIS_FLAG_DOES_NOT_EXIST_XYZ123" with
  | None -> ()
  | Some _ -> assert false

let test_find_opt_first_registered () =
  match R.all_flags with
  | [] -> assert false  (* covered by test_registry_nonempty *)
  | first :: _ ->
      (match R.find_opt first.R.env_name with
       | Some f -> assert (f.R.env_name = first.R.env_name)
       | None -> assert false)

(* ─── (4) flag_to_json shape ──────────────────────────────────── *)

let test_flag_to_json_eight_fields () =
  match R.all_flags with
  | [] -> assert false
  | first :: _ ->
      let j = R.flag_to_json first in
      let expected_keys =
        [ "env_name"; "description"; "canonical_default";
          "runtime_value"; "source"; "category"; "lifecycle";
          "since" ]
      in
      List.iter
        (fun k ->
          let v = Yojson.Safe.Util.member k j in
          if v = `Null then begin
            Printf.eprintf "missing field %S in flag_to_json\n" k;
            assert false
          end)
        expected_keys

let test_flag_to_json_canonical_default_is_bool () =
  match R.all_flags with
  | [] -> assert false
  | first :: _ ->
      let j = R.flag_to_json first in
      let v = Yojson.Safe.Util.member "canonical_default" j in
      (match v with
       | `Bool _ -> ()
       | _ -> assert false)

(* ─── (5) to_json categorisation ──────────────────────────────── *)

let test_to_json_total_matches_all_flags () =
  let j = R.to_json () in
  let total =
    Yojson.Safe.Util.member "total_flags" j
    |> Yojson.Safe.Util.to_int
  in
  assert (total = List.length R.all_flags)

let test_to_json_six_categories () =
  let j = R.to_json () in
  let cats =
    Yojson.Safe.Util.member "categories" j
    |> Yojson.Safe.Util.to_assoc
  in
  let names = List.map fst cats |> List.sort String.compare in
  let expected =
    [ "dashboard"; "inference"; "keeper"; "runtime"; "tool";
      "transport" ]
  in
  assert (names = expected)

let test_to_json_categories_partition_all_flags () =
  (* Every flag in [all_flags] must appear in exactly one
     category bucket — the 6 buckets together must equal the
     full registry size. *)
  let j = R.to_json () in
  let cats =
    Yojson.Safe.Util.member "categories" j
    |> Yojson.Safe.Util.to_assoc
  in
  let summed =
    List.fold_left
      (fun acc (_cat, flags_json) ->
        acc + List.length (Yojson.Safe.Util.to_list flags_json))
      0 cats
  in
  assert (summed = List.length R.all_flags)

(* ─── (6) deprecated_flags / overridden_flags ─────────────────── *)

let test_deprecated_flags_only_deprecated () =
  let dep = R.deprecated_flags () in
  List.iter
    (fun f ->
      match f.R.lifecycle with
      | R.Deprecated _ -> ()
      | _ -> assert false)
    dep

let test_overridden_flags_subset_of_all () =
  (* Without setting env vars, [overridden_flags] should be a
     subset of [all_flags] and contain only flags whose
     [runtime_value] disagrees with their canonical default. *)
  let ov = R.overridden_flags () in
  assert (List.length ov <= List.length R.all_flags);
  List.iter
    (fun f -> assert (R.runtime_value f <> f.R.default))
    ov

(* ─── runner ──────────────────────────────────────────────────── *)

let () =
  test_lifecycle_active ();
  test_lifecycle_experimental ();
  test_lifecycle_deprecated_with_reason ();
  test_lifecycle_deprecated_empty_reason ();
  test_registry_nonempty ();
  test_env_names_unique ();
  test_no_blank_deprecation_reason ();
  test_every_env_name_has_masc_prefix ();
  test_every_category_in_documented_set ();
  test_find_opt_unknown ();
  test_find_opt_first_registered ();
  test_flag_to_json_eight_fields ();
  test_flag_to_json_canonical_default_is_bool ();
  test_to_json_total_matches_all_flags ();
  test_to_json_six_categories ();
  test_to_json_categories_partition_all_flags ();
  test_deprecated_flags_only_deprecated ();
  test_overridden_flags_subset_of_all ();
  print_endline "test_feature_flag_registry: all assertions passed"
