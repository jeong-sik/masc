(** Current Keeper-meta read failures remain typed and never rewrite the row. *)

open Alcotest
open Masc

let current_with_outside_field name key =
  match Masc_test_deps.current_meta_json_fixture ~name () with
  | `Assoc fields -> `Assoc ((key, `String "value") :: fields)
  | _ -> Alcotest.fail "current fixture must be an object"
;;

let current_name = function
  | `Assoc fields ->
    (match List.assoc_opt "name" fields with
     | Some (`String name) -> name
     | _ -> Alcotest.fail "current fixture must have a string name")
  | _ -> Alcotest.fail "current fixture must be an object"
;;

let with_temp_json_as ~file_name json f =
  let dir = Filename.temp_file "keeper-current-meta-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let path = Filename.concat dir (file_name ^ ".json") in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      Unix.rmdir dir)
    (fun () ->
       Fs_compat.save_file path (Yojson.Safe.to_string json);
       f path)
;;

let with_temp_json json f =
  with_temp_json_as ~file_name:(current_name json) json f
;;

let replace_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> Alcotest.fail "current fixture must be an object"
;;

let assoc_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field %s" key)
  | _ -> Alcotest.fail "projection must be an object"
;;

let test_invalid_current_is_typed_and_byte_preserving () =
  with_temp_json
    (current_with_outside_field "typed-unavailable" "outside_current")
    (fun path ->
       let before = Masc_test_deps.read_file path in
       let unavailable =
         match Keeper_meta_store.read_meta_file_path_current path with
         | Error unavailable -> unavailable
         | Ok _ -> Alcotest.fail "outside-current row unexpectedly decoded"
       in
       (match unavailable.reason with
        | Keeper_meta_store.Invalid_current -> ()
        | Keeper_meta_store.Read_failed ->
          Alcotest.fail "schema mismatch was classified as a read failure"
        | Keeper_meta_store.Missing_current
        | Keeper_meta_store.Discovery_failed ->
          Alcotest.fail "schema mismatch was classified as a discovery failure");
       check string
         "path projection is basename-only"
         (Filename.basename path)
         unavailable.path_identity;
       check string
         "detail is stable and sanitized"
         "keeper current metadata does not match the current schema; runtime reset required"
         unavailable.detail;
       check bool
         "detail does not expose the parent path"
         false
         (Astring.String.is_infix
            ~affix:(Filename.dirname path)
            unavailable.detail);
       let projection =
         Keeper_meta_store.current_meta_unavailable_collection_to_yojson
           (Keeper_meta_store.Current_meta_observed [ unavailable ])
       in
       check string
         "collection status"
         "blocked"
         (match assoc_field "status" projection with
          | `String value -> value
          | _ -> Alcotest.fail "status must be a string");
       check bool
         "collection requires reset"
         true
         (match assoc_field "reset_required" projection with
          | `Bool value -> value
          | _ -> Alcotest.fail "reset_required must be a boolean");
       check int
         "collection count"
         1
         (match assoc_field "count" projection with
          | `Int value -> value
          | _ -> Alcotest.fail "count must be an integer");
       check string
         "invalid row is byte-for-byte unchanged"
         before
         (Masc_test_deps.read_file path))
;;

let test_all_outside_fields_share_one_reason () =
  [ "outside_current_a"; "outside_current_b" ]
  |> List.iter (fun key ->
    with_temp_json
      (current_with_outside_field ("uniform-" ^ key) key)
      (fun path ->
         match Keeper_meta_store.read_meta_file_path_current path with
         | Error { reason = Keeper_meta_store.Invalid_current; _ } -> ()
         | Error { reason = Keeper_meta_store.Read_failed; _ } ->
           Alcotest.failf "%s was classified as read_failed" key
         | Error
             { reason =
                 ( Keeper_meta_store.Missing_current
                 | Keeper_meta_store.Discovery_failed )
             ; _
             } ->
           Alcotest.failf "%s was classified as a discovery failure" key
         | Ok _ -> Alcotest.failf "%s unexpectedly decoded" key))
;;

let test_embedded_name_must_match_canonical_path () =
  let json = Masc_test_deps.current_meta_json_fixture ~name:"embedded-name" () in
  with_temp_json_as ~file_name:"path-name" json (fun path ->
    match Keeper_meta_store.read_meta_file_path_current path with
    | Error { reason = Keeper_meta_store.Invalid_current; _ } -> ()
    | Error _ -> Alcotest.fail "identity mismatch had the wrong typed reason"
    | Ok _ -> Alcotest.fail "identity mismatch unexpectedly decoded")
;;

let test_terminal_latch_requires_pause () =
  let json =
    Masc_test_deps.current_meta_json_fixture ~name:"unpaused-terminal" ()
    |> replace_field "latched_reason" (`String "dead_tombstone")
    |> replace_field "paused" (`Bool false)
  in
  with_temp_json json (fun path ->
    match Keeper_meta_store.read_meta_file_path_current path with
    | Error { reason = Keeper_meta_store.Invalid_current; _ } -> ()
    | Error _ -> Alcotest.fail "terminal latch violation had the wrong typed reason"
    | Ok _ -> Alcotest.fail "unpaused terminal latch unexpectedly decoded")
;;

let test_agent_name_must_match_canonical_identity () =
  let json =
    Masc_test_deps.current_meta_json_fixture ~name:"agent-identity" ()
    |> replace_field "agent_name" (`String "different-agent")
  in
  with_temp_json json (fun path ->
    match Keeper_meta_store.read_meta_file_path_current path with
    | Error { reason = Keeper_meta_store.Invalid_current; _ } -> ()
    | Error _ -> Alcotest.fail "agent identity mismatch had the wrong typed reason"
    | Ok _ -> Alcotest.fail "agent identity mismatch unexpectedly decoded")
;;

let test_meta_version_must_be_nonnegative () =
  let json =
    Masc_test_deps.current_meta_json_fixture ~name:"negative-version" ()
    |> replace_field "meta_version" (`Int (-1))
  in
  with_temp_json json (fun path ->
    match Keeper_meta_store.read_meta_file_path_current path with
    | Error { reason = Keeper_meta_store.Invalid_current; _ } -> ()
    | Error _ -> Alcotest.fail "negative meta version had the wrong typed reason"
    | Ok _ -> Alcotest.fail "negative meta version unexpectedly decoded")
;;

let test_generation_must_be_nonnegative () =
  let json =
    Masc_test_deps.current_meta_json_fixture ~name:"negative-generation" ()
    |> replace_field "generation" (`Int (-1))
  in
  with_temp_json json (fun path ->
    match Keeper_meta_store.read_meta_file_path_current path with
    | Error { reason = Keeper_meta_store.Invalid_current; _ } -> ()
    | Error _ -> Alcotest.fail "negative generation had the wrong typed reason"
    | Ok _ -> Alcotest.fail "negative generation unexpectedly decoded")
;;

let test_meta_version_must_remain_incrementable () =
  let json =
    Masc_test_deps.current_meta_json_fixture ~name:"max-version" ()
    |> replace_field "meta_version" (`Int max_int)
  in
  with_temp_json json (fun path ->
    match Keeper_meta_store.read_meta_file_path_current path with
    | Error { reason = Keeper_meta_store.Invalid_current; _ } -> ()
    | Error _ -> Alcotest.fail "max meta version had the wrong typed reason"
    | Ok _ -> Alcotest.fail "max meta version unexpectedly decoded")
;;

let test_latch_violation_keeps_reset_required_classification () =
  let json =
    Masc_test_deps.current_meta_json_fixture ~name:"latch-classification" ()
    |> replace_field "latched_reason" (`String "dead_tombstone")
    |> replace_field "paused" (`Bool false)
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error detail ->
    check bool
      "latch violation has current-schema prefix"
      true
      (Astring.String.is_prefix
         ~affix:"invalid current keeper meta:"
         detail);
    check bool
      "latch violation requires reset"
      true
      (Astring.String.is_infix ~affix:"runtime reset required" detail)
  | Ok _ -> Alcotest.fail "latch violation unexpectedly decoded"
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun child -> remove_tree (Filename.concat path child));
      Unix.rmdir path)
    else Sys.remove path
