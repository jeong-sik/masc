(* Tests for Dashboard_tla_specs: specs directory enumeration + JSON shape. *)

open Alcotest

let make_fixture_dir () =
  let root = Filename.temp_file "masc-specs-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o755;
  let boundary = Filename.concat root "boundary" in
  let bugs = Filename.concat root "bug-models" in
  Unix.mkdir boundary 0o755;
  Unix.mkdir bugs 0o755;
  let write path contents =
    let oc = open_out path in
    output_string oc contents;
    close_out oc
  in
  write (Filename.concat boundary "CascadeStrategy.tla") "MODULE CascadeStrategy\n";
  write (Filename.concat boundary "CascadeStrategy.cfg") "SPECIFICATION Spec\n";
  write (Filename.concat boundary "CascadeStrategy-buggy.cfg") "SPECIFICATION SpecBuggy\n";
  write (Filename.concat boundary "ZOnlyTla.tla") "MODULE ZOnlyTla\n";
  write (Filename.concat bugs "Overflow.tla") "MODULE Overflow\n";
  write (Filename.concat bugs "Overflow.cfg") "SPECIFICATION Spec\n";
  root
;;

let cleanup root =
  let rec rm_r p =
    if Sys.is_directory p
    then (
      Sys.readdir p |> Array.iter (fun c -> rm_r (Filename.concat p c));
      Unix.rmdir p)
    else Unix.unlink p
  in
  try rm_r root with
  | _ -> ()
;;

let with_specs_dir root f =
  let saved = Sys.getenv_opt "MASC_SPECS_DIR" in
  Unix.putenv "MASC_SPECS_DIR" root;
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv "MASC_SPECS_DIR" v
      | None -> Unix.putenv "MASC_SPECS_DIR" "")
    f
;;

let test_list_specs_basic () =
  let root = make_fixture_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup root)
    (fun () ->
       with_specs_dir root (fun () ->
         let entries = Masc_mcp.Dashboard_tla_specs.list_specs () in
         check int "three specs" 3 (List.length entries);
         let names =
           List.map (fun (e : Masc_mcp.Dashboard_tla_specs.spec_entry) -> e.name) entries
         in
         check
           (list string)
           "sorted by (category, name)"
           [ "CascadeStrategy"; "ZOnlyTla"; "Overflow" ]
           names))
;;

let test_cfg_presence_flags () =
  let root = make_fixture_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup root)
    (fun () ->
       with_specs_dir root (fun () ->
         let entries = Masc_mcp.Dashboard_tla_specs.list_specs () in
         let cascade =
           List.find
             (fun (e : Masc_mcp.Dashboard_tla_specs.spec_entry) ->
                e.name = "CascadeStrategy")
             entries
         in
         check bool "clean cfg present" true cascade.has_clean_cfg;
         check bool "buggy cfg present" true cascade.has_buggy_cfg;
         let only_tla =
           List.find
             (fun (e : Masc_mcp.Dashboard_tla_specs.spec_entry) -> e.name = "ZOnlyTla")
             entries
         in
         check bool "clean cfg absent" false only_tla.has_clean_cfg;
         check bool "buggy cfg absent" false only_tla.has_buggy_cfg))
;;

let test_category_mapping () =
  let root = make_fixture_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup root)
    (fun () ->
       with_specs_dir root (fun () ->
         let entries = Masc_mcp.Dashboard_tla_specs.list_specs () in
         let overflow =
           List.find
             (fun (e : Masc_mcp.Dashboard_tla_specs.spec_entry) -> e.name = "Overflow")
             entries
         in
         check string "bug-models category" "bug-models" overflow.category;
         let cascade =
           List.find
             (fun (e : Masc_mcp.Dashboard_tla_specs.spec_entry) ->
                e.name = "CascadeStrategy")
             entries
         in
         check string "boundary category" "boundary" cascade.category))
;;

let test_missing_dir () =
  with_specs_dir "/does/not/exist/masc-specs-xyz" (fun () ->
    let entries = Masc_mcp.Dashboard_tla_specs.list_specs () in
    check int "empty list when dir missing" 0 (List.length entries);
    let json = Masc_mcp.Dashboard_tla_specs.specs_json () in
    match json with
    | `Assoc fields ->
      (match List.assoc "specs_dir" fields with
       | `Null -> ()
       | _ -> fail "specs_dir should be null when dir missing");
      (match List.assoc "count" fields with
       | `Int 0 -> ()
       | _ -> fail "count should be 0 when dir missing")
    | _ -> fail "expected assoc")
;;

let test_json_shape () =
  let root = make_fixture_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup root)
    (fun () ->
       with_specs_dir root (fun () ->
         let json = Masc_mcp.Dashboard_tla_specs.specs_json () in
         match json with
         | `Assoc fields ->
           check bool "has updated_at" true (List.mem_assoc "updated_at" fields);
           check bool "has specs_dir" true (List.mem_assoc "specs_dir" fields);
           check bool "has count" true (List.mem_assoc "count" fields);
           check bool "has entries" true (List.mem_assoc "entries" fields);
           (match List.assoc "count" fields with
            | `Int 3 -> ()
            | _ -> fail "count should be 3");
           (match List.assoc "entries" fields with
            | `List xs -> check int "entries length" 3 (List.length xs)
            | _ -> fail "entries should be list")
         | _ -> fail "expected assoc"))
;;

let () =
  run
    "dashboard_tla_specs"
    [ ( "scan"
      , [ test_case "basic list" `Quick test_list_specs_basic
        ; test_case "cfg presence flags" `Quick test_cfg_presence_flags
        ; test_case "category mapping" `Quick test_category_mapping
        ; test_case "missing directory" `Quick test_missing_dir
        ] )
    ; "json", [ test_case "shape" `Quick test_json_shape ]
    ]
;;
