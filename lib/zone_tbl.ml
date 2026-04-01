(** Zone_tbl — per-keeper tool zone stack with O(1) membership check.
    Phase 2B of Tool Gate architecture (#4381). *)

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type zone_id = int

type zone_frame = {
  id : zone_id;
  op : Tool_gate.tool_op;
  snapshot : string list;
  current : string list;
  lookup : (string, unit) Hashtbl.t;
}

type t = {
  base : string list;
  base_lookup : (string, unit) Hashtbl.t;
  stack : zone_frame list;
  next_id : int;
}

(* ================================================================ *)
(* Local helpers                                                     *)
(* Reuses normalize from Tool_gate via apply; build Hashtbl locally. *)
(* ================================================================ *)

let set_of_list names =
  let tbl = Hashtbl.create (max 16 (List.length names)) in
  List.iter (fun n -> Hashtbl.replace tbl n ()) names;
  tbl

(* ================================================================ *)
(* create                                                            *)
(* ================================================================ *)

let create ~base_tools =
  (* Delegate normalization to Tool_gate.apply Keep_all to avoid
     duplicating trim/dedup logic (GLM-5.1 review P2.2). *)
  let base = Tool_gate.apply Tool_gate.Keep_all base_tools in
  {
    base;
    base_lookup = set_of_list base;
    stack = [];
    next_id = 0;
  }

(* ================================================================ *)
(* Query                                                             *)
(* ================================================================ *)

let current_tools t =
  match t.stack with
  | [] -> t.base
  | frame :: _ -> frame.current

let base_tools t = t.base

let is_tool_allowed t name =
  let lookup =
    match t.stack with
    | [] -> t.base_lookup
    | frame :: _ -> frame.lookup
  in
  Hashtbl.mem lookup name

let depth t = List.length t.stack

let is_base t = t.stack = []

(* ================================================================ *)
(* enter                                                             *)
(* ================================================================ *)

let enter ~op t =
  let prev = current_tools t in
  let cur = Tool_gate.apply op prev in
  let frame =
    { id = t.next_id;
      op;
      snapshot = prev;
      current = cur;
      lookup = set_of_list cur;
    }
  in
  (t.next_id, { t with stack = frame :: t.stack; next_id = t.next_id + 1 })

(* ================================================================ *)
(* exit                                                              *)
(* ================================================================ *)

let exit ~zone_id t =
  match t.stack with
  | [] ->
      Error "cannot exit base: zone stack is empty"
  | top :: rest ->
      if top.id <> zone_id then
        Error
          (Printf.sprintf
            "LIFO violation: expected zone_id %d (top), got %d"
            top.id zone_id)
      else
        Ok { t with stack = rest }

let exit_all t =
  { t with stack = [] }

(* ================================================================ *)
(* to_yojson                                                         *)
(* ================================================================ *)

let to_yojson t =
  let zone_frame_to_yojson f =
    `Assoc [
      ("zone_id", `Int f.id);
      ("op", Tool_gate.to_yojson f.op);
      ("tool_count", `Int (List.length f.current));
      ("snapshot_count", `Int (List.length f.snapshot));
    ]
  in
  `Assoc [
    ("depth", `Int (depth t));
    ("base_tool_count", `Int (List.length t.base));
    ("current_tools", `List (List.map (fun n -> `String n) (current_tools t)));
    ("zones", `List (List.map zone_frame_to_yojson t.stack));
  ]
