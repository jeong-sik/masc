(** Keeper_personality_io — symmetric I/O harness (incremental).

    Commit 1: types + parse + to_json. Future commits add coerce,
    validate, merge_with_defaults, compare_normalized; caller migration
    is the last step in this PR. *)

type raw_personality = {
  will : string;
  needs : string;
  desires : string;
  instructions : string;
}

let empty = { will = ""; needs = ""; desires = ""; instructions = "" }

let parse ?(defaults = empty) (json : Yojson.Safe.t) : raw_personality =
  {
    will = Safe_ops.json_string ~default:defaults.will "will" json;
    needs = Safe_ops.json_string ~default:defaults.needs "needs" json;
    desires = Safe_ops.json_string ~default:defaults.desires "desires" json;
    instructions =
      Safe_ops.json_string ~default:defaults.instructions "instructions" json;
  }

let to_json (p : raw_personality) : (string * Yojson.Safe.t) list =
  [
    ("will", `String p.will);
    ("needs", `String p.needs);
    ("desires", `String p.desires);
    ("instructions", `String p.instructions);
  ]

(* coerced_personality is just raw_personality under a different name.
   The .mli keeps the constructor private so callers cannot bypass
   [coerce] to mint one — same trick samchon uses for parser stages. *)
type coerced_personality = raw_personality

let coerce (p : raw_personality) : coerced_personality =
  {
    will = String.trim p.will;
    needs = String.trim p.needs;
    desires = String.trim p.desires;
    instructions = String.trim p.instructions;
  }

let to_raw (c : coerced_personality) : raw_personality = c

type field = Will | Needs | Desires | Instructions

let field_to_string = function
  | Will -> "will"
  | Needs -> "needs"
  | Desires -> "desires"
  | Instructions -> "instructions"

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
  []
  |> check Instructions c.instructions
  |> check Desires c.desires
  |> check Needs c.needs
  |> check Will c.will