;;

let test_stale_update_cannot_recreate_missing_current () =
  Eio_main.run
  @@ fun _env ->
  let base_path = Filename.temp_file "keeper-current-create-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "current-meta-test"));
       let meta =
         match
           Masc_test_deps.current_meta_json_fixture ~name:"create-authority" ()
           |> Keeper_meta_json_parse.meta_of_json
         with
         | Ok meta -> meta
         | Error detail -> Alcotest.fail detail
       in
       (match Keeper_meta_store.create_meta config meta with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       let persisted =
         match Keeper_meta_store.read_meta config meta.name with
         | Ok (Some persisted) -> persisted
         | Ok None -> Alcotest.fail "fresh current row disappeared"
         | Error detail -> Alcotest.fail detail
       in
       let path = Keeper_types_profile.keeper_meta_path config meta.name in
       Sys.remove path;
       (match Keeper_meta_store.write_meta config persisted with
        | Error detail ->
          check bool
            "missing-current update is reset-required"
            true
            (Astring.String.is_infix ~affix:"runtime reset required" detail)
        | Ok () -> Alcotest.fail "stale update recreated missing current metadata");
       check bool "current row remains absent" false (Sys.file_exists path))
;;

let () =
  run
    "keeper_meta_current_unavailable"
    [ ( "current-meta"
      , [ test_case "typed fact and byte preservation" `Quick
            test_invalid_current_is_typed_and_byte_preserving
        ; test_case "outside fields share Invalid_current" `Quick
            test_all_outside_fields_share_one_reason
        ; test_case "canonical path owns keeper identity" `Quick
            test_embedded_name_must_match_canonical_path
        ; test_case "terminal latch requires pause" `Quick
            test_terminal_latch_requires_pause
        ; test_case "agent identity is canonical" `Quick
            test_agent_name_must_match_canonical_identity
        ; test_case "meta version is nonnegative" `Quick
            test_meta_version_must_be_nonnegative
        ; test_case "generation is nonnegative" `Quick
            test_generation_must_be_nonnegative
        ; test_case "meta version remains incrementable" `Quick
            test_meta_version_must_remain_incrementable
        ; test_case "latch violation keeps reset-required classification" `Quick
            test_latch_violation_keeps_reset_required_classification
        ; test_case "stale update cannot recreate missing current" `Quick
            test_stale_update_cannot_recreate_missing_current
        ] )
    ]
;;
