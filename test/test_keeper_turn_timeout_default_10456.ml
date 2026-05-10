(** #10456/#10716 — pin {!Env_config_keeper.KeeperKeepalive.turn_timeout_sec}
    SSOT default (600) and opt-in ceiling (900) source literals in
    {!Keeper_runtime_resolved.turn_timeout_sec_live}.

    Original pre-fix drift was:
    - env_config_keeper:301 default=3600 (post-#9637)
    - keeper_runtime_resolved:75 default=1200 (stale)

    Math: 1200 - 30 (oas_timeout_guard_sec) = 1170s — exact match for
    #10388 cascade ollama timeout walls.

    The audit hard-ceiling pass later lowered the SSOT default to 600 so the
    keeper turn envelope cannot hide long OAS provider stalls. RFC-0012/0022
    then lifted only the opt-in hard ceiling to 900 so local-LLM cascades can
    opt in without changing the checked-in remote default.

    This test pins the SSOT, source-level literal, and generated env snapshot
    so silent re-divergence shows up as a test failure. *)

open Alcotest

module E = Env_config_keeper.KeeperKeepalive

let approx = float 0.001

let test_ssot_default_600 () =
  check approx
    "env_config_keeper.KeeperKeepalive.turn_timeout_sec SSOT must stay at 600"
    600.0 E.turn_timeout_sec

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

let snapshot_source_path =
  let candidates =
    [
      "lib/config/env_config_snapshot.ml";
      "../lib/config/env_config_snapshot.ml";
      "../../lib/config/env_config_snapshot.ml";
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

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec loop i =
    if i + m > n then false
    else if String.sub s i m = sub then true
    else loop (i + 1)
  in
  loop 0

let test_resolver_default_matches_ssot () =
  match resolver_source_path with
  | None -> skip ()
  | Some p ->
      let body = read_file p in
      (* The fix replaces stale long defaults with default:600.0 in
         turn_timeout_sec_live. Guard: must NOT contain the stale literal
         on the same line as MASC_KEEPER_TURN_TIMEOUT_SEC. *)
      let stale_pattern = "~default:1200.0 \"MASC_KEEPER_TURN_TIMEOUT_SEC\"" in
      let stale_3600_pattern =
        "~default:3600.0 \"MASC_KEEPER_TURN_TIMEOUT_SEC\""
      in
      let canonical_pattern =
        "~default:600.0 \"MASC_KEEPER_TURN_TIMEOUT_SEC\""
      in
      let has_stale = contains body stale_pattern in
      let has_stale_3600 = contains body stale_3600_pattern in
      let has_canonical = contains body canonical_pattern in
      check bool "no stale 1200 default in resolver" false has_stale;
      check bool "no stale 3600 default in resolver" false has_stale_3600;
      check bool "canonical 600 default in resolver" true has_canonical

let test_resolver_upper_matches_ssot () =
  match resolver_source_path with
  | None -> skip ()
  | Some p ->
      let body = read_file p in
      (* The resolver must keep the same 900s opt-in hard ceiling as
         Env_config_keeper.KeeperKeepalive.timeout_hard_ceiling_sec while
         preserving the 600s default checked above. *)
      let canonical_upper = "Float.min 900.0" in
      check bool "canonical 900 upper bound in resolver" true
        (contains body canonical_upper)

let test_snapshot_default_matches_ssot () =
  match snapshot_source_path with
  | None -> skip ()
  | Some p ->
      let body = read_file p in
      let stale_default =
        "entry ~default:\"3600.0\" \"MASC_KEEPER_TURN_TIMEOUT_SEC\""
      in
      let stale_range =
        "Wall-clock timeout for a single unified turn (clamped 60-7200 seconds)"
      in
      let canonical_default =
        "entry ~default:\"600.0\" \"MASC_KEEPER_TURN_TIMEOUT_SEC\""
      in
      let canonical_range =
        "Wall-clock timeout for a single unified turn (clamped 60-900 seconds)"
      in
      check bool "no stale 3600 default in env snapshot" false
        (contains body stale_default);
      check bool "no stale 7200 range in env snapshot" false
        (contains body stale_range);
      check bool "canonical 600 default in env snapshot" true
        (contains body canonical_default);
      check bool "canonical 60-900 range in env snapshot" true
        (contains body canonical_range)

let () =
  run "keeper_turn_timeout_default_10456"
    [
      ( "ssot-pin",
        [
          test_case "env_config_keeper SSOT default is 600"
            `Quick test_ssot_default_600;
        ] );
      ( "resolver-drift-gate",
        [
          test_case "resolver default literal matches SSOT (no 1200 drift)"
            `Quick test_resolver_default_matches_ssot;
          test_case "resolver upper bound literal matches SSOT (900)" `Quick
            test_resolver_upper_matches_ssot;
        ] );
      ( "snapshot-drift-gate",
        [
          test_case "env config snapshot matches keeper turn timeout SSOT"
            `Quick test_snapshot_default_matches_ssot;
        ] );
    ]
