module Decode = Masc.Tui_decode

type frame =
  { reset : bool
  ; snapshot : Decode.system_log_snapshot
  }

type reader =
  { lines : Masc_tui_sse_lines.t
  ; mutable data : string list  (** The current frame's data lines, last first. *)
  }

let create () = { lines = Masc_tui_sse_lines.create (); data = [] }

let strip_cr line =
  let n = String.length line in
  if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line

let data_prefix = "data:"

let decode_frame text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error detail -> Error ("log stream frame is not JSON: " ^ detail)
  | json ->
    let reset = match json with `Assoc fields -> List.assoc_opt "reset" fields | _ -> None in
    (match reset with
     | Some (`Bool reset) ->
       Result.map (fun snapshot -> { reset; snapshot }) (Decode.decode_system_log_snapshot json)
     | Some _ | None -> Error "log stream frame has no reset flag")

let finish reader =
  match reader.data with
  | [] -> None
  | lines ->
    reader.data <- [];
    Some (decode_frame (String.concat "\n" (List.rev lines)))

let feed_line reader raw =
  let line = strip_cr raw in
  if String.equal line "" then finish reader
  else if String.starts_with ~prefix:":" line then None
  else if String.starts_with ~prefix:data_prefix line then begin
    let value = String.sub line (String.length data_prefix) (String.length line - String.length data_prefix) in
    let value =
      if String.starts_with ~prefix:" " value then String.sub value 1 (String.length value - 1)
      else value
    in
    reader.data <- value :: reader.data;
    None
  end
  else None

let feed reader chunk =
  Masc_tui_sse_lines.feed reader.lines chunk |> List.filter_map (feed_line reader)

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: rest -> x :: take (n - 1) rest

let apply ~limit frame (previous : Decode.system_log_snapshot option) =
  match frame.reset, previous with
  | true, (Some _ | None) | false, None -> frame.snapshot
  | false, Some previous ->
    { Decode.sys_entries = take limit (frame.snapshot.sys_entries @ previous.sys_entries)
    ; sys_total = frame.snapshot.sys_total
    ; sys_latest_seq =
        (match frame.snapshot.sys_latest_seq with
         | Some _ as newest -> newest
         | None -> previous.sys_latest_seq)
    }

let cursor = function
  | None -> None
  | Some (snapshot : Decode.system_log_snapshot) -> snapshot.sys_latest_seq
