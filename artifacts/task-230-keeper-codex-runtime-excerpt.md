# task-230 bounded source evidence: keeper_codex_runtime.ml

Source: `lib/keeper/keeper_codex_runtime.ml`
Commit: `4bf56c35bb795cdae0ab91c5285d21e91183cca5`

The projection is applied before the retry oracle is measured. The resulting `projected` list is the provider-bound request, so source-projected Gate replay evidence participates in both `full_bytes` and `next_shrink_capacity_bytes`.

```ocaml
let* windowed = windowed in
let* projected =
  match source_projection with
  | None -> Ok windowed
  | Some project -> project windowed
in
(* Compute the next structural retry boundary from the exact provider-bound
   request. Source projections may append synthetic evidence (for example
   Gate replay), and that evidence is part of the request the provider
   rejected. Measuring [projected] keeps the strict comparison in
   [next_shrink_capacity_bytes] aligned with that rejected request instead
   of authorizing an identical retry from the pre-projection history. *)
let () =
  Domain_pool_ref.submit_cpu_or_inline (fun () ->
    let full_bytes =
      List.fold_left
        (fun total message ->
           total + measure_model_input_message_bytes message)
        0
        projected
    in
    let target_capacity_bytes =
      if capacity_bytes = unbounded_model_input_capacity_bytes
      then
        Keeper_turn_driver_try_provider.default_context_overflow_shrink_capacity
          ~capacity_bytes:full_bytes
      else
        Keeper_turn_driver_try_provider.default_context_overflow_shrink_capacity
          ~capacity_bytes
    in
    observed_next_shrink_capacity_bytes :=
      Runtime_model_input_tail_window.next_shrink_capacity_bytes
        ~measure_message_bytes:measure_model_input_message_bytes
        ~target_capacity_bytes
        projected)
in
Ok projected
;;
```

This is a bounded excerpt of the changed production function; the full source is retained in the same commit.
