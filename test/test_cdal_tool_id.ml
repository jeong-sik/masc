open Alcotest
module Tool_id = Masc_mcp_cdal_runtime.Tool_id

let test_round_trip_known () =
  List.iter
    (fun id ->
       let s = Tool_id.to_string id in
       let parsed = Tool_id.of_string s in
       check bool (Printf.sprintf "round-trip %s" s) true (parsed = id))
    Tool_id.known
;;

let test_known_count () =
  (* RFC-0005 §3.1 baseline after descriptor-spine hard cut: 45 built-in tools. If
     this number changes, update Tool_id.t and acknowledge here so a
     drift between Tool_id.known and the default classification table
     is impossible to ship silently. *)
  check int "known constructor count" 45 (List.length Tool_id.known)
;;

let test_unknown_falls_back () =
  match Tool_id.of_string "definitely_not_a_real_tool" with
  | `Other_tool s -> check string "preserves wire string" "definitely_not_a_real_tool" s
  | _ -> fail "expected `Other_tool fallback for unknown tool"
;;

let test_other_tool_round_trip () =
  let id = `Other_tool "custom_plugin_tool" in
  check string "Other_tool to_string" "custom_plugin_tool" (Tool_id.to_string id);
  match Tool_id.of_string "custom_plugin_tool" with
  | `Other_tool s when s = "custom_plugin_tool" -> ()
  | other ->
    failf
      "Other_tool round-trip diverged: %s -> %s"
      "custom_plugin_tool"
      (Tool_id.to_string other)
;;

let test_normalised_lowercases () =
  match Tool_id.of_string_normalised "  Read_File  " with
  | `Read_file -> ()
  | other ->
    failf "expected `Read_file after trim+lowercase, got %s" (Tool_id.to_string other)
;;

let test_normalised_descriptor_public_names () =
  let cases =
    [ "Execute", `Execute
    ; "SearchFiles", `Search_files
    ; "ReadFile", `Read_file
    ; "EditFile", `Edit_file
    ; "WriteFile", `Write_file
    ; "SearchWeb", `Search_web
    ; "FetchWeb", `Fetch_web
    ]
  in
  List.iter
    (fun (raw, expected) ->
       let actual = Tool_id.of_string_normalised raw in
       check
         bool
         (Printf.sprintf "descriptor public name %s" raw)
         true
         (actual = expected))
    cases
;;

let test_retired_public_names_are_opaque () =
  List.iter
    (fun raw ->
       match Tool_id.of_string_normalised raw with
       | `Other_tool s ->
         check string (Printf.sprintf "retired %s" raw) (String.lowercase_ascii raw) s
       | other ->
         failf "expected retired %s to stay opaque, got %s" raw (Tool_id.to_string other))
    [ "Bash"; "Grep"; "Read"; "Write"; "Edit"; "WebFetch"; "WebSearch" ]
;;

let test_normalised_unknown_lowercased () =
  match Tool_id.of_string_normalised "  CUSTOM_Plugin  " with
  | `Other_tool "custom_plugin" -> ()
  | other ->
    failf "expected `Other_tool \"custom_plugin\", got %s" (Tool_id.to_string other)
;;

let test_known_unique_strings () =
  let strings = List.map Tool_id.to_string Tool_id.known in
  let sorted = List.sort String.compare strings in
  let rec has_duplicates = function
    | a :: b :: _ when a = b -> Some a
    | _ :: rest -> has_duplicates rest
    | [] -> None
  in
  match has_duplicates sorted with
  | None -> ()
  | Some dup -> failf "duplicate string in Tool_id.known: %s" dup
;;

let () =
  Alcotest.run
    "cdal_tool_id"
    [ ( "round_trip"
      , [ test_case "all known constructors round-trip" `Quick test_round_trip_known
        ; test_case "known count stable" `Quick test_known_count
        ; test_case "unknown falls back to Other_tool" `Quick test_unknown_falls_back
        ; test_case
            "Other_tool round-trip preserves string"
            `Quick
            test_other_tool_round_trip
        ] )
    ; ( "normalisation"
      , [ test_case "trim + lowercase resolves known" `Quick test_normalised_lowercases
        ; test_case
            "descriptor public names resolve"
            `Quick
            test_normalised_descriptor_public_names
        ; test_case
            "retired public names stay opaque"
            `Quick
            test_retired_public_names_are_opaque
        ; test_case "trim + lowercase + unknown" `Quick test_normalised_unknown_lowercased
        ] )
    ; ( "uniqueness"
      , [ test_case "no two constructors share a string" `Quick test_known_unique_strings
        ] )
    ]
;;
