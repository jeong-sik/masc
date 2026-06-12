type violation =
  { token : string
  ; reason : string
  }

let is_tool_token_char = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '_' ->
      true
  | _ -> false

let starts_with_prefixes token =
  (String.starts_with ~prefix:"keeper_" token
   && String.length token > String.length "keeper_")
  || (String.starts_with ~prefix:"masc_" token
      && String.length token > String.length "masc_")

let dedupe_preserve_order tokens =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun token ->
      if Hashtbl.mem seen token then false
      else (
        Hashtbl.add seen token ();
        true))
    tokens

let tool_like_tokens text =
  let len = String.length text in
  let rec scan pos acc =
    if pos >= len then List.rev acc |> dedupe_preserve_order
    else if is_tool_token_char text.[pos] then
      let start = pos in
      let rec stop i =
        if i >= len || not (is_tool_token_char text.[i]) then i else stop (i + 1)
      in
      let finish = stop pos in
      let token = String.sub text start (finish - start) in
      let acc = if starts_with_prefixes token then token :: acc else acc in
      scan finish acc
    else scan (pos + 1) acc
  in
  scan 0 []

let is_forbidden token =
  List.exists (String.equal token)
    Keeper_state_reporting_contract.forbidden_tool_tokens

let violations text =
  tool_like_tokens text
  |> List.filter_map (fun token ->
    if is_forbidden token then Some { token; reason = "forbidden_retired_tool" }
    else
      match Keeper_tool_resolution.resolve token with
      | Keeper_tool_resolution.Unknown _ ->
          Some { token; reason = "unknown_tool_token" }
      | Keeper_tool_resolution.Resolved _
      | Keeper_tool_resolution.Alias_to _ ->
          None)

let violation_to_json v =
  `Assoc [ ("token", `String v.token); ("reason", `String v.reason) ]
