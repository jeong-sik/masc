(** Every typed accessor, against every constructor of [toml_value].

    The accessors used to decide through [| _ -> None] over a closed
    13-constructor variant, so a new TOML value kind was absorbed silently.
    They now enumerate the rejected constructors, which makes the compiler
    refuse to build when the variant grows.

    Writing those or-patterns by hand is the part the compiler cannot check:
    dropping a constructor from one list only shows up as a non-exhaustive
    match, but putting a constructor in the wrong accessor's accepting arm
    compiles fine and changes behaviour. This walks the full matrix so the
    answer for each (accessor, constructor) pair is pinned. *)

open Alcotest

module L = Keeper_toml_loader

(* One witness per constructor, in the order the type declares them. A
   constructor added to toml_value belongs here too -- and the count case
   below fails until it is. *)
let witnesses : (string * L.toml_value) list =
  [ "Toml_string", L.Toml_string "s"
  ; "Toml_int", L.Toml_int 7
  ; "Toml_float", L.Toml_float 1.5
  ; "Toml_bool", L.Toml_bool true
  ; "Toml_string_array", L.Toml_string_array [ "a"; "b" ]
  ; "Toml_array", L.Toml_array [ L.Toml_int 1 ]
  ; "Toml_table", L.Toml_table [ "k", L.Toml_int 1 ]
  ; "Toml_inline_table", L.Toml_inline_table [ "k", L.Toml_int 1 ]
  ; "Toml_table_array", L.Toml_table_array [ L.Toml_table [] ]
  ; "Toml_offset_datetime", L.Toml_offset_datetime "1979-05-27T07:32:00Z"
  ; "Toml_local_datetime", L.Toml_local_datetime "1979-05-27T07:32:00"
  ; "Toml_local_date", L.Toml_local_date "1979-05-27"
  ; "Toml_local_time", L.Toml_local_time "07:32:00"
  ]
;;

let key = "keeper.value"
let doc_of value : L.toml_doc = [ key, value ]

(* A matrix over an empty witness list would pass by testing nothing. *)
let test_every_constructor_has_a_witness () =
  check int "one witness per toml_value constructor" 13 (List.length witnesses);
  check bool "names are distinct" true
    (List.length (List.sort_uniq String.compare (List.map fst witnesses)) = 13)
;;

(* [accepts] names the constructors the accessor answers for; every other
   constructor must fall through. *)
let matrix name ~accepts ~run ~is_reject =
  List.iter
    (fun (ctor, value) ->
      let got = run (doc_of value) in
      let expected_reject = not (List.mem ctor accepts) in
      if expected_reject && not (is_reject got)
      then failf "%s accepted %s; it should only accept %s" name ctor
             (String.concat ", " accepts)
      else if (not expected_reject) && is_reject got
      then failf "%s rejected %s, which it is supposed to accept" name ctor)
    witnesses
;;

let test_string_opt () =
  matrix "toml_string_opt" ~accepts:[ "Toml_string" ]
    ~run:(fun d -> L.toml_string_opt d key)
    ~is_reject:(fun r -> r = None);
  check (option string) "value round-trips" (Some "s")
    (L.toml_string_opt (doc_of (L.Toml_string "s")) key)
;;

let test_int_opt () =
  matrix "toml_int_opt" ~accepts:[ "Toml_int" ]
    ~run:(fun d -> L.toml_int_opt d key)
    ~is_reject:(fun r -> r = None);
  check (option int) "value round-trips" (Some 7)
    (L.toml_int_opt (doc_of (L.Toml_int 7)) key)
;;

(* toml_float_opt is the one accessor that accepts two constructors: an int
   is widened. Losing that arm would be a silent behaviour change. *)
let test_float_opt () =
  matrix "toml_float_opt" ~accepts:[ "Toml_float"; "Toml_int" ]
    ~run:(fun d -> L.toml_float_opt d key)
    ~is_reject:(fun r -> r = None);
  check (option (float 0.0001)) "float passes through" (Some 1.5)
    (L.toml_float_opt (doc_of (L.Toml_float 1.5)) key);
  check (option (float 0.0001)) "int is widened" (Some 7.0)
    (L.toml_float_opt (doc_of (L.Toml_int 7)) key)
;;

let test_bool_opt () =
  matrix "toml_bool_opt" ~accepts:[ "Toml_bool" ]
    ~run:(fun d -> L.toml_bool_opt d key)
    ~is_reject:(fun r -> r = None);
  check (option bool) "value round-trips" (Some true)
    (L.toml_bool_opt (doc_of (L.Toml_bool true)) key)
;;

(* This one rejects with [] rather than None. *)
let test_string_list () =
  matrix "toml_string_list" ~accepts:[ "Toml_string_array" ]
    ~run:(fun d -> L.toml_string_list d key)
    ~is_reject:(fun r -> r = []);
  check (list string) "value round-trips" [ "a"; "b" ]
    (L.toml_string_list (doc_of (L.Toml_string_array [ "a"; "b" ])) key)
;;

(* A key that is not in the document is the other rejection path, and it
   shares an arm with the wrong-constructor case. *)
let test_missing_key () =
  let empty : L.toml_doc = [] in
  check (option string) "string" None (L.toml_string_opt empty key);
  check (option int) "int" None (L.toml_int_opt empty key);
  check (option (float 0.0001)) "float" None (L.toml_float_opt empty key);
  check (option bool) "bool" None (L.toml_bool_opt empty key);
  check (list string) "string list" [] (L.toml_string_list empty key)
;;

let () =
  Alcotest.run
    "Keeper toml accessor matrix"
    [ ( "witnesses"
      , [ test_case "cover every constructor" `Quick test_every_constructor_has_a_witness ] )
    ; ( "accessors"
      , [ test_case "toml_string_opt" `Quick test_string_opt
        ; test_case "toml_int_opt" `Quick test_int_opt
        ; test_case "toml_float_opt" `Quick test_float_opt
        ; test_case "toml_bool_opt" `Quick test_bool_opt
        ; test_case "toml_string_list" `Quick test_string_list
        ; test_case "a missing key" `Quick test_missing_key
        ] )
    ]
;;
