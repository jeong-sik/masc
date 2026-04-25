(** #10388 — pin the keeper-assignable cascade fail-fast contract.

    Pre-fix four keepers (masc-improver, sangsu, ramarama,
    ollama-local) referenced cascade names that were marked
    [keeper_assignable=false] in cascade.toml.  No layer rejected
    the binding up-front — the violations surfaced only at
    bootstrap or downstream as a mix of "active cascade source
    could not be loaded", silent fall-through, and 19-min ollama
    walls.  About 144 ERRORs/day (~33.7% of fleet ERROR) lived
    in this drift class.

    [Keeper_cascade_profile.is_system_only_cascade] already
    encoded the policy but no caller wired it to the keeper
    bootstrap.  This module pins:

    1. [is_system_only_cascade] returns [true] for a profile
       declared with [keeper_assignable=false].
    2. Returns [false] for a profile declared with
       [keeper_assignable=true] (and for the explicit-default
       case where the field is omitted, which the loader treats
       as [true]).
    3. Returns [false] for a name absent from the catalog.
    4. Trims surrounding whitespace before lookup.
    5. The dedicated rejection counter
       [masc_keeper_cascade_assignment_rejection_total] exists
       in the metric vocabulary so dashboards can subscribe by
       name rather than typo. *)

open Alcotest

module KCP = Masc_mcp.Keeper_cascade_profile

let counter = ref 0

let mk_fixture () =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "cascade_assignable_10388_%d_%d_%.0f" !counter
         (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o755;
  let path = Filename.concat dir "cascade.json" in
  let oc = open_out path in
  output_string oc
    {|{
  "assignable_one_models": [{"model": "openai:gpt", "weight": 1}],
  "assignable_one_keeper_assignable": true,
  "system_only_one_models": [{"model": "openai:gpt", "weight": 1}],
  "system_only_one_keeper_assignable": false,
  "implicit_default_models": [{"model": "openai:gpt", "weight": 1}]
}|};
  close_out oc;
  (dir, path)

let rec rm_rf p =
  if Sys.file_exists p then
    if Sys.is_directory p then (
      Sys.readdir p |> Array.iter (fun n -> rm_rf (Filename.concat p n));
      Unix.rmdir p)
    else Sys.remove p

(* --- 1. system-only profile is detected --- *)

let test_system_only_returns_true () =
  let dir, path = mk_fixture () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      check bool "system_only_one is system-only" true
        (KCP.is_system_only_cascade ~config_path:path "system_only_one"))

(* --- 2. keeper_assignable=true → not system-only --- *)

let test_assignable_returns_false () =
  let dir, path = mk_fixture () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      check bool "assignable_one is not system-only" false
        (KCP.is_system_only_cascade ~config_path:path "assignable_one"))

(* --- 2b. omitted field defaults to assignable --- *)

let test_implicit_default_returns_false () =
  let dir, path = mk_fixture () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      check bool
        "profile without explicit keeper_assignable defaults to assignable"
        false
        (KCP.is_system_only_cascade ~config_path:path "implicit_default"))

(* --- 3. unknown profile returns false (no spurious veto) --- *)

let test_unknown_returns_false () =
  let dir, path = mk_fixture () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      check bool "absent profile is not flagged system-only" false
        (KCP.is_system_only_cascade ~config_path:path "ghost_profile"))

(* --- 4. surrounding whitespace is trimmed --- *)

let test_whitespace_trimmed () =
  let dir, path = mk_fixture () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      check bool "leading/trailing whitespace ignored" true
        (KCP.is_system_only_cascade ~config_path:path
           "  system_only_one  "))

(* --- 5. dedicated rejection counter exists --- *)

let test_rejection_counter_in_vocab () =
  check string "metric name uses the masc_ prefix"
    "masc_keeper_cascade_assignment_rejection_total"
    Masc_mcp.Prometheus.metric_keeper_cascade_assignment_rejection;
  let labels =
    [ ("keeper", "ghost"); ("cascade", "ghost"); ("reason", "system_only") ]
  in
  let before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_keeper_cascade_assignment_rejection
      ~labels ()
  in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Prometheus.metric_keeper_cascade_assignment_rejection
    ~labels ();
  let after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_keeper_cascade_assignment_rejection
      ~labels ()
  in
  check (float 0.0001) "counter increments by 1" (before +. 1.0) after

let () =
  run "cascade_keeper_assignable_10388"
    [
      ( "is_system_only_cascade",
        [
          test_case "system-only profile returns true" `Quick
            test_system_only_returns_true;
          test_case "assignable profile returns false" `Quick
            test_assignable_returns_false;
          test_case "implicit default treated as assignable" `Quick
            test_implicit_default_returns_false;
          test_case "unknown profile returns false" `Quick
            test_unknown_returns_false;
          test_case "whitespace is trimmed" `Quick test_whitespace_trimmed;
        ] );
      ( "rejection-counter",
        [
          test_case "metric name + increment" `Quick
            test_rejection_counter_in_vocab;
        ] );
    ]
