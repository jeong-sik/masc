open Lane_addon_types
module S = Mcp_protocol.Mcp_types
let ( let* ) = Result.bind
type t = (string, int) Hashtbl.t
let create () = Hashtbl.create 2
let exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error "invalid machine input history fields"
let nonnegative fields name = match List.assoc name fields with
  | `Int count when count >= 0 -> Ok count | _ -> Error ("invalid history " ^ name)
let descriptor json =
  let* fields = exact ["incarnation";"entry_count"] json in
  let* incarnation = match List.assoc "incarnation" fields with
    | `String name when name <> "" -> Ok name | _ -> Error "invalid history incarnation" in
  let* count = nonnegative fields "entry_count" in
  Ok (incarnation,count)
let payload_limit max_response_bytes =
  (* The private port returns empty content and no metadata. Reserve the exact
     SDK JSON-RPC wrapper plus its newline, with the widest integer request ID.
     Only structuredContent contains the requested payload. *)
  let result : S.tool_result = {content=[];is_error=Some false;structured_content=Some `Null;_meta=None} in
  let wire = Mcp_protocol.Jsonrpc.make_response_json ~id:(Mcp_protocol.Jsonrpc.Int min_int)
    ~result:(S.tool_result_to_yojson result) |> Yojson.Safe.to_string in
  max_response_bytes - (String.length wire - String.length "null" + 1)
let retain t ~store ~instance_id ~max_response_bytes ~call (output : output) =
  let max_bytes = payload_limit max_response_bytes in
  let retain_row (row : row) = match List.assoc_opt "input_history" row.fields with
    | None -> Ok row
    | Some json ->
        let* () = if List.mem_assoc "input_ledger" row.fields then
          Error "worker cannot supply both transferred and retained input history" else Ok () in
        let* incarnation,count = descriptor json in
        let history = Yojson.Safe.to_string (`List [`String instance_id;`String incarnation]) in
        let previous = Option.value ~default:0 (Hashtbl.find_opt t history) in
        let* () = if count < previous then Error "input cursor regressed without a new incarnation" else Ok () in
        let rec pages before oldest_first =
          if before <= previous then Ok (List.rev oldest_first)
          else
            let* () = if max_bytes > 0 then Ok () else Error "machine history RPC envelope is too small" in
            let* result = call ~name:Machine_input_history.tool_name ~arguments:(`Assoc [
              "incarnation",`String incarnation;"entry_count",`Int count;
              "before",`Int before;"max_bytes",`Int max_bytes]) in
            let* fields = if result.is_error = Some true then Error (Agent_core.Mcp.text_of_tool_result result)
              else match result.structured_content with
                | Some json -> exact ["incarnation";"entry_count";"before";"next_before";"entries"] json
                | None -> Error "machine history page omitted structuredContent" in
            let* () = if List.assoc "incarnation" fields = `String incarnation
              && List.assoc "entry_count" fields = `Int count
              && List.assoc "before" fields = `Int before then Ok ()
              else Error "machine history page belongs to another captured prefix" in
            let* next = nonnegative fields "next_before" in
            let* entries = match List.assoc "entries" fields with
              | `List entries -> Ok entries | _ -> Error "history page entries must be an array" in
            let* () = if next < before && List.length entries = before-next then Ok ()
              else Error "history page cursor does not match its records" in
            let needed = List.take (min (before-previous) (List.length entries)) entries in
            pages next (List.rev_append needed oldest_first) in
        let* entries = pages count [] in
        let* retained = Eio_unix.run_in_systhread (fun () ->
          Lane_addon_store.retain_jsonl store ~history ~entry_count:count ~newest_first:entries
            ~encode:(fun entry -> Yojson.Safe.to_string entry ^ "\n")) in
        Hashtbl.replace t history count;
        let evidence = retained.Lane_addon_store.reference in
        Ok {row with fields=("input_ledger",`Assoc ["format",`String "machine-input-jsonl-sequence";
          "entry_count",`Int count;"evidence",evidence_to_json evidence]) :: List.remove_assoc "input_history" row.fields;
          evidence=evidence :: row.evidence} in
  let* rows = List.fold_left (fun acc row ->
    let* rows = acc in let* row = retain_row row in Ok (row::rows)) (Ok []) output.rows in
  Ok {output with rows=List.rev rows}
