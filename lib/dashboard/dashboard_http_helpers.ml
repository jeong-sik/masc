(** Dashboard HTTP helpers — shared env-parsing and JSON utility functions.

    Extracted from server_dashboard_http.ml for sub-module reuse. *)


(* Delegations to the canonical Env_config_core readers (RFC-0371 B7):
   this module used to carry raw getenv + parse + clamp copies of them. *)
let bool_default_true_of_env name = Env_config_core.get_bool ~default:true name

let int_of_env_default name ~default ~min_v ~max_v =
  Env_config_core.get_int_clamped ~default ~min_v ~max_v name

let float_of_env_default name ~default ~min_v ~max_v =
  Env_config_core.get_float_clamped ~default ~min_v ~max_v name

let operator_snapshot_recent_completed_limit () =
  int_of_env_default "MASC_OPERATOR_SNAPSHOT_RECENT_COMPLETED_LIMIT"
    ~default:5 ~min_v:1 ~max_v:50

let safe_member = Safe_ops.safe_member

let keeper_tail_lines_or_empty ~site path ~max_bytes ~max_lines =
  match Keeper_memory_recall.read_file_tail_lines_result path ~max_bytes ~max_lines with
  | Ok lines -> lines
  | Error exn_class ->
      Keeper_memory_recall.record_memory_recall_read_error ~site path exn_class;
      []

(* RFC-0142 PR-4: lift the silent [| _ -> default] catch-all through
   [Json_field.{list,string,assoc} |> to_option] so a Wrong_shape
   payload disappears with the same default (preserving caller
   semantics) but the type system now distinguishes Field_absent
   from Wrong_shape — call sites that want operator-visible drift
   can opt into [log_wrong_shape] later without further refactor.
   [json_int_field] is intentionally NOT migrated — it accepts
   [`Intlit raw] (large-integer string form) that [Json_field.int]
   rejects as Wrong_shape, so migration would silently downgrade
   legitimate large-integer payloads to the default. *)

let json_list_field key json =
  Json_field.list json key
  |> Json_field.to_option
  |> Option.value ~default:[]

let json_int_field key json ~default =
  match safe_member key json with
  | `Int value -> value
  | `Intlit raw -> (Option.value ~default:default (int_of_string_opt raw))
  | _ -> default

let json_string_field_opt key json =
  match Json_field.string json key |> Json_field.to_option with
  | None -> None
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed

let json_assoc_field key json =
  match Json_field.assoc json key |> Json_field.to_option with
  | None -> `Assoc []
  | Some fields -> `Assoc fields

let count_where items predicate =
  List.fold_left
    (fun acc item -> if predicate item then acc + 1 else acc)
    0 items

(** Collapse multi-line text into a single trimmed line, dropping blank
    rows.  Used by judge modules to normalize LLM output before scoring,
    so this is the SSOT — retired dashboard judges previously carried
    identical forks. *)
let normalize_text raw =
  raw |> String.trim |> String.split_on_char '\n'
  |> List.filter_map String_util.trim_nonempty
  |> String.concat " " |> String.trim
