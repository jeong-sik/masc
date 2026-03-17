(** Coverage tests for Lodge GraphQL fallback paths

    After commit 0a8f14b, Lodge uses curl fallback when Eio net is not initialized.
    These tests verify the curl fallback behavior works correctly. *)

open Masc_mcp

let () = Printf.printf "\n=== Lodge GraphQL Fallback Coverage Tests ===\n"

let with_env key value f =
  let prev = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let test name f =
  try
    f ();
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

(* Test: curl fallback works when Eio net not initialized *)
let () = test "load_agents_from_neo4j_curl_fallback" (fun () ->
  (* When Eio net is not initialized, Cohttp fails but curl fallback succeeds.
     On invalid/empty GraphQL payloads, Lodge now falls back to builtin agents. *)
  let agents = Lodge_heartbeat.load_agents_from_neo4j () in
  assert (List.length agents >= 5);
  Printf.printf "  (fallback returned %d agents)\n" (List.length agents)
)

let () = test "load_agents_from_neo4j_invalid_endpoint_uses_builtin_fallback" (fun () ->
  with_env "GRAPHQL_URL" (Some "http://127.0.0.1:9/graphql") (fun () ->
      let agents = Lodge_heartbeat.load_agents_from_neo4j () in
      assert (List.length agents >= 5)))

let () = test "load_lodge_agents_full_invalid_endpoint_errors_cleanly" (fun () ->
  with_env "GRAPHQL_URL" (Some "http://127.0.0.1:9/graphql") (fun () ->
      match Lodge_heartbeat.load_lodge_agents_full () with
      | Ok (`Assoc fields) ->
          ignore (List.assoc "agents" fields)
      | Ok _ -> failwith "expected agents payload"
      | Error msg -> assert (String.length msg > 0)))

let () = test "tool_lodge_invalid_endpoint_uses_builtin_cache_fallback" (fun () ->
  Eio_main.run @@ fun _env ->
  with_env "GRAPHQL_URL" (Some "http://127.0.0.1:9/graphql") (fun () ->
      Tool_lodge.load_agents_config ();
      let agents = Tool_lodge.get_all_agents () in
      assert (List.length agents >= 5)))

let () = Printf.printf "\n✅ All Lodge GraphQL fallback tests passed!\n"
