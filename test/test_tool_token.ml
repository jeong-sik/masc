(** Tests for Tool_token — private type, mint validation, dispatch integration. *)

open Alcotest
open Masc_mcp

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_tbl entries =
  let tbl = Hashtbl.create (List.length entries) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) entries;
  tbl

let empty_tbl = make_tbl []
let full_tbl = make_tbl [ "masc_status"; "masc_heartbeat"; "masc_tasks" ]

(* ================================================================ *)
(* mint — table variant                                              *)
(* ================================================================ *)

let test_mint_success () =
  match Tool_token.mint_with ~validate:(Hashtbl.mem full_tbl) ~name:"masc_status" with
  | Ok token ->
    check string "name preserved" "masc_status" token.name;
    check bool "minted_at > 0" true (token.minted_at > 0.0)
  | Error e -> fail e

let test_mint_failure () =
  match Tool_token.mint_with ~validate:(Hashtbl.mem empty_tbl) ~name:"any" with
  | Error msg ->
    check bool "contains tool name" true
      (String.length msg > 0 && Astring.String.is_infix ~affix:"any" msg)
  | Ok _ -> fail "expected Error for empty table"

let test_mint_unknown_tool () =
  match Tool_token.mint_with ~validate:(Hashtbl.mem full_tbl) ~name:"masc_nonexistent_xyz" with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for unknown tool"

(* ================================================================ *)
(* mint_with — validate variant                                      *)
(* ================================================================ *)

let test_mint_with_success () =
  let validate name = name = "allowed" in
  match Tool_token.mint_with ~validate ~name:"allowed" with
  | Ok token -> check string "name" "allowed" token.name
  | Error e -> fail e

let test_mint_with_failure () =
  let validate _ = false in
  match Tool_token.mint_with ~validate ~name:"denied" with
  | Error _ -> ()
  | Ok _ -> fail "expected Error when validate returns false"

(* ================================================================ *)
(* Token properties                                                  *)
(* ================================================================ *)

let test_token_name_readable () =
  match Tool_token.mint_with ~validate:(Hashtbl.mem full_tbl) ~name:"masc_heartbeat" with
  | Ok token ->
    (* Private type: fields are readable *)
    check string "name field" "masc_heartbeat" token.name;
    check bool "minted_at is recent" true
      (token.minted_at > 0.0 && token.minted_at <= Unix.gettimeofday () +. 1.0)
  | Error e -> fail e

(* Private type: { name = "fake"; minted_at = 0. } would be a compile error.
   This is a structural guarantee, not a runtime test.
   Uncomment below to verify:

   let _compile_error = { Tool_token.name = "fake"; minted_at = 0. }
*)

(* ================================================================ *)
(* Tool_dispatch.mint_token integration                              *)
(* ================================================================ *)

let test_mint_token_registered () =
  let tool = "__test_token_registered" in
  Tool_dispatch.register ~tool_name:tool
    ~handler:(fun ~name:_ ~args:_ -> Some (Masc_mcp.Tool_result.quick_ok "ok"));
  Tool_dispatch.register_name_tag ~tool_name:tool ~tag:Mod_misc;
  match Tool_dispatch.mint_token ~name:tool with
  | Ok token -> check string "name" tool token.name
  | Error e -> fail (Printf.sprintf "mint_token failed for registered tool: %s" e)

let test_mint_token_unregistered () =
  match Tool_dispatch.mint_token ~name:"__test_token_definitely_not_registered" with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for unregistered tool"

let test_dispatch_with_token () =
  let tool = "__test_token_dispatch" in
  Tool_dispatch.register ~tool_name:tool
    ~handler:(fun ~name ~args:_ -> Some (Tool_result.quick_ok ~tool_name:name ("dispatched:" ^ name)));
  Tool_dispatch.register_name_tag ~tool_name:tool ~tag:Mod_misc;
  match Tool_dispatch.mint_token ~name:tool with
  | Error e -> fail e
  | Ok token ->
    match Tool_dispatch.dispatch ~token ~args:`Null with
    | Some tr ->
      let ok = tr.success in
      let msg = Tool_result.message tr in
      (match ok with
       | true -> check string "dispatch result" ("dispatched:" ^ tool) msg
       | false -> fail ("dispatch returned false: " ^ msg))
    | None -> fail "dispatch returned None for minted token"

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  run "Tool_token"
    [
      ( "mint",
        [
          test_case "success" `Quick test_mint_success;
          test_case "empty table" `Quick test_mint_failure;
          test_case "unknown tool" `Quick test_mint_unknown_tool;
        ] );
      ( "mint_with",
        [
          test_case "validate true" `Quick test_mint_with_success;
          test_case "validate false" `Quick test_mint_with_failure;
        ] );
      ( "token_properties",
        [
          test_case "fields readable" `Quick test_token_name_readable;
        ] );
      ( "dispatch_integration",
        [
          test_case "mint_token registered" `Quick test_mint_token_registered;
          test_case "mint_token unregistered" `Quick test_mint_token_unregistered;
          test_case "dispatch with token" `Quick test_dispatch_with_token;
        ] );
    ]
