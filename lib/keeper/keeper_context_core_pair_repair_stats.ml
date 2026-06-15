(** Tool-pair repair stats and metadata helpers.

    Counters and message-metadata bookkeeping for the
    [repair_*_tool_*] family in [Keeper_context_core]. The repair
    bodies themselves stay in the parent (they depend on the
    Pure record / metadata helpers — no parent-local state, no I/O,
    no callback injection. *)

type tool_pair_repair_stats =
  { dropped_tool_uses : int
  ; dropped_tool_results : int
  ; dropped_tool_use_samples : (string * string) list
  ; dropped_tool_result_ids : string list
  }

let empty_tool_pair_repair_stats =
  {
    dropped_tool_uses = 0;
    dropped_tool_results = 0;
    dropped_tool_use_samples = [];
    dropped_tool_result_ids = [];
  }

let sample_cap = 8
let pair_repair_diagnostic_max_bytes = 256

let bound_pair_repair_diagnostic_string value =
  value
  |> String.trim
  |> Inference_utils.sanitize_text_utf8
  |> String_util.utf8_prefix ~max_bytes:pair_repair_diagnostic_max_bytes

let take_bounded n items =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop n [] items

let bounded_tool_use_samples samples =
  samples
  |> List.map (fun (tool_use_id, tool_name) ->
    ( bound_pair_repair_diagnostic_string tool_use_id
    , bound_pair_repair_diagnostic_string tool_name ))
  |> take_bounded sample_cap

let bounded_tool_result_ids ids =
  ids |> List.map bound_pair_repair_diagnostic_string |> take_bounded sample_cap

let add_tool_pair_repair_stats left right =
  { dropped_tool_uses =
      left.dropped_tool_uses + right.dropped_tool_uses
  ; dropped_tool_results =
      left.dropped_tool_results + right.dropped_tool_results
  ; dropped_tool_use_samples =
      bounded_tool_use_samples
        (left.dropped_tool_use_samples @ right.dropped_tool_use_samples)
  ; dropped_tool_result_ids =
      bounded_tool_result_ids
        (left.dropped_tool_result_ids @ right.dropped_tool_result_ids)
  }

let tool_pair_repair_stats_changed stats =
  stats.dropped_tool_uses > 0 || stats.dropped_tool_results > 0

let pair_repair_metadata_key = "masc.tool_pair_repair"

let pair_repair_metadata_keys =
  [
    "was_fabricated";
    "fabrication_source";
    "was_repaired";
    "repair_source";
    pair_repair_metadata_key;
  ]

let tool_use_sample_to_json (tool_use_id, tool_name) =
  `Assoc [ "tool_use_id", `String tool_use_id; "tool_name", `String tool_name ]

let with_pair_repair_metadata
    ?(tool_use_samples = [])
    ?(tool_result_ids = [])
    ~kind
    ~count
    (msg : Agent_sdk.Types.message) =
  let tool_use_samples = bounded_tool_use_samples tool_use_samples in
  let tool_result_ids = bounded_tool_result_ids tool_result_ids in
  let metadata =
    List.filter
      (fun (key, _) -> not (List.mem key pair_repair_metadata_keys))
      msg.metadata
  in
  let repair_fields =
    [ "version", `Int 1; "kind", `String kind; "count", `Int count ]
    @ (match tool_use_samples with
       | [] -> []
       | samples ->
           [ ( "tool_use_samples"
             , `List (List.map tool_use_sample_to_json samples) )
           ])
    @ (match tool_result_ids with
       | [] -> []
       | ids -> [ "tool_result_ids", `List (List.map (fun id -> `String id) ids) ])
  in
  { msg with
    metadata =
      [ "was_repaired", `Bool true
      ; "repair_source", `String "tool_pair_repair"
      ; pair_repair_metadata_key, `Assoc repair_fields
      ]
      @ metadata
  }
