open Alcotest
module Boundary = Masc_mcp.Track2_sync_boundary

let check_admission name expected layer writer =
  check bool name expected (Boundary.can_write layer writer)
;;

let test_writer_admission () =
  check_admission
    "authority accepts OCaml writer"
    true
    Boundary.Authority
    Boundary.Ocaml_authority;
  check_admission
    "authority rejects dashboard writer"
    false
    Boundary.Authority
    Boundary.Dashboard_client;
  check
    string
    "dashboard rejection reason"
    "not_authoritative"
    (Boundary.rejection_name
       (match Boundary.admit_write Boundary.Authority Boundary.Dashboard_client with
        | Boundary.Accepted -> failwith "unexpected accepted write"
        | Boundary.Rejected reason -> reason));
  check_admission
    "projection is server authored"
    true
    Boundary.Projection
    Boundary.Ocaml_authority;
  check_admission
    "projection rejects sidecar writes"
    false
    Boundary.Projection
    Boundary.Sync_sidecar;
  check_admission
    "ephemeral accepts dashboard writes"
    true
    Boundary.Ephemeral
    Boundary.Dashboard_client;
  check_admission
    "ephemeral rejects authoritative state writes"
    false
    Boundary.Ephemeral
    Boundary.Ocaml_authority
;;

let test_cluster_sizes () =
  check (list int) "no agents" [] (Boundary.cluster_sizes 0);
  check (list int) "partial pair" [ 2 ] (Boundary.cluster_sizes 2);
  check (list int) "single full cell" [ 5 ] (Boundary.cluster_sizes 5);
  check (list int) "avoid singleton remainder" [ 3; 3 ] (Boundary.cluster_sizes 6);
  check (list int) "balanced cells" [ 4; 4; 3 ] (Boundary.cluster_sizes 11);
  check (list int) "twelve agent cells" [ 4; 4; 4 ] (Boundary.cluster_sizes 12)
;;

let test_plan_clusters_preserves_order () =
  let agents = [ "a"; "b"; "c"; "d"; "e"; "f"; "g"; "h"; "i"; "j"; "k"; "l" ] in
  check
    (list (list string))
    "stable 12-agent partition"
    [ [ "a"; "b"; "c"; "d" ]; [ "e"; "f"; "g"; "h" ]; [ "i"; "j"; "k"; "l" ] ]
    (Boundary.plan_clusters agents)
;;

let contract
      ?(codec = Boundary.Json_text)
      ?(text_fallback = true)
      ?(version_negotiated = true)
      ?(semantics_preserved = true)
      ?(collaboration_specific = false)
      ()
  =
  { Boundary.codec
  ; text_fallback
  ; version_negotiated
  ; semantics_preserved
  ; collaboration_specific
  }
;;

let test_frame_contract () =
  check
    bool
    "json text remains admitted"
    true
    (Boundary.admits_frame_contract (contract ()));
  check
    bool
    "opaque binary requires fallback"
    false
    (Boundary.admits_frame_contract
       (contract ~codec:Boundary.Opaque_binary_frame ~text_fallback:false ()));
  check
    bool
    "native binary requires version negotiation"
    false
    (Boundary.admits_frame_contract
       (contract ~codec:Boundary.Native_binary_protocol ~version_negotiated:false ()));
  check
    bool
    "semantic drift blocks frame"
    false
    (Boundary.admits_frame_contract (contract ~semantics_preserved:false ()));
  check
    bool
    "collaboration-specific codec stays out of boundary"
    false
    (Boundary.admits_frame_contract (contract ~collaboration_specific:true ()))
;;

let () =
  run
    "Track2_sync_boundary"
    [ ( "writes"
      , [ test_case "admits only layer-owned writers" `Quick test_writer_admission ] )
    ; ( "clusters"
      , [ test_case "sizes stay within Track 2 cells" `Quick test_cluster_sizes
        ; test_case
            "partitions are deterministic"
            `Quick
            test_plan_clusters_preserves_order
        ] )
    ; ( "frames"
      , [ test_case "binary readiness is conservative" `Quick test_frame_contract ] )
    ]
;;
