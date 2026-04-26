(** Test that Transport_bridge.seal blocks post-bootstrap registration. *)

open Alcotest

module MockProvider : Masc_mcp.Transport_bridge.PROVIDER = struct
  let name = "test-seal-mock"
  let protocol = Masc_mcp.Transport.Sse
  let is_enabled () = false
  let session_count () = 0
  let status_json () = `Null
  let reap_stale () = 0
end

let test_seal_blocks_registration () =
  (* seal may already be called by other tests or the server;
     call it again — idempotent. *)
  Masc_mcp.Transport_bridge.seal ();
  let raised = ref false in
  (try Masc_mcp.Transport_bridge.register_provider (module MockProvider) with
   | Invalid_argument msg -> if String.length msg > 0 then raised := true);
  check bool "post-seal register raises Invalid_argument" true !raised
;;

let () =
  run
    "Transport_bridge.seal"
    [ ( "seal"
      , [ test_case "blocks post-seal registration" `Quick test_seal_blocks_registration ]
      )
    ]
;;
