(* Pins the host rejection arm for Apple Container: Intel macOS is rejected
   before any inventory probe runs. The wildcard-expansion codemod dropped the
   Macos X64 arm, so Intel hosts fell through to the live service probe and
   saw probe failures instead of the unsupported-host answer. *)

module S = Masc.Sandbox_readiness

let dummy_run : S.runner = fun _ -> Error S.Command_failed

let () =
  let entry =
    S.probe ~host:(S.Macos { architecture = S.X64; major = 26 }) ~run:dummy_run
      ~require_rootless:false ~require_userns:false S.Apple_container
  in
  (match entry.S.state with
   | S.Unsupported_host reason ->
     Alcotest.(check string)
       "intel macos is rejected without probing the service"
       "Apple Container requires Apple Silicon and macOS 26 or newer" reason
   | other ->
     Alcotest.failf "expected Unsupported_host on an Intel mac, got %s"
       (match other with
        | S.Service_ready -> "Service_ready"
        | S.Missing_prerequisite _ -> "Missing_prerequisite"
        | S.Unsupported_host _ -> "Unsupported_host"
        | S.Unsupported_capability _ -> "Unsupported_capability"
        | S.Probe_failed _ -> "Probe_failed"
        | S.Needs_configuration _ -> "Needs_configuration"))
;;
