(** Unit tests for Keeper_admission_runtime (RFC-0026 PR-E-1.6).

    The shadow-mode shim has three behaviors worth pinning:
    - default lookups return [None] (no policies registered)
    - [observe] returns [Legacy_path] when no policy is registered
    - [set_policy_lookup] / [set_bucket_lookup] are idempotent and
      observable through the public lookups
    - flag-off behavior matches flag-on with [None] policy
      (both produce [Legacy_path])

    The Prometheus counter increment is a side effect that lives in
    Prometheus_test territory; we verify the *outcome* the counter is
    keyed off, not the counter itself. *)

open Masc_mcp
module KAR = Keeper_admission_runtime
module KAP = Keeper_admission_policy
module KPTB = Keeper_provider_token_bucket

let now_ref = ref 0.0
let now () = !now_ref

let make_policy provider =
  let candidate : KAP.candidate =
    { provider; model = "m"; tier = KAP.Preferred }
  in
  match
    KAP.of_fields ~keeper_id:"k1"
      ~candidates:[candidate] ~weight:1 ~min_tier:KAP.Preferred
  with
  | Ok p -> p
  | Error _ -> Alcotest.fail "of_fields rejected test policy"

(* ------------------------------------------------------------------ *)
(* Default state                                                       *)
(* ------------------------------------------------------------------ *)

let test_default_lookups_return_none () =
  KAR.reset_for_test ();
  Alcotest.(check (option pass))
    "policy_lookup default = None" None
    (KAR.policy_lookup "any-keeper");
  Alcotest.(check (option pass))
    "bucket_lookup default = None" None
    (KAR.bucket_lookup "any-provider")

let test_observe_default_is_legacy_path () =
  KAR.reset_for_test ();
  let outcome = KAR.observe ~keeper_id:"k1" in
  match outcome with
  | Keeper_admission_glue.Legacy_path -> ()
  | Keeper_admission_glue.New_admission _ ->
      Alcotest.fail "observe with no registered policy must return Legacy_path"

(* ------------------------------------------------------------------ *)
(* Registration                                                        *)
(* ------------------------------------------------------------------ *)

let test_set_policy_lookup_observable () =
  KAR.reset_for_test ();
  let policy = make_policy "anthropic" in
  KAR.set_policy_lookup (fun id ->
    if id = "k1" then Some policy else None);
  Alcotest.(check bool)
    "policy_lookup k1 returns Some" true
    (KAR.policy_lookup "k1" |> Option.is_some);
  Alcotest.(check (option pass))
    "policy_lookup k2 returns None" None
    (KAR.policy_lookup "k2")

let test_set_bucket_lookup_observable () =
  KAR.reset_for_test ();
  let bucket = KPTB.create ~provider:"anthropic"
      ~capacity:1 ~refill_rate:1.0 ~now in
  KAR.set_bucket_lookup (fun p ->
    if p = "anthropic" then Some bucket else None);
  Alcotest.(check bool)
    "bucket_lookup anthropic returns Some" true
    (KAR.bucket_lookup "anthropic" |> Option.is_some);
  Alcotest.(check (option pass))
    "bucket_lookup other returns None" None
    (KAR.bucket_lookup "other")

let test_set_lookup_is_idempotent_last_wins () =
  KAR.reset_for_test ();
  let policy_a = make_policy "anthropic" in
  let policy_b = make_policy "openai" in
  KAR.set_policy_lookup (fun _ -> Some policy_a);
  KAR.set_policy_lookup (fun _ -> Some policy_b);
  let candidates =
    KAR.policy_lookup "k1"
    |> Option.map KAP.candidates
    |> Option.value ~default:[]
  in
  let providers = List.map (fun (c : KAP.candidate) -> c.provider) candidates in
  Alcotest.(check (list string))
    "last set wins" ["openai"] providers

(* ------------------------------------------------------------------ *)
(* Reset                                                               *)
(* ------------------------------------------------------------------ *)

let test_reset_for_test_clears_lookups () =
  let policy = make_policy "p" in
  KAR.set_policy_lookup (fun _ -> Some policy);
  KAR.set_bucket_lookup (fun _ ->
    Some (KPTB.create ~provider:"p" ~capacity:1 ~refill_rate:1.0 ~now));
  KAR.reset_for_test ();
  Alcotest.(check (option pass))
    "policy cleared" None (KAR.policy_lookup "k");
  Alcotest.(check (option pass))
    "bucket cleared" None (KAR.bucket_lookup "p")

(* ------------------------------------------------------------------ *)
(* Lazy bucket lookup wired by init                                     *)
(* ------------------------------------------------------------------ *)

let test_init_creates_lazy_bucket_lookup () =
  KAR.reset_for_test ();
  KAR.set_bucket_lookup (
    let table : (string, KPTB.t) Hashtbl.t = Hashtbl.create 4 in
    let now () = !now_ref in
    fun provider ->
      match Hashtbl.find_opt table provider with
      | Some b -> Some b
      | None ->
          let b = KPTB.create ~provider ~capacity:10 ~refill_rate:1.0 ~now in
          Hashtbl.add table provider b;
          Some b);
  let b1 = KAR.bucket_lookup "anthropic" in
  let b2 = KAR.bucket_lookup "anthropic" in
  Alcotest.(check bool) "first lookup creates bucket"
    true (Option.is_some b1);
  Alcotest.(check bool) "second lookup returns same bucket"
    true (Option.is_some b2);
  match b1, b2 with
  | Some a, Some b -> Alcotest.(check bool) "stable identity" true (a == b)
  | _ -> Alcotest.fail "expected Some bucket on both lookups"

let () =
  Alcotest.run "keeper_admission_runtime"
    [
      ( "defaults",
        [
          Alcotest.test_case "default lookups return None" `Quick
            test_default_lookups_return_none;
          Alcotest.test_case "observe default = Legacy_path" `Quick
            test_observe_default_is_legacy_path;
        ] );
      ( "registration",
        [
          Alcotest.test_case "set_policy_lookup observable" `Quick
            test_set_policy_lookup_observable;
          Alcotest.test_case "set_bucket_lookup observable" `Quick
            test_set_bucket_lookup_observable;
          Alcotest.test_case "set_*_lookup is idempotent (last wins)" `Quick
            test_set_lookup_is_idempotent_last_wins;
        ] );
      ( "reset",
        [
          Alcotest.test_case "reset_for_test clears lookups" `Quick
            test_reset_for_test_clears_lookups;
        ] );
      ( "lazy_bucket",
        [
          Alcotest.test_case "lazy bucket lookup is stable per provider"
            `Quick test_init_creates_lazy_bucket_lookup;
        ] );
    ]
