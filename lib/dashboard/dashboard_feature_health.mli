(** Dashboard_feature_health — Read model for feature-flag health
    monitoring.

    Aggregates status, enablement source, and lifecycle buckets for
    every flag in {!Feature_flag_registry.all_flags} to provide a
    runtime view of which features are active, experimental, or
    deprecated. *)

(** {1 Types} *)

type feature_status =
  | Healthy
  | Warning
  | Inactive
  | Deprecated

type feature_health_item = {
  env_name : string;
  description : string;
  category : string;
  lifecycle : string;
  is_enabled : bool;
  source : string;  (** ["env"] when overridden, else ["default"]. *)
  status : feature_status;
  since : string;
}

(** {1 Enumeration} *)

val status_to_string : feature_status -> string

val lifecycle_to_status :
  Feature_flag_registry.lifecycle -> feature_status

val feature_to_health_item :
  Feature_flag_registry.flag -> feature_health_item

(** {1 Queries} *)

val get_all_features : unit -> feature_health_item list

val get_features_by_category : string -> feature_health_item list

val get_feature_categories : unit -> string list

val count_by_status :
  feature_health_item list -> feature_status -> int

(** {1 JSON output} *)

val feature_health_item_to_json :
  feature_health_item -> Yojson.Safe.t

val overview_json : feature_health_item list -> Yojson.Safe.t

val features_by_category_json :
  feature_health_item list -> Yojson.Safe.t

(** Full dashboard payload: [generated_at], [overview],
    [features_by_category], [all_features]. *)
val json : unit -> Yojson.Safe.t
