(** Current Keeper-meta read failures remain typed and never rewrite the row. *)

open Alcotest
open Masc

let current_with_outside_field name key =
  match Masc_test_deps.current_meta_json_fixture ~name () with
  | `Assoc fields -> `Assoc ((key, `String "value") :: fields)
  | _ -> Alcotest.fail "current fixture must be an object"
;;

let with_temp_json json f =
  let path = Filename.temp_file "keeper-current-meta-" ".json" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       Fs_compat.save_file path (Yojson.Safe.to_string json);
       f path)
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
          Alcotest.fail "schema mismatch was classified as a read failure");
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
           [ unavailable ]
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
         | Ok _ -> Alcotest.failf "%s unexpectedly decoded" key))
;;

let () =
  run
    "keeper_meta_current_unavailable"
    [ ( "current-meta"
      , [ test_case "typed fact and byte preservation" `Quick
            test_invalid_current_is_typed_and_byte_preserving
        ; test_case "outside fields share Invalid_current" `Quick
            test_all_outside_fields_share_one_reason
        ] )
    ]
;;
