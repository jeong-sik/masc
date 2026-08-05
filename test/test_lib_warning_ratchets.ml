(** Every library that carries compiler flags carries the same ratchets.

    The flag set is hand-maintained across ~50 [lib/*/dune] files. Nothing
    makes them agree, so a library can be edited to drop a ratchet and the
    build stays green -- the ratchet just stops applying there.

    This pins the invariant as it holds today: a library with a
    [(:standard ...)] flags field carries [-w +37] (unused-constructor,
    the dead-state guard). It reads the dune files rather than asserting
    on behaviour because that is where the drift would happen. *)

open Alcotest

let ratchet = "-w +37"

(* The runtest action runs in the test directory; the stanza stages lib/
   beside it under the build root. *)
let lib_root = "../lib"

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let contains ~needle haystack =
  let hn = String.length haystack and nn = String.length needle in
  let rec go i =
    if i + nn > hn then false
    else if String.sub haystack i nn = needle then true
    else go (i + 1)
  in
  go 0
;;

(* dune files directly under lib/ and one level down. *)
let dune_files () =
  let entries = Sys.readdir lib_root |> Array.to_list |> List.sort String.compare in
  let nested =
    List.filter_map
      (fun entry ->
        let path = Filename.concat (Filename.concat lib_root entry) "dune" in
        if Sys.file_exists path then Some path else None)
      entries
  in
  let top = Filename.concat lib_root "dune" in
  if Sys.file_exists top then top :: nested else nested
;;

let flagged_dune_files () =
  dune_files ()
  |> List.filter_map (fun path ->
    let src = read_file path in
    if contains ~needle:"(:standard" src then Some (path, src) else None)
;;

(* A scan that finds no dune file passes by checking nothing. *)
let test_scan_finds_the_libraries () =
  let flagged = flagged_dune_files () in
  check bool
    (Printf.sprintf "%s yields libraries with a flags field" lib_root)
    true
    (List.length flagged >= 40)
;;

let test_every_flagged_library_carries_the_ratchet () =
  let missing =
    flagged_dune_files ()
    |> List.filter (fun (_, src) -> not (contains ~needle:ratchet src))
    |> List.map fst
  in
  if missing <> []
  then
    failf
      "these libraries declare compiler flags but not %s, so the dead-state \
       guard does not apply to them:\n  %s"
      ratchet
      (String.concat "\n  " missing)
;;

let () =
  Alcotest.run
    "lib warning ratchets"
    [ ( "ratchets"
      , [ test_case "the scan finds the libraries" `Quick test_scan_finds_the_libraries
        ; test_case "every flagged library carries -w +37" `Quick
            test_every_flagged_library_carries_the_ratchet
        ] )
    ]
;;
