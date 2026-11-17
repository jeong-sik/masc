let prefix = ".atomic_"
let suffix = ".tmp"

let private_jsonl_stage_prefix = ".private_jsonl_"
let private_jsonl_stage_suffix = ".stage"

(* The name a private JSONL replacement is created under, before its lease is
   held. The reclaimer reclaims a stage file it cannot confirm as held, so a
   replacement must not carry a stage name during the window between creating
   the file and taking the lease: the reclaimer could take a live writer's file
   there. This name matches neither [is_atomic_tmp_name] nor
   [is_private_jsonl_stage_name], which is what keeps it out of the sweep; the
   file is renamed onto its destination without ever becoming a stage file. *)
let private_jsonl_holding_prefix = ".private_jsonl_holding_"
let private_jsonl_holding_suffix = ".holding"

let has_prefix_and_suffix ~prefix ~suffix name =
  String.length name >= String.length prefix + String.length suffix
  && String.starts_with name ~prefix
  && String.ends_with ~suffix name
;;

let is_atomic_tmp_name name =
  has_prefix_and_suffix ~prefix ~suffix name
;;

let is_private_jsonl_stage_name name =
  has_prefix_and_suffix
    ~prefix:private_jsonl_stage_prefix
    ~suffix:private_jsonl_stage_suffix
    name
;;

let is_name name =
  is_atomic_tmp_name name || is_private_jsonl_stage_name name
;;
