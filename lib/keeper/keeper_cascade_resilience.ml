open Keeper_types

type cascade_resilience =
  { ok : bool
  ; cascade_name : string
  ; model_labels : string list
  ; pure_local : bool
  ; fallback_cascade : string option
  ; blocker : string option
  ; error : string option
  ; hint : string option
  }

let cascade_resilience_of_name raw_name =
  let cascade_name =
    raw_name
    |> Keeper_cascade_profile.normalize_keeper_runtime_declared_name
    |> String.trim
  in
  let model_labels, error =
    match
      Cascade_runtime.models_of_cascade_name_result
        (Cascade_name.of_string_exn cascade_name)
    with
    | Ok models -> models, None
    | Error err -> [], Some err
  in
  let fallback_cascade =
    Keeper_cascade_profile.fallback_cascade_for cascade_name
  in
  let pure_local =
    match model_labels with
    | [] -> false
    | models -> Cascade_runtime.labels_are_pure_local models
  in
  let blocker =
    match error with
    | Some _ -> Some "cascade_resolution_error"
    | None when model_labels = [] -> Some "cascade_no_candidates"
    | None
      when pure_local
           && List.length model_labels <= 1
           && Option.is_none fallback_cascade ->
      Some "pure_local_single_provider_no_fallback"
    | None -> None
  in
  let hint =
    match blocker with
    | Some "cascade_resolution_error" ->
      Some "fix active cascade.toml resolution before autonomous PR fan-out"
    | Some "cascade_no_candidates" ->
      Some "configure at least one executable provider for the keeper cascade"
    | Some "pure_local_single_provider_no_fallback" ->
      Some
        "add a non-local fallback cascade or avoid autonomous PR fan-out while \
         local-only guard is active"
    | Some blocker -> Some ("cascade resilience blocked: " ^ blocker)
    | None -> None
  in
  { ok = Option.is_none blocker
  ; cascade_name
  ; model_labels
  ; pure_local
  ; fallback_cascade
  ; blocker
  ; error
  ; hint
  }

let cascade_resilience_of_meta (meta : keeper_meta) =
  cascade_resilience_of_name (cascade_name_of_meta meta)

let cascade_resilience_error_message resilience =
  match resilience.blocker with
  | None -> None
  | Some blocker ->
    let hint =
      match resilience.hint with
      | Some value -> "; hint=" ^ value
      | None -> ""
    in
    Some
      (Printf.sprintf
         "keeper cascade_resilience failed: cascade=%s blocker=%s%s"
         resilience.cascade_name
        blocker
        hint)
