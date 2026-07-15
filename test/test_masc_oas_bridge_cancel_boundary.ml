(* test/test_masc_oas_bridge_cancel_boundary.ml

   Source-level assertion test for Masc_oas_bridge cancel safety.

   The [run_safe] function in [lib/masc_oas_bridge.ml] is the central
   boundary between MASC subsystems and the OAS Agent SDK.  When an
   OAS operation is cancelled via Eio structured concurrency, the
   cancel handler MUST:

   1. Re-raise [Eio.Cancel.Cancelled] — never swallow it or convert
      it to an [Error _] result.  Swallowing breaks structured
      concurrency and can leave parent fibers waiting forever.
   2. Preserve the backtrace via [Printexc.raise_with_backtrace].
   3. Emit observability (Otel_metric_store counter + WARN/INFO log) before
      re-raising so operators see anomalous cancellations in dashboards
      without turning routine fast [Not_first] races into WARN noise.
   4. Classify wall-time into buckets (fast/short_tail/mid_tail/
      long_mid/long_tail) for bimodal distribution analysis.

   This test reads the source file and asserts these structural
   properties.  A future refactor that silently removes the reraise
   or weakens the observability will fail CI before reaching main.

   Reference: plan Phase C, PR-C2 (cancel boundary property test).
   Mirror of #10942 (keeper_llm_bridge) pattern. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let assert_contains ~label haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  if not (scan 0) then
    failwith
      (Printf.sprintf
         "[%s] expected source to contain %S — cancel boundary regression"
         label needle)

let assert_not_contains ~label haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  if scan 0 then
    failwith
      (Printf.sprintf
         "[%s] expected source NOT to contain %S — cancel boundary regression"
         label needle)

let count_occurrences haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let count = ref 0 in
  for i = 0 to h - n do
    if String.sub haystack i n = needle then incr count
  done;
  !count

let resolve_path candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None ->
    failwith
      (Printf.sprintf
         "no candidate path resolved (cwd=%s, tried: %s)"
         (Sys.getcwd ())
         (String.concat ", " candidates))

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in

  let src =
    resolve_path
      [ Filename.concat project_root "lib/masc_oas_bridge.ml"
      ; "lib/masc_oas_bridge.ml"
      ; "../lib/masc_oas_bridge.ml"
      ]
    |> read_file
  in

  (* ── cancel_reraise: core structural properties ───────────── *)

  (* B1: Eio.Cancel.Cancelled match branch exists *)
  assert_contains
    ~label:"B1: Cancelled match branch present"
    src
    "Eio.Cancel.Cancelled";

  (* B2: Cancelled is re-raised, not swallowed or returned as Error *)
  assert_contains
    ~label:"B2: Cancelled re-raised with backtrace"
    src
    "Printexc.raise_with_backtrace exn bt";

  (* B3: Backtrace is captured before reraise *)
  assert_contains
    ~label:"B3: backtrace captured via get_raw_backtrace"
    src
    "Printexc.get_raw_backtrace ()";

  (* B4: Wall time is measured before reraise *)
  assert_contains
    ~label:"B4: wall time measured"
    src
    "let wall = elapsed ()";

  (* B5: Time bucket classification uses the shared SSOT.  Literal bucket
     labels are pinned in [test_cancel_wall_bucket.ml]. *)
  assert_contains
    ~label:"B5: cancel bucket classifier SSOT"
    src
    "Cancel_wall_bucket.of_wall wall";

  (* B6: Otel_metric_store counter incremented for cancel *)
  assert_contains
    ~label:"B6: Otel_metric_store cancel counter"
    src
    "metric_oas_bridge_cancel";

  (* B7: non-routine WARN log remains before reraise *)
  assert_contains
    ~label:"B7: WARN log present for anomalous conditions"
    src
    "Log.Misc.warn";
  assert_contains
    ~label:"B7: routine cancel INFO downgrade"
    src
    "Log.Misc.info";
  assert_not_contains
    ~label:"B7: no Eio internal exception string matching"
    src
    "Eio__core__Fiber.Not_first";
  assert_contains
    ~label:"B7-caller-label"
    src
    "caller=%s wall=%.1fs bucket=%s";

  (* B8: Timeout Error is in a *separate* match branch from Cancel —
     cancel must reraise, timeout returns Error *)
  assert_contains
    ~label:"B8-timeout-branch"
    src
    "Eio.Time.Timeout";
  assert_contains
    ~label:"B8-timeout-error"
    src
    "Agent_sdk.Error.Api";

  (* ── cancel_observability ──────────────────────────────────── *)

  (* O1: Per-caller label in Otel_metric_store counter *)
  assert_contains
    ~label:"O1: caller label in cancel counter"
    src
    "(\"caller\", caller)";

  (* O2: Bucket label in Otel_metric_store counter *)
  assert_contains
    ~label:"O2: bucket label in cancel counter"
    src
    "(\"bucket\", bucket)";

  (* O3: Inner exception surfaced in log *)
  assert_contains
    ~label:"O3: inner exception in log"
    src
    "inner=%s";

  (* ── timeout_safety ────────────────────────────────────────── *)

  assert_not_contains
    ~label:"bridge has no Eio timeout wrapper"
    src
    "Eio.Time.with_timeout";
  assert_not_contains
    ~label:"bridge has no timeout budget argument"
    src
    "timeout_s";

  print_endline "test_masc_oas_bridge_cancel_boundary: OK"
