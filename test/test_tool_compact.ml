(** Tests for Tool_compact — masc_compact_context MCP tool.

    The masc_compact_context tool was pruned from the public registry.
    The Tool_compact.dispatch handler is gutted and now returns None
    for all inputs. Remaining tests cover fs_compat backend types which
    are independent of the dispatcher.

    @since 2.95.0 (dispatch gutted in tool-registry-pruning, 2026-04-15) *)

open Alcotest
module TC = Masc_mcp.Tool_compact

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let make_args (messages : (string * string) list) : Yojson.Safe.t =
  let msg_json = List.map (fun (role, content) ->
    `Assoc [("role", `String role); ("content", `String content)]
  ) messages in
  `Assoc [
    ("messages", `List msg_json);
    ("strategy", `String "all");
    ("max_tokens", `Int 128_000);
    ("system_prompt", `String "");
  ]

(* ================================================================ *)
(* Tests — dispatch gutted                                          *)
(* ================================================================ *)

let test_dispatch_returns_none_for_compact_context () =
  let args = make_args [("user", "hello")] in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> ()
  | Some _ -> fail "masc_compact_context dispatch should be gutted"

let test_dispatch_returns_none_for_unknown_tool () =
  let args = `Assoc [] in
  match TC.dispatch ~name:"unknown_tool" ~args with
  | None -> ()
  | Some _ -> fail "unknown tool should return None"

(* ================================================================ *)
(* Test for fs_compat backend types                                 *)
(* ================================================================ *)

let test_backend_create_default () =
  let b = Fs_compat.default_backend ~base_path:"/tmp/test" in
  check string "base_path" "/tmp/test" (Fs_compat.backend_base_path b);
  check string "kind" "local" (Fs_compat.backend_kind_to_string b.kind)

let test_backend_create_remote () =
  let b = Fs_compat.create_backend
    ~kind:(Fs_compat.Remote "https://s3.example.com/bucket")
    ~base_path:"/data" () in
  check string "base_path" "/data" (Fs_compat.backend_base_path b);
  check string "kind" "remote(https://s3.example.com/bucket)"
    (Fs_compat.backend_kind_to_string b.kind)

let test_backend_create_local_explicit () =
  let b = Fs_compat.create_backend
    ~kind:Fs_compat.Local ~base_path:"/var/data" () in
  check string "base_path" "/var/data" (Fs_compat.backend_base_path b)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "tool_compact + fs_compat_backend" [
    ("compact_dispatch", [
      test_case "compact_context dispatch gutted" `Quick
        test_dispatch_returns_none_for_compact_context;
      test_case "unknown tool name" `Quick
        test_dispatch_returns_none_for_unknown_tool;
    ]);
    ("fs_compat_backend", [
      test_case "default backend" `Quick test_backend_create_default;
      test_case "remote backend" `Quick test_backend_create_remote;
      test_case "local explicit" `Quick test_backend_create_local_explicit;
    ]);
  ]
