let prefix = ".atomic_"
let suffix = ".tmp"

let private_jsonl_prep_prefix = ".private_jsonl_prep_"
let private_jsonl_prep_suffix = ".prep"

let private_jsonl_stage_prefix = ".private_jsonl_"
let private_jsonl_stage_suffix = ".stage"

let has_prefix_and_suffix ~prefix ~suffix name =
  String.length name >= String.length prefix + String.length suffix
  && String.starts_with name ~prefix
  && String.ends_with ~suffix name
;;

let is_atomic_tmp_name name =
  has_prefix_and_suffix ~prefix ~suffix name
;;

let is_private_jsonl_prep_name name =
  has_prefix_and_suffix
    ~prefix:private_jsonl_prep_prefix
    ~suffix:private_jsonl_prep_suffix
    name
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
