open Keeper_types

let configured_model_labels_of_meta (m : keeper_meta) : string list =
  match dedupe_keep_order (List.filter (fun s -> String.trim s <> "") m.models) with
  | _ :: _ as explicit -> explicit
  | [] ->
      let configured =
        Cascade_runtime.models_of_cascade_name
          (Keeper_cascade_profile.Runtime_name m.cascade_name)
      in
      match Keeper_benchmark_canary.recommended_model_label_for_keeper ~keeper_name:m.name with
      | Some model_label when String.trim model_label <> "" ->
          dedupe_keep_order (model_label :: configured)
      | _ -> configured
