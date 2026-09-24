(* The image catalog a Keeper's sandbox_image name is looked up in (RFC
   keeper-sandbox-images-have-versions §2.3). A name either resolves to one
   pinned build for the store asked about, or says precisely why not; a
   malformed catalog is refused rather than read around. *)

open Alcotest
module C = Keeper_sandbox_image_catalog
open C

let digest c = "sha256:" ^ String.make 64 c
let apple = Microvm Keeper_microvm_backend.Apple_container

let parsed text =
  match parse text with
  | Ok catalog -> catalog
  | Error e -> fail (parse_error_to_string e)

let refused label text =
  match parse text with
  | Ok _ -> fail (label ^ ": parsed")
  | Error e -> e

let promoted_ocaml =
  Printf.sprintf
    {|[images.base]

[images.ocaml.apple_container]
reference = "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07"
digest = "%s"
previous = { reference = "masc-sandbox-ocaml:20260921T0517Z-9b04e6d1", digest = "%s" }
|}
    (digest 'a') (digest 'b')

let resolution =
  testable
    (fun fmt -> function
       | Resolved p -> Format.fprintf fmt "Resolved %s@%s" p.reference p.digest
       | Unknown_image { name; known } ->
         Format.fprintf fmt "Unknown_image %s [%s]" name (String.concat ";" known)
       | Not_built_on_host { name; store } ->
         Format.fprintf fmt "Not_built_on_host %s %s" name (store_to_string store))
    ( = )

let test_a_promoted_name_resolves_for_its_store () =
  let catalog = parsed promoted_ocaml in
  check resolution "apple_container"
    (Resolved { reference = "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07"; digest = digest 'a' })
    (resolve catalog ~name:"ocaml" ~store:apple);
  check resolution "docker has nothing built"
    (Not_built_on_host { name = "ocaml"; store = Docker_daemon })
    (resolve catalog ~name:"ocaml" ~store:Docker_daemon)

let test_a_name_with_no_build_is_not_built_on_host () =
  check resolution "base"
    (Not_built_on_host { name = "base"; store = apple })
    (resolve (parsed promoted_ocaml) ~name:"base" ~store:apple)

let test_an_unknown_name_lists_the_known_ones () =
  check resolution "rust"
    (Unknown_image { name = "rust"; known = [ "base"; "ocaml" ] })
    (resolve (parsed promoted_ocaml) ~name:"rust" ~store:apple)

let test_previous_is_kept () =
  match entries (parsed promoted_ocaml) with
  | [ base; ocaml ] ->
    check int "base has no builds" 0 (List.length base.promoted);
    (match ocaml.promoted with
     | [ (store, promotion) ] ->
       check string "store" "apple_container" (store_to_string store);
       check (option string) "previous"
         (Some "masc-sandbox-ocaml:20260921T0517Z-9b04e6d1")
         (Option.map (fun p -> p.reference) promotion.previous)
     | _ -> fail "one promotion expected")
  | _ -> fail "two entries expected"

let test_an_empty_catalog_knows_no_names () =
  check resolution "empty"
    (Unknown_image { name = "base"; known = [] })
    (resolve (parsed "") ~name:"base" ~store:Docker_daemon)

let test_every_store_spelling_round_trips () =
  List.iter
    (fun store ->
       check (option string) (store_to_string store) (Some (store_to_string store))
         (Option.map store_to_string (store_of_string (store_to_string store))))
    (Docker_daemon :: List.map (fun b -> Microvm b) Keeper_microvm_backend.all)

let error = testable (fun fmt e -> Format.pp_print_string fmt (parse_error_to_string e)) ( = )

