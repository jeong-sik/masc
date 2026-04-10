module Keeper_name = struct
  type t = string
  let is_valid s =
    let len = String.length s in
    len > 0 && len <= 64 &&
    let rec check i =
      if i = len then true
      else
        let c = s.[i] in
        match c with
        | 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' -> check (i + 1)
        | _ -> false
    in check 0

  let of_string s =
    if is_valid s then Ok s
    else Error (Printf.sprintf "Invalid keeper_name format: '%s'" s)

  let to_string s = s
  let equal = String.equal
end

module Trace_id = struct
  type t = string
  let is_valid s = String.length s > 0 && not (String.contains s '/')
  let of_string s =
    if is_valid s then Ok s
    else Error "Invalid trace_id"
  let to_string s = s
  let equal = String.equal
end

module Task_id = struct
  type t = string
  let is_valid s = String.length s > 0
  let of_string s =
    if is_valid s then Ok s
    else Error "Invalid task_id"
  let to_string s = s
  let equal = String.equal
end