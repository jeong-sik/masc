(** IDE annotation types — shared across [ide_annotations], [ide_region_tracker],
    and [server_ide_http].

    These types model the observational IDE overlay: Keeper-authored
    annotations bound to file + line ranges, plus code regions extracted
    from Keeper tool_calls. *)

type annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark
[@@deriving show, eq]

let annotation_kind_of_string = function
  | "Comment" -> Some Comment
  | "Decision" -> Some Decision
  | "Question" -> Some Question
  | "Bookmark" -> Some Bookmark
  | _ -> None

type annotation = {
  id : string;
  file_path : string;
  line_start : int;
  line_end : int;
  keeper_id : string;
  kind : annotation_kind;
  content : string;
  goal_id : string option;
  task_id : string option;
  created_at_ms : int64;
  updated_at_ms : int64;
}
[@@deriving show, eq]

type code_region = {
  file_path : string;
  line_start : int;
  line_end : int;
  keeper_id : string;
  source : region_source;
  timestamp_ms : int64;
}

and region_source =
  | Tool_call of { tool_name : string; turn : int }
  | Manual of { note : string }
[@@deriving show, eq]

type annotation_filter = {
  file_path : string option;
  keeper_id : string option;
  goal_id : string option;
  task_id : string option;
}

let annotation_to_json (a : annotation) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String a.id);
      ("file_path", `String a.file_path);
      ("line_start", `Int a.line_start);
      ("line_end", `Int a.line_end);
      ("keeper_id", `String a.keeper_id);
      ("kind", `String (show_annotation_kind a.kind));
      ("content", `String a.content);
      ("goal_id", match a.goal_id with None -> `Null | Some g -> `String g);
      ("task_id", match a.task_id with None -> `Null | Some t -> `String t);
      ("created_at_ms", `Intlit (Int64.to_string a.created_at_ms));
      ("updated_at_ms", `Intlit (Int64.to_string a.updated_at_ms));
    ]

let annotation_of_json (json : Yojson.Safe.t) : (annotation, string) result =
  match json with
  | `Assoc fields ->
      let find_string key default =
        match List.assoc_opt key fields with
        | Some (`String s) -> s
        | _ -> default
      in
      let find_int key default =
        match List.assoc_opt key fields with
        | Some (`Int i) -> i
        | Some (`Intlit s) -> (try int_of_string s with _ -> default)
        | _ -> default
      in
      let find_int64 key default =
        match List.assoc_opt key fields with
        | Some (`Intlit s) -> (try Int64.of_string s with _ -> default)
        | Some (`Int i) -> Int64.of_int i
        | _ -> default
      in
      let find_opt_string key =
        match List.assoc_opt key fields with
        | Some (`String s) when s <> "" -> Some s
        | _ -> None
      in
      let kind_str = find_string "kind" "Comment" in
      let kind = match annotation_kind_of_string kind_str with
        | Some k -> k
        | None -> Comment
      in
      Ok
        {
          id = find_string "id" "";
          file_path = find_string "file_path" "";
          line_start = find_int "line_start" 1;
          line_end = find_int "line_end" 1;
          keeper_id = find_string "keeper_id" "";
          kind;
          content = find_string "content" "";
          goal_id = find_opt_string "goal_id";
          task_id = find_opt_string "task_id";
          created_at_ms = find_int64 "created_at_ms" 0L;
          updated_at_ms = find_int64 "updated_at_ms" 0L;
        }
  | _ -> Error "Expected JSON object for annotation"

let region_to_json (r : code_region) : Yojson.Safe.t =
  `Assoc
    [
      ("file_path", `String r.file_path);
      ("line_start", `Int r.line_start);
      ("line_end", `Int r.line_end);
      ("keeper_id", `String r.keeper_id);
      ( "source",
        match r.source with
        | Tool_call { tool_name; turn } ->
            `Assoc
              [
                ("type", `String "tool_call");
                ("tool_name", `String tool_name);
                ("turn", `Int turn);
              ]
        | Manual { note } ->
            `Assoc [ ("type", `String "manual"); ("note", `String note) ] );
      ("timestamp_ms", `Intlit (Int64.to_string r.timestamp_ms));
    ]

let region_of_json (json : Yojson.Safe.t) : (code_region, string) result =
  match json with
  | `Assoc fields ->
      let find_string key default =
        match List.assoc_opt key fields with
        | Some (`String s) -> s
        | _ -> default
      in
      let find_int key default =
        match List.assoc_opt key fields with
        | Some (`Int i) -> i
        | Some (`Intlit s) -> (try int_of_string s with _ -> default)
        | _ -> default
      in
      let find_int64 key default =
        match List.assoc_opt key fields with
        | Some (`Intlit s) -> (try Int64.of_string s with _ -> default)
        | Some (`Int i) -> Int64.of_int i
        | _ -> default
      in
      let source =
        match List.assoc_opt "source" fields with
        | Some (`Assoc src_fields) -> (
            match List.assoc_opt "type" src_fields with
            | Some (`String "tool_call") ->
                Tool_call
                  {
                    tool_name =
                      (match List.assoc_opt "tool_name" src_fields with
                      | Some (`String s) -> s
                      | _ -> "");
                    turn =
                      (match List.assoc_opt "turn" src_fields with
                      | Some (`Int i) -> i
                      | _ -> 0);
                  }
            | Some (`String "manual") ->
                Manual
                  {
                    note =
                      (match List.assoc_opt "note" src_fields with
                      | Some (`String s) -> s
                      | _ -> "");
                  }
            | _ -> Manual { note = "" })
        | _ -> Manual { note = "" }
      in
      Ok
        {
          file_path = find_string "file_path" "";
          line_start = find_int "line_start" 1;
          line_end = find_int "line_end" 1;
          keeper_id = find_string "keeper_id" "";
          source;
          timestamp_ms = find_int64 "timestamp_ms" 0L;
        }
  | _ -> Error "Expected JSON object for code_region"
