(** MCP Protocol Utilities
    HTTP content negotiation for MCP Streamable HTTP transport *)

module Http_negotiation = struct
  type accept_mode =
    | Streamable
    | Legacy_accepted
    | Rejected

  let sse_content_type = "text/event-stream"
  let json_content_type = "application/json"

  let parse_accept_header accept_header =
    match accept_header with
    | None -> []
    | Some header ->
        header
        |> String.split_on_char ','
        |> List.map String.trim
        |> List.filter_map (fun part ->
               let lowered = String.lowercase_ascii part in
               let parts = String.split_on_char ';' lowered in
               match parts with
               | [] -> None
               | media_type :: params ->
                   let q_value =
                     List.find_map
                       (fun param ->
                         let param = String.trim param in
                         if String.length param >= 2 && param.[0] = 'q'
                            && param.[1] = '='
                         then
                           let q_str =
                             String.sub param 2 (String.length param - 2)
                           in
                           try Some (float_of_string q_str) with Failure _ -> None
                         else None)
                       params
                     |> Option.value ~default:1.0
                   in
                   Some (String.trim media_type, q_value))

  let is_media_type_accepted media_types target =
    let target = String.lowercase_ascii target in
    List.exists
      (fun (media_type, q) -> q > 0.0 && String.equal media_type target)
      media_types

  let accepts_sse_header accept_header =
    let media_types = parse_accept_header accept_header in
    is_media_type_accepted media_types sse_content_type

  let accepts_streamable_mcp accept_header =
    let media_types = parse_accept_header accept_header in
    is_media_type_accepted media_types json_content_type
    && is_media_type_accepted media_types sse_content_type

  let classify_mcp_accept ~allow_legacy accept_header =
    if accepts_streamable_mcp accept_header then Streamable
    else if allow_legacy then Legacy_accepted
    else Rejected
end
