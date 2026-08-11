# task-230 bounded regression evidence: test_runtime_model_input_tail_window.ml

Source: `test/test_runtime_model_input_tail_window.ml`
Commit: `4bf56c35bb795cdae0ab91c5285d21e91183cca5`

The regression compares the pre-projection history with the provider-bound history after Gate replay evidence is appended.

```ocaml
let test_next_shrink_accounts_for_gate_replay_projection () =
  (* Gate replay is a source projection: it appends a User evidence message
     after the bounded history. The rejected request is therefore larger than
     the pre-projection [windowed] list used by the old oracle. *)
  let oldest = padded ~role:Types.User ~tag:"oldest|" 100 in
  let newest = padded ~role:Types.Assistant ~tag:"newest|" 600 in
  let replay_evidence = padded ~role:Types.User ~tag:"gate-replay|" 500 in
  let pre_projection = [ oldest; newest ] in
  let provider_bound = pre_projection @ [ replay_evidence ] in
  let target_capacity_bytes = 700 in
  let pre_projection_boundary =
    Window.next_shrink_capacity_bytes
      ~measure_message_bytes
      ~target_capacity_bytes
      pre_projection
  in
  let provider_bound_boundary =
    Window.next_shrink_capacity_bytes
      ~measure_message_bytes
      ~target_capacity_bytes
      provider_bound
  in
  Alcotest.(check (option int))
    "pre-projection history has no safe framed retry"
    None
    pre_projection_boundary;
  match provider_bound_boundary with
  | None -> Alcotest.fail "provider-bound replay evidence must retain a safe retry"
  | Some capacity_bytes ->
    Alcotest.(check bool)
      "retry is smaller than the provider-bound rejected request"
      true
      (capacity_bytes < total_bytes provider_bound);
    let projected =
      ok_exn
        ~what:"provider-bound replay shrink"
        (project ~capacity_bytes provider_bound)
    in
    fits_budget ~capacity_bytes ~reserved_bytes:0 projected
;;
```

The test proves that the larger provider-bound request gets a strictly smaller safe retry boundary while the pre-projection oracle returns `None`.
