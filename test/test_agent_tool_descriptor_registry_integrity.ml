(** Registry integrity checks that the OCaml type system cannot enforce.

    [Agent_tool_descriptor.runtime_handler] is a closed variant and
    every in-process dispatch site pattern-matches against it
    exhaustively, so the "descriptor registered without a dispatch
    handler" case is already caught at compile time. What is NOT
    caught:

    - duplicate [public_name] strings across descriptors
    - duplicate [internal_name] strings across descriptors
    - empty / whitespace-only name fields
    - [internal_name] format drift (non-snake_case, embedded spaces,
      etc.)

    These are exactly the failures a big-bang descriptor-add merge
    (e.g., RFC-0179 #18710, 38 descriptors) is most likely to
    introduce: typos in name fields propagate silently until a caller
    looks them up by string. *)

open Alcotest
module Descriptor = Masc_mcp.Agent_tool_descriptor

let all_descriptors () : Descriptor.t list = Descriptor.all_descriptors ()

let find_duplicates ~key (xs : Descriptor.t list) : (string * int) list =
  let counts = Hashtbl.create 64 in
  List.iter
    (fun d ->
      let k = key d in
      let prev = Option.value (Hashtbl.find_opt counts k) ~default:0 in
      Hashtbl.replace counts k (prev + 1))
    xs;
  Hashtbl.fold
    (fun k count acc -> if count > 1 then (k, count) :: acc else acc)
    counts
    []

let test_public_name_uniqueness () =
  let dups = find_duplicates ~key:(fun d -> d.Descriptor.public_name) (all_descriptors ()) in
  if dups <> []
  then
    Alcotest.failf
      "duplicate public_name(s) across Agent_tool_descriptor.all_descriptors: %s"
      (String.concat ", "
         (List.map (fun (n, c) -> Printf.sprintf "%S×%d" n c) dups))

let test_internal_name_uniqueness () =
  let dups = find_duplicates ~key:(fun d -> d.Descriptor.internal_name) (all_descriptors ()) in
  if dups <> []
  then
    Alcotest.failf
      "duplicate internal_name(s) across Agent_tool_descriptor.all_descriptors: %s"
      (String.concat ", "
         (List.map (fun (n, c) -> Printf.sprintf "%S×%d" n c) dups))

let is_blank s = String.trim s = ""

let test_no_blank_names () =
  List.iter
    (fun d ->
      if is_blank d.Descriptor.public_name
      then
        Alcotest.failf
          "descriptor with internal_name=%S has blank public_name"
          d.Descriptor.internal_name;
      if is_blank d.Descriptor.internal_name
      then
        Alcotest.failf
          "descriptor with public_name=%S has blank internal_name"
          d.Descriptor.public_name)
    (all_descriptors ())

let internal_name_charset_ok c =
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'

let test_internal_name_snake_case () =
  List.iter
    (fun d ->
      let n = d.Descriptor.internal_name in
      String.iter
        (fun c ->
          if not (internal_name_charset_ok c)
          then
            Alcotest.failf
              "internal_name %S contains non-snake_case character %C \
               (allowed: a-z, 0-9, _)"
              n
              c)
        n)
    (all_descriptors ())

let test_registry_not_empty () =
  if all_descriptors () = []
  then Alcotest.failf "Agent_tool_descriptor.all_descriptors () returned []"

let () =
  Alcotest.run
    "agent_tool_descriptor_registry_integrity"
    [ ( "uniqueness"
      , [ test_case "registry not empty" `Quick test_registry_not_empty
        ; test_case "public_name is unique" `Quick test_public_name_uniqueness
        ; test_case "internal_name is unique" `Quick test_internal_name_uniqueness
        ] )
    ; ( "format"
      , [ test_case "no blank name fields" `Quick test_no_blank_names
        ; test_case "internal_name is snake_case" `Quick test_internal_name_snake_case
        ] )
    ]
