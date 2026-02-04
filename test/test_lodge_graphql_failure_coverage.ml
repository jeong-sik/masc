(** Coverage tests for Lodge GraphQL failure paths *)

open Masc_mcp

let () = Printf.printf "\n=== Lodge GraphQL Failure Coverage Tests ===\n"

let test name f =
  try
    f ();
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

let () = test "load_agents_from_neo4j_no_net" (fun () ->
  let agents = Lodge_heartbeat.load_agents_from_neo4j () in
  assert (agents = [])
)

let () = test "load_lodge_agents_full_no_net" (fun () ->
  match Lodge_heartbeat.load_lodge_agents_full () with
  | Ok _ -> failwith "expected error when Eio net is not initialized"
  | Error msg ->
      assert (String.starts_with ~prefix:"GraphQL request failed" msg)
)

let () = Printf.printf "\n✅ All Lodge GraphQL failure tests passed!\n"
