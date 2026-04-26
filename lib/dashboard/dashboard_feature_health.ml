(** Dashboard_feature_health — read model for feature flag health monitoring.

    Aggregates feature flag status, usage patterns, and health indicators
    to provide runtime visibility into which features are active and healthy. *)

type feature_status =
  | Healthy
  | Warning
  | Inactive
  | Deprecated

type feature_health_item =
  { env_name : string
  ; description : string
  ; category : string
  ; lifecycle : string
  ; is_enabled : bool
  ; source : string (* "env" or "default" *)
  ; status : feature_status
  ; since : string
  }

let status_to_string = function
  | Healthy -> "healthy"
  | Warning -> "warning"
  | Inactive -> "inactive"
  | Deprecated -> "deprecated"
;;

let lifecycle_to_status = function
  | Feature_flag_registry.Active -> Healthy
  | Feature_flag_registry.Experimental -> Warning
  | Feature_flag_registry.Deprecated _ -> Deprecated
;;

let feature_to_health_item (flag : Feature_flag_registry.flag) : feature_health_item =
  let is_enabled = Feature_flag_registry.runtime_value flag in
  let source = Feature_flag_registry.runtime_source flag in
  let lifecycle_str = Feature_flag_registry.lifecycle_to_string flag.lifecycle in
  let status =
    match flag.lifecycle with
    | Feature_flag_registry.Deprecated _ -> Deprecated
    | Feature_flag_registry.Experimental -> Warning
    | Feature_flag_registry.Active -> if is_enabled then Healthy else Inactive
  in
  { env_name = flag.env_name
  ; description = flag.description
  ; category = flag.category
  ; lifecycle = lifecycle_str
  ; is_enabled
  ; source
  ; status
  ; since = flag.since
  }
;;

let get_all_features () : feature_health_item list =
  List.map feature_to_health_item Feature_flag_registry.all_flags
;;

let get_features_by_category category : feature_health_item list =
  Feature_flag_registry.all_flags
  |> List.filter (fun f -> f.Feature_flag_registry.category = category)
  |> List.map feature_to_health_item
;;

let get_feature_categories () : string list =
  Feature_flag_registry.all_flags
  |> List.map (fun f -> f.Feature_flag_registry.category)
  |> List.sort_uniq String.compare
;;

let count_by_status (features : feature_health_item list) status : int =
  List.filter (fun f -> f.status = status) features |> List.length
;;

let feature_health_item_to_json (item : feature_health_item) : Yojson.Safe.t =
  `Assoc
    [ "env_name", `String item.env_name
    ; "description", `String item.description
    ; "category", `String item.category
    ; "lifecycle", `String item.lifecycle
    ; "is_enabled", `Bool item.is_enabled
    ; "source", `String item.source
    ; "status", `String (status_to_string item.status)
    ; "since", `String item.since
    ]
;;

let overview_json (features : feature_health_item list) : Yojson.Safe.t =
  let total = List.length features in
  let healthy_count = count_by_status features Healthy in
  let warning_count = count_by_status features Warning in
  let inactive_count = count_by_status features Inactive in
  let deprecated_count = count_by_status features Deprecated in
  let enabled_count = List.filter (fun f -> f.is_enabled) features |> List.length in
  let overridden_count =
    List.filter (fun f -> f.source = "env") features |> List.length
  in
  `Assoc
    [ "total_features", `Int total
    ; "healthy_count", `Int healthy_count
    ; "warning_count", `Int warning_count
    ; "inactive_count", `Int inactive_count
    ; "deprecated_count", `Int deprecated_count
    ; "enabled_count", `Int enabled_count
    ; "overridden_count", `Int overridden_count
    ]
;;

let features_by_category_json (features : feature_health_item list) : Yojson.Safe.t =
  let categories = get_feature_categories () in
  let category_data =
    List.map
      (fun category ->
         let category_features = List.filter (fun f -> f.category = category) features in
         let enabled =
           List.filter (fun f -> f.is_enabled) category_features |> List.length
         in
         ( category
         , `Assoc
             [ "total", `Int (List.length category_features)
             ; "enabled", `Int enabled
             ; "features", `List (List.map feature_health_item_to_json category_features)
             ] ))
      categories
  in
  `Assoc category_data
;;

let json () : Yojson.Safe.t =
  let features = get_all_features () in
  `Assoc
    [ "generated_at", `Float (Time_compat.now ())
    ; "overview", overview_json features
    ; "features_by_category", features_by_category_json features
    ; "all_features", `List (List.map feature_health_item_to_json features)
    ]
;;
