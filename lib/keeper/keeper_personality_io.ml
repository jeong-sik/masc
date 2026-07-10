(** Keeper_personality_io — symmetric I/O harness for the keeper
    [instructions] persona field.

    The harness provides the parse / coerce / byte-cap /
    drift-compare / prompt-render machinery that [Keeper_meta_json_parse]
    and [Keeper_runtime_personality_diff] depend on. *)

type raw_personality = { instructions : string }

let empty = { instructions = "" }

let parse ?(defaults = empty) (json : Yojson.Safe.t) : raw_personality =
  {
    instructions =
      Safe_ops.json_string ~default:defaults.instructions "instructions" json;
  }

let to_json (p : raw_personality) : (string * Yojson.Safe.t) list =
  [ ("instructions", `String p.instructions) ]

(* coerced_personality is just raw_personality under a different name.
   The .mli keeps the constructor private so callers cannot bypass
   [coerce] to mint one — same trick samchon uses for parser stages. *)
type coerced_personality = raw_personality

let coerce (p : raw_personality) : coerced_personality =
  { instructions = String.trim p.instructions }

let to_raw (c : coerced_personality) : raw_personality = c

type field = Instructions

let field_to_string = function Instructions -> "instructions"

type cap_warning = {
  field : field;
  observed_bytes : int;
  cap_bytes : int;
  hint : string;
}

let make_hint ~field ~observed ~cap =
  Printf.sprintf
    "%s exceeds %d-byte cap by %d bytes — prompt-render path will \
     truncate; consider tightening at source."
    (field_to_string field) cap (observed - cap)

let check_byte_caps ?max_bytes (c : coerced_personality) =
  let cap =
    match max_bytes with
    | Some n -> n
    | None -> Keeper_config.prompt_render_max_bytes
  in
  let check field value acc =
    let observed = String.length value in
    if observed > cap then
      {
        field;
        observed_bytes = observed;
        cap_bytes = cap;
        hint = make_hint ~field ~observed ~cap;
      }
      :: acc
    else acc
  in
  [] |> check Instructions c.instructions

type field_diff = {
  field : field;
  current_bytes : int;
  target_bytes : int;
  diff_offset : int;
}

let first_byte_diff a b =
  let la = String.length a in
  let lb = String.length b in
  let n = min la lb in
  let rec scan i =
    if i = n then n
    else if a.[i] <> b.[i] then i
    else scan (i + 1)
  in
  scan 0

let field_diff_of_strings ~field ~current ~target =
  if String.equal current target then None
  else
    Some
      {
        field;
        current_bytes = String.length current;
        target_bytes = String.length target;
        diff_offset = first_byte_diff current target;
      }

let compare_normalized (current : coerced_personality)
    (target : coerced_personality) =
  let diffs =
    List.filter_map
      (fun (field, c, t) -> field_diff_of_strings ~field ~current:c ~target:t)
      [ (Instructions, current.instructions, target.instructions) ]
  in
  match diffs with [] -> `Equal | _ :: _ -> `Drift diffs

let to_prompt_form ~max_bytes (p : raw_personality) : raw_personality =
  (* Delegate to the SSOT helper so render layer auto-inherits any future
     normalization fixes (e.g. PR #10557 idempotency hardening on
     [normalize_prompt_text]). Behaviour today is identical to the
     prior inline [trim → String_util.utf8_prefix] sequence; the value is
     in not having two copies of the trim/cap recipe drift apart. *)
  let render s = Keeper_config.normalize_prompt_text ~max_bytes s in
  { instructions = render p.instructions }
