open Keeper_types

let configured_model_labels_of_meta (m : keeper_meta) : string list =
  match dedupe_keep_order (List.filter (fun s -> String.trim s <> "") m.models) with
  | _ :: _ as explicit -> explicit
  | [] -> Cascade_runtime.models_of_cascade_name m.cascade_name
