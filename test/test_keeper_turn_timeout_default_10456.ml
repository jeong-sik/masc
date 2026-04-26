(** #10456 — pin {!Env_config_keeper.KeeperKeepalive.turn_timeout_sec}
    SSOT default (3600) and the source literal in
    {!Keeper_runtime_resolved.turn_timeout_sec_live}.

    Pre-fix drift was:
    - env_config_keeper:301 default=3600 (post-#9637)
    - keeper_runtime_resolved:75 default=1200 (stale)

    Math: 1200 - 30 (oas_timeout_guard_sec) = 1170s — exact match for
    #10388 cascade ollama timeout walls.

    This test pins the SSOT and source-level literal so silent
    re-divergence shows up as a test failure. *)

open Alcotest

module E = Env_config_keeper.KeeperKeepalive

let approx = float 0.001

let test_ssot_default_3600 () =
  check approx
    "env_config_keeper.KeeperKeepalive.turn_timeout_sec SSOT must stay at 3600 (#9637)"
    3600.0 E.turn_timeout_sec

let resolver_source_path =
  let candidates =
    [
      "lib/keeper/keeper_runtime_resolved.ml";
      "../lib/keeper/keeper_runtime_resolved.ml";
      "../../lib/keeper/keeper_runtime_resolved.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> Some p
  | None -> None

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let test_resolver_default_matches_ssot () =
  match resolver_source_path with
  | None -> skip ()
  | Some p ->
      let body = read_file p in
      (* The fix replaces default:1200.0 with default:3600.0 in
         turn_timeout_sec_live. Guard: must NOT contain the stale literal
         on the same line as MASC_KEEPER_TURN_TIMEOUT_SEC. *)
      let stale_pattern = "~default:1200.0 \"MASC_KEEPER_TURN_TIMEOUT_SEC\"" in
      let canonical_pattern =
        "~default:3600.0 \"MASC_KEEPER_TURN_TIMEOUT_SEC\""
      in
      let contains s sub =
        let n = String.length s and m = String.length sub in
        let rec loop i =
          if i + m > n then false
          else if String.sub s i m = sub then true
          else loop (i + 1)
        in
        loop 0
      in
      let has_stale = contains body stale_pattern in
      let has_canonical = contains body canonical_pattern in
      check bool "no stale 1200 default in resolver" false has_stale;
      check bool "canonical 3600 default in resolver" true has_canonical

let test_resolver_upper_matches_ssot () =
  match resolver_source_path with
  | None -> skip ()
  | Some p ->
      let body = read_file p in
      (* The fix raises Float.min upper bound from 3600.0 to 7200.0 in
         turn_timeout_sec_live block. Both 3600.0 and 7200.0 may appear
         elsewhere; we just guard that 7200.0 is present after the fix. *)
      let canonical_upper = "Float.min 7200.0" in
      let contains s sub =
        let n = String.length s and m = String.length sub in
        let rec loop i =
          if i + m > n then false
          else if String.sub s i m = sub then true
          else loop (i + 1)
        in
        loop 0
      in
      check bool "canonical 7200 upper bound in resolver" true
        (contains body canonical_upper)

let () =
  run "keeper_turn_timeout_default_10456"
    [
      ( "ssot-pin",
        [
          test_case "env_config_keeper SSOT default is 3600 (post-#9637)"
            `Quick test_ssot_default_3600;
        ] );
      ( "resolver-drift-gate",
        [
          test_case "resolver default literal matches SSOT (no 1200 drift)"
            `Quick test_resolver_default_matches_ssot;
          test_case "resolver upper bound literal matches SSOT (7200)" `Quick
            test_resolver_upper_matches_ssot;
        ] );
    ]