let test_malformed_catalogs_are_refused () =
  let one_store body = "[images.ocaml.apple_container]\n" ^ body in
  let pinned_body = Printf.sprintf "reference = \"x:y\"\ndigest = \"%s\"\n" (digest 'a') in
  check error "unknown top-level key"
    (Unknown_key { path = []; key = "image" })
    (refused "top" "[image.base]\n");
  check error "misspelt field"
    (Unknown_key { path = [ "images"; "ocaml"; "apple_container" ]; key = "tag" })
    (refused "field" (one_store (pinned_body ^ "tag = \"z\"\n")));
  check error "unknown store"
    (Unknown_store { image = "ocaml"; store = "podman" })
    (refused "store" ("[images.ocaml.podman]\n" ^ pinned_body));
  check error "uppercase digest"
    (Invalid_digest
       { path = [ "images"; "ocaml"; "apple_container" ]; value = "sha256:" ^ String.make 64 'A' })
    (refused "digest"
       (one_store (Printf.sprintf "reference = \"x:y\"\ndigest = \"sha256:%s\"\n" (String.make 64 'A'))));
  check error "missing digest"
    (Missing_field { path = [ "images"; "ocaml"; "apple_container" ]; field = "digest" })
    (refused "missing" (one_store "reference = \"x:y\"\n"));
  check error "half a previous"
    (Missing_field { path = [ "images"; "ocaml"; "apple_container"; "previous" ]; field = "digest" })
    (refused "previous" (one_store (pinned_body ^ "previous = { reference = \"x:z\" }\n")));
  check error "blank reference"
    (Invalid_reference { path = [ "images"; "ocaml"; "apple_container" ]; value = " " })
    (refused "blank" (one_store (Printf.sprintf "reference = \" \"\ndigest = \"%s\"\n" (digest 'a'))));
  check error "quote in reference"
    (Invalid_reference { path = [ "images"; "ocaml"; "apple_container" ]; value = "x\"y" })
    (refused "quote" (one_store (Printf.sprintf "reference = 'x\"y'\ndigest = \"%s\"\n" (digest 'a'))));
  check error "bad name" (Invalid_name "Base") (refused "name" "[images.Base]\n");
  check error "store is not a table"
    (Expected_table { path = [ "images"; "ocaml"; "apple_container" ] })
    (refused "scalar" "[images.ocaml]\napple_container = \"x:y\"\n");
  (match refused "syntax" "[images.base\n" with
   | Toml_syntax _ -> ()
   | other -> fail ("expected a syntax error, got " ^ parse_error_to_string other))

let changed label = function
  | Ok catalog -> catalog
  | Error e -> fail (label ^ ": " ^ change_error_to_string e)

let current catalog name store =
  match resolve catalog ~name ~store with
  | Resolved p -> Some p.reference
  | Unknown_image _ | Not_built_on_host _ -> None

let test_to_toml_round_trips () =
  let catalog = parsed promoted_ocaml in
  check string "parse (to_toml c) = c" (to_toml catalog) (to_toml (parsed (to_toml catalog)));
  check bool "same entries" true (entries (parsed (to_toml catalog)) = entries catalog)

let test_promote_keeps_what_it_replaced () =
  let catalog = parsed promoted_ocaml in
  let next =
    changed "promote"
      (promote catalog ~name:"ocaml" ~store:apple ~reference:"masc-sandbox-ocaml:20260925T0900Z-11112222"
         ~digest:(digest 'c'))
  in
  check (option string) "current" (Some "masc-sandbox-ocaml:20260925T0900Z-11112222")
    (current next "ocaml" apple);
  (match rollback next ~name:"ocaml" ~store:apple with
   | Ok back ->
     check (option string) "rolled back" (Some "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07")
       (current back "ocaml" apple);
     check (option string) "rolling back twice returns"
       (Some "masc-sandbox-ocaml:20260925T0900Z-11112222")
       (current (changed "rollback" (rollback back ~name:"ocaml" ~store:apple)) "ocaml" apple)
   | Error e -> fail (change_error_to_string e));
  check bool "promoting the current build again changes nothing" true
    (entries next
     = entries
         (changed "again"
            (promote next ~name:"ocaml" ~store:apple
               ~reference:"masc-sandbox-ocaml:20260925T0900Z-11112222" ~digest:(digest 'c'))))

