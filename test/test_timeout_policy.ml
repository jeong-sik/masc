(* test/test_timeout_policy.ml

   Covers Timeout_policy.Deadline arithmetic and overshoot_warn gating.
   Related to masc-mcp#9639 (timeout SSOT meta) and #9662 (keeper_llm_bridge
   ~24s overshoot).

   overshoot_warn returns [true] exactly when actual_wall_s > cap + slack.
   The surrounding log side effect is not asserted; we rely on the boolean
   return as the observable signal so the test stays deterministic. *)

open Masc_mcp

let assert_eq_float ~epsilon ~msg expected got =
  if Float.abs (expected -. got) > epsilon
  then failwith (Printf.sprintf "%s: expected=%.6f got=%.6f" msg expected got)
;;

let assert_true msg b = if not b then failwith msg
let assert_false msg b = if b then failwith msg

let mk_deadline ~cap ~at =
  Timeout_policy.Deadline.make
    ~layer:Timeout_policy.Layer.Oas_bridge
    ~origin:"test"
    ~wall_cap_s:cap
    ~now:at
;;

let test_layer_to_string () =
  let pairs =
    [ Timeout_policy.Layer.Tool, "tool"
    ; Timeout_policy.Layer.Oas_bridge, "oas_bridge"
    ; Timeout_policy.Layer.Keeper_turn, "keeper_turn"
    ; Timeout_policy.Layer.Keeper_cycle, "keeper_cycle"
    ; Timeout_policy.Layer.Shutdown, "shutdown"
    ]
  in
  List.iter
    (fun (l, s) ->
       let got = Timeout_policy.Layer.to_string l in
       if got <> s
       then failwith (Printf.sprintf "Layer.to_string mismatch: expected=%s got=%s" s got))
    pairs
;;

let test_deadline_arithmetic () =
  let d = mk_deadline ~cap:60.0 ~at:1000.0 in
  assert_eq_float
    ~epsilon:1e-6
    ~msg:"elapsed at t+0"
    0.0
    (Timeout_policy.Deadline.elapsed d ~now:1000.0);
  assert_eq_float
    ~epsilon:1e-6
    ~msg:"elapsed at t+15"
    15.0
    (Timeout_policy.Deadline.elapsed d ~now:1015.0);
  assert_eq_float
    ~epsilon:1e-6
    ~msg:"remaining at t+0"
    60.0
    (Timeout_policy.Deadline.remaining d ~now:1000.0);
  assert_eq_float
    ~epsilon:1e-6
    ~msg:"remaining at t+70 (negative)"
    (-10.0)
    (Timeout_policy.Deadline.remaining d ~now:1070.0)
;;

let test_overshoot_warn_gating () =
  let d = mk_deadline ~cap:60.0 ~at:0.0 in
  (* within cap: no warn *)
  assert_false
    "within cap should not warn"
    (Timeout_policy.overshoot_warn ~slack_s:5.0 ~deadline:d ~actual_wall_s:55.0 ());
  (* exactly at cap: no warn *)
  assert_false
    "at cap should not warn"
    (Timeout_policy.overshoot_warn ~slack_s:5.0 ~deadline:d ~actual_wall_s:60.0 ());
  (* within slack: no warn *)
  assert_false
    "within slack should not warn"
    (Timeout_policy.overshoot_warn ~slack_s:5.0 ~deadline:d ~actual_wall_s:64.9 ());
  (* at slack boundary: no warn (excess must be strictly greater than slack) *)
  assert_false
    "at slack boundary should not warn"
    (Timeout_policy.overshoot_warn ~slack_s:5.0 ~deadline:d ~actual_wall_s:65.0 ());
  (* beyond slack: warn *)
  assert_true
    "beyond slack should warn"
    (Timeout_policy.overshoot_warn ~slack_s:5.0 ~deadline:d ~actual_wall_s:65.1 ());
  (* Regression case from #9662: 596.6s on a 573s cap. *)
  let d_9662 = mk_deadline ~cap:573.0 ~at:0.0 in
  assert_true
    "#9662 regression (596.6 > 573+5) must warn"
    (Timeout_policy.overshoot_warn ~slack_s:5.0 ~deadline:d_9662 ~actual_wall_s:596.6 ())
;;

let test_overshoot_default_slack () =
  let d = mk_deadline ~cap:60.0 ~at:0.0 in
  (* default slack = 5s: cap=60, actual=64 → no warn *)
  assert_false
    "default slack respects cap+slack lower bound"
    (Timeout_policy.overshoot_warn ~deadline:d ~actual_wall_s:64.0 ());
  assert_true
    "default slack fires beyond cap+5"
    (Timeout_policy.overshoot_warn ~deadline:d ~actual_wall_s:70.0 ())
;;

let () =
  test_layer_to_string ();
  test_deadline_arithmetic ();
  test_overshoot_warn_gating ();
  test_overshoot_default_slack ();
  print_endline "test_timeout_policy: OK"
;;
