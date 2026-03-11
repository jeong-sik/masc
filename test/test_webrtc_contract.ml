open Alcotest

module Webrtc_datachannel = Masc_mcp.Webrtc_datachannel

let test_init_always_uses_stub_backend () =
  let backend = Webrtc_datachannel.init ~prefer_native:true () in
  check string "active backend is stub" "stub (simulation)"
    (Webrtc_datachannel.string_of_backend backend);
  Webrtc_datachannel.cleanup ()

let test_backend_labels_are_truthful () =
  check string "stub label" "stub (simulation)"
    (Webrtc_datachannel.string_of_backend Webrtc_datachannel.Stub);
  check string "native label" "native (reserved)"
    (Webrtc_datachannel.string_of_backend Webrtc_datachannel.Native)

let () =
  run "webrtc contract"
    [
      ("init", [ test_case "init returns stub" `Quick test_init_always_uses_stub_backend ]);
      ("labels", [ test_case "labels match truth" `Quick test_backend_labels_are_truthful ]);
    ]
