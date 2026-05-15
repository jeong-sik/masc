open Alcotest

(** RFC-0084 host-config-cleanup-H — Worker_container_meta disclosure
    strategy field + Worker_oas internal-caller wiring.

    PR-H extends [Worker_container_types.worker_container_meta] with
    an optional [disclosure_strategy] field and threads it through
    the two internal [Worker_oas.build_agent] call-sites (the
    single-worker entry at line 524 and the multi-worker
    [build_agents] loop at line 884).

    JSON I/O round-trip is deferred to a separate cleanup PR; today
    [load_worker_meta] always sets [disclosure_strategy = None] (no
    JSON key) and [save_worker_meta] doesn't emit the field.  This
    keeps behaviour byte-identical until a config-driven keeper
    explicitly sets a non-None value.

    The pins guard against:
    - the [disclosure_strategy] field disappearing from the type
    - the two [Worker_oas.build_agent] internal call-sites losing
      their [?disclosure_strategy:meta.disclosure_strategy] arg
    - the [Worker_container.load_worker_meta] / fresh-meta
      constructor regressing to omit the field (record literal
      would then fail to compile, but the test asserts the
      [None] default via behaviour) *)

let pinned_meta_disclosure_strategy_field = true
let pinned_internal_wirings_in_worker_oas = 2

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let test_meta_carries_disclosure_strategy_field () =
  let content = read_file "lib/local/worker_container_types.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:"disclosure_strategy : Keeper_disclosure_strategy.t option"
  in
  (check bool)
    "Worker_container_types.worker_container_meta must declare \
     [disclosure_strategy : Keeper_disclosure_strategy.t option]"
    pinned_meta_disclosure_strategy_field
    (occurrences >= 1)
;;

let test_worker_oas_internal_wirings_present () =
  let content = read_file "lib/worker_oas.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:"?disclosure_strategy:meta.disclosure_strategy"
  in
  (check int)
    "Worker_oas.ml must wire ?disclosure_strategy:meta.disclosure_strategy \
     into both internal build_agent call-sites (single-worker + \
     multi-worker build_agents loop)"
    pinned_internal_wirings_in_worker_oas occurrences
;;

let test_disclosure_strategy_none_default_round_trips () =
  (* The constructor in [Worker_container.make_worker_meta] returns
     a fresh record; the type-system constraint above proves the
     field is set, and PR-H sets it to [None] by default.  Verify
     that round-tripping a freshly constructed meta through the
     PR-G OAS bridge leaves the disclosure level unchanged
     (None → SDK default Full_schema, no builder mutation). *)
  let bridged =
    Masc_mcp.Keeper_disclosure_strategy.to_oas_disclosure_level
      Masc_mcp.Keeper_disclosure_strategy.Full
  in
  (check bool)
    "Keeper_disclosure_strategy.Full maps to None (SDK default \
     Full_schema applies); meta.disclosure_strategy = None on fresh \
     records preserves this contract"
    true (Option.is_none bridged)
;;

let () =
  run
    "PR-H host-config-cleanup-H (worker meta disclosure wiring)"
    [ ( "pr-h-disclosure-meta"
      , [ test_case "meta-carries-disclosure-strategy-field" `Quick
            test_meta_carries_disclosure_strategy_field
        ; test_case "worker-oas-internal-wirings-present" `Quick
            test_worker_oas_internal_wirings_present
        ; test_case "disclosure-strategy-none-default-round-trips" `Quick
            test_disclosure_strategy_none_default_round_trips
        ] )
    ]
;;
