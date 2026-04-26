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
