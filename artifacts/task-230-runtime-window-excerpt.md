# task-230 bounded source evidence: runtime_model_input_tail_window.ml

Source: `lib/runtime/runtime_model_input_tail_window.ml`
Commit: `4bf56c35bb795cdae0ab91c5285d21e91183cca5`

The retry boundary measures the exact `messages` argument and accepts a boundary only when it is strictly smaller than the rejected provider window.

```ocaml
let next_shrink_capacity_bytes
    ~measure_message_bytes
    ~target_capacity_bytes
    messages =
  let rejected_window_bytes =
    List.fold_left
      (fun total message -> total + measure_message_bytes message)
      0
      messages
  in
  let shrinkable_messages =
    List.filter (fun message -> not (is_synthetic_preamble message)) messages
  in
  let labelled, atom_count = annotate shrinkable_messages in
  if atom_count <= 1
  then None
  else (
    let pinned_bytes =
      List.fold_left
        (fun total (message, label) ->
           match label with
           | Pinned -> total + measure_message_bytes message
           | Atom _ -> total)
        0
        labelled
    in
    let preamble_bytes = measure_message_bytes preamble_message in
    let undroppable_bytes = pinned_bytes + preamble_bytes in
    let _, suffix =
      atom_suffix_bytes ~measure_message_bytes ~atom_count labelled
    in
    let full_atom_bytes = suffix.(0) in
    let target_atom_bytes = target_capacity_bytes - undroppable_bytes in
    let required_atom_capacity bytes = max 1 bytes in
    let rec first_boundary_at_or_below_target drop =
      if drop >= atom_count
      then None
      else (
        let retained = required_atom_capacity suffix.(drop) in
        if retained < full_atom_bytes && retained <= target_atom_bytes
        then Some retained
        else first_boundary_at_or_below_target (drop + 1))
    in
    let newest_atom_bytes =
      required_atom_capacity suffix.(atom_count - 1)
    in
    let retained_atom_bytes =
      match first_boundary_at_or_below_target 1 with
      | Some bytes -> Some bytes
      | None when newest_atom_bytes < full_atom_bytes ->
        Some newest_atom_bytes
      | None -> None
    in
    Option.bind retained_atom_bytes (fun retained ->
      let framed_capacity = undroppable_bytes + retained in
      if framed_capacity < rejected_window_bytes
      then Some framed_capacity
      else None))
;;
```

The strict comparison is evaluated against the provider-bound `messages` list supplied by the caller.
