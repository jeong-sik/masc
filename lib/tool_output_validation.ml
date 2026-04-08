(** Tool_output_validation — Deterministic output budget enforcement.

    Replaces heuristic [truncate_tool_output] with schema-aware validation.

    Two integration points:
    1. [Tool_dispatch.register_post_hook] — catches [masc_*] tools
    2. [validate_and_truncate] called from [keeper_tools_oas.ml] —
       catches [keeper_*] tools that bypass [Tool_dispatch]

    @since Samchon deterministic harness — #5807 *)

(* ── Budget registry ─────────────────────────────────────────── *)

let default_budget =
  let env_val =
    match Sys.getenv_opt "MASC_KEEPER_MAX_TOOL_OUTPUT_CHARS" with
    | Some s -> (try int_of_string s with _ -> 8000)
    | None -> 8000
  in
  max 1000 (min 32000 env_val)

(** Per-tool budget overrides.  No mutex: non-yielding Hashtbl ops,
    single-domain writes during init, reads during dispatch. *)
let budgets : (string, int) Hashtbl.t = Hashtbl.create 16

let set_budget ~tool_name ~max_chars =
  Hashtbl.replace budgets tool_name (max 100 (min 32000 max_chars))

let budget_for tool_name =
  match Hashtbl.find_opt budgets tool_name with
  | Some b -> b
  | None -> default_budget

(* ── Array-aware truncation ──────────────────────────────────── *)

(** Estimate metadata JSON length for a given shown/total pair.
    Avoids hardcoded byte constant — calculates from actual values. *)
let metadata_json_len ~shown ~total =
  (* {"_truncated":true,"_shown":NNN,"_total":NNN} + comma + safety margin *)
  let digits n = if n = 0 then 1 else int_of_float (log10 (float_of_int (abs n))) + 1 in
  50 + digits shown + digits total

(** Truncate a JSON array to fit within [max_chars], preserving structure.
    Returns the truncated JSON string with a metadata element appended. *)
let truncate_json_array (items : Yojson.Safe.t list) ~max_chars : string =
  let total = List.length items in
  let buf = Buffer.create (min max_chars 16384) in
  Buffer.add_char buf '[';
  let shown = ref 0 in
  let first = ref true in
  let done_ = ref false in
  List.iter (fun item ->
    if not !done_ then begin
      let s = Yojson.Safe.to_string item in
      let sep = if !first then "" else "," in
      let meta_reserve = metadata_json_len ~shown:(!shown + 1) ~total in
      let projected = Buffer.length buf + String.length sep + String.length s + meta_reserve in
      if projected > max_chars then
        done_ := true
      else begin
        Buffer.add_string buf sep;
        Buffer.add_string buf s;
        first := false;
        incr shown
      end
    end
  ) items;
  if !shown < total then begin
    let meta = Printf.sprintf
      "%s{\"_truncated\":true,\"_shown\":%d,\"_total\":%d}"
      (if !shown > 0 then "," else "") !shown total
    in
    Buffer.add_string buf meta
  end;
  Buffer.add_char buf ']';
  Buffer.contents buf

(** Truncate a JSON object by finding its largest string/array value
    and shrinking it. Preserves the envelope structure.
    Falls back to minimal metadata object if budget is too small. *)
let truncate_json_object (fields : (string * Yojson.Safe.t) list) ~max_chars : string =
  let sized_fields =
    List.map (fun (k, v) ->
      let s = Yojson.Safe.to_string v in
      (k, v, String.length s)
    ) fields
  in
  let sorted = List.sort (fun (_, _, a) (_, _, b) -> compare b a) sized_fields in
  match sorted with
  | [] -> "{}"
  | (largest_key, largest_val, _) :: _ ->
    let truncated_val = match largest_val with
      | `List items ->
        let item_budget = max_chars / 2 in
        Yojson.Safe.from_string (truncate_json_array items ~max_chars:item_budget)
      | `String s when String.length s > max_chars / 2 ->
        let keep = max_chars / 2 in
        `String (String.sub s 0 keep ^ "...")
      | v -> v
    in
    let new_fields = List.map (fun (k, v) ->
      if k = largest_key then (k, truncated_val) else (k, v)
    ) fields in
    let with_meta = new_fields @ [
      ("_output_budget_exceeded", `Bool true);
      ("_budget_chars", `Int max_chars);
    ] in
    let candidate = Yojson.Safe.to_string (`Assoc with_meta) in
    (* Budget guarantee: if still over, fall back to minimal metadata *)
    if String.length candidate <= max_chars then candidate
    else
      let minimal = `Assoc [
        ("_output_budget_exceeded", `Bool true);
        ("_budget_chars", `Int max_chars);
        ("_original_fields", `Int (List.length fields));
      ] in
      Yojson.Safe.to_string minimal

(* ── Core validation ─────────────────────────────────────────── *)

(** Validate and truncate a tool output string.
    - Within budget: return unchanged.
    - Over budget + valid JSON array: array-aware truncation.
    - Over budget + valid JSON object: object-aware truncation.
    - Over budget + non-JSON: character truncation with metadata. *)
let validate_and_truncate ~tool_name (output : string) : string =
  let budget = budget_for tool_name in
  let len = String.length output in
  if len <= budget then output
  else
    (* Try JSON-aware truncation first *)
    match
      (try Some (Yojson.Safe.from_string output)
       with Yojson.Json_error _ -> None)
    with
    | Some (`List items) ->
      truncate_json_array items ~max_chars:budget
    | Some (`Assoc fields) ->
      truncate_json_object fields ~max_chars:budget
    | _ ->
      (* Fallback: character truncation with structured metadata *)
      let kept = String.sub output 0 budget in
      let pct = Float.of_int (len - budget) *. 100.0 /. Float.of_int len in
      Printf.sprintf "%s\n{\"_output_budget_exceeded\":true,\"_shown_chars\":%d,\"_total_chars\":%d,\"_elided_pct\":%.0f}"
        kept budget len pct

(* ── Post-hook for Tool_dispatch ─────────────────────────────── *)

(** Check if output already has truncation metadata (avoid double-truncation
    when a keeper_* tool internally dispatches a masc_* tool). *)
let is_already_truncated (data : Yojson.Safe.t) : bool =
  match data with
  | `Assoc fields -> List.mem_assoc "_output_budget_exceeded" fields
  | `List items ->
    List.exists (fun item ->
      match item with
      | `Assoc fields -> List.mem_assoc "_truncated" fields
      | _ -> false
    ) items
  | _ -> false

let post_hook (result : Tool_result.t) : Tool_result.t =
  if is_already_truncated result.data then result
  else
    let budget = budget_for result.tool_name in
    (* For `String, operate on the raw string directly to avoid
       JSON encoding overhead (quotes/escaping inflate length). *)
    match result.data with
    | `String s when String.length s > budget ->
      let truncated = validate_and_truncate ~tool_name:result.tool_name s in
      { result with data = `String truncated }
    | `List _ | `Assoc _ ->
      let serialized = Yojson.Safe.to_string result.data in
      if String.length serialized <= budget then result
      else
        let truncated_str = validate_and_truncate ~tool_name:result.tool_name serialized in
        let new_data =
          try Yojson.Safe.from_string truncated_str
          with Yojson.Json_error _ -> `String truncated_str
        in
        { result with data = new_data }
    | _ -> result

(* ── Installation ────────────────────────────────────────────── *)

let installed = ref false

let install () =
  if not !installed then begin
    Tool_dispatch.register_post_hook post_hook;
    installed := true
  end