let test_first_promotion_and_other_stores () =
  let catalog = parsed promoted_ocaml in
  let next =
    changed "base on docker"
      (promote catalog ~name:"base" ~store:Docker_daemon ~reference:"masc-sandbox:general"
         ~digest:(digest 'd'))
  in
  check (option string) "docker" (Some "masc-sandbox:general") (current next "base" Docker_daemon);
  check (option string) "apple untouched" None (current next "base" apple);
  check (option string) "ocaml untouched" (Some "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07")
    (current next "ocaml" apple)

let test_changes_are_refused_with_reasons () =
  let catalog = parsed promoted_ocaml in
  (match promote catalog ~name:"rust" ~store:apple ~reference:"r:1" ~digest:(digest 'a') with
   | Error (No_such_image { name = "rust"; known = [ "base"; "ocaml" ] }) -> ()
   | _ -> fail "an unknown name was promoted");
  (match promote catalog ~name:"base" ~store:apple ~reference:"r:1" ~digest:"sha256:short" with
   | Error (Invalid_pin (Invalid_digest _)) -> ()
   | _ -> fail "a bad digest was promoted");
  (match rollback catalog ~name:"base" ~store:apple with
   | Error (Nothing_to_roll_back _) -> ()
   | _ -> fail "rolled back a name with no build")

let with_dir f =
  let dir = Filename.temp_file "masc-image-catalog-" ".d" in
  Sys.remove dir;
  Sys.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      let file = Filename.concat dir file_name in
      if Sys.file_exists file then Sys.remove file;
      Sys.rmdir dir)
    (fun () -> f dir)

let test_load_reads_the_config_root () =
  with_dir (fun config_root ->
    (match load ~config_root with
     | Error (Missing { path }) ->
       check string "path" (Filename.concat config_root file_name) path
     | Error e -> fail (load_error_to_string e)
     | Ok _ -> fail "loaded a catalog that is not there");
    Out_channel.with_open_bin (Filename.concat config_root file_name) (fun oc ->
      output_string oc promoted_ocaml);
    match load ~config_root with
    | Ok catalog -> check int "entries" 2 (List.length (entries catalog))
    | Error e -> fail (load_error_to_string e))

let test_save_then_load () =
  with_dir (fun config_root ->
    let catalog = parsed promoted_ocaml in
    (match save ~config_root catalog with
     | Ok () -> ()
     | Error e -> fail (save_error_to_string e));
    match load ~config_root with
    | Ok loaded -> check bool "same catalog" true (entries loaded = entries catalog)
    | Error e -> fail (load_error_to_string e))

let () =
  run "Sandbox image catalog"
    [ ( "resolve"
      , [ test_case "a promoted name resolves for its store" `Quick
            test_a_promoted_name_resolves_for_its_store
        ; test_case "a name with no build is not built on host" `Quick
            test_a_name_with_no_build_is_not_built_on_host
        ; test_case "an unknown name lists the known ones" `Quick
            test_an_unknown_name_lists_the_known_ones
        ; test_case "previous is kept" `Quick test_previous_is_kept
        ; test_case "an empty catalog knows no names" `Quick test_an_empty_catalog_knows_no_names
        ; test_case "every store spelling round-trips" `Quick
            test_every_store_spelling_round_trips
        ] )
    ; ( "parse"
      , [ test_case "malformed catalogs are refused" `Quick test_malformed_catalogs_are_refused
        ; test_case "load reads the config root" `Quick test_load_reads_the_config_root
        ] )
    ; ( "change"
      , [ test_case "to_toml round-trips" `Quick test_to_toml_round_trips
        ; test_case "promote keeps what it replaced" `Quick test_promote_keeps_what_it_replaced
        ; test_case "first promotion and other stores" `Quick
            test_first_promotion_and_other_stores
        ; test_case "changes are refused with reasons" `Quick test_changes_are_refused_with_reasons
        ; test_case "save then load" `Quick test_save_then_load
        ] )
    ]
