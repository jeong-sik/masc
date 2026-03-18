(** Coverage tests for Lodge deprecation stubs (#1596, Phase 3).
    Lodge heartbeat removed; these verify the stub API surface. *)

open Masc_mcp

let () = Printf.printf "\n=== Lodge Deprecation Stub Tests ===\n"

let test name f =
  try
    f ();
    Printf.printf "  PASS %s\n" name
  with e ->
    Printf.printf "  FAIL %s: %s\n" name (Printexc.to_string e);
    exit 1

let () = test "lodge_status_returns_deprecated" (fun () ->
  let json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "status" fields with
       | Some (`String "deprecated") -> ()
       | _ -> failwith "expected status=deprecated")
  | _ -> failwith "expected Assoc")

let () = test "load_lodge_agents_full_returns_error" (fun () ->
  match Lodge_heartbeat.load_lodge_agents_full () with
  | Error _ -> ()
  | Ok _ -> failwith "expected Error")

let () = test "get_agents_returns_empty" (fun () ->
  assert (Lodge_heartbeat.get_agents () = []))

let () = test "check_gap_threshold_returns_empty" (fun () ->
  assert (Lodge_heartbeat.check_gap_threshold () = []))

let () = test "tool_lodge_stub_works" (fun () ->
  Eio_main.run @@ fun _env ->
  Tool_lodge.load_agents_config ();
  let agents = Tool_lodge.get_all_agents () in
  assert (List.length agents = 0))

let () = Printf.printf "\nAll Lodge deprecation stub tests passed.\n"
