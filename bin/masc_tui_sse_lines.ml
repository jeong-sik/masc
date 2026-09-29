(* See .mli. *)

(* [held] is the start of a line an earlier chunk did not end. Its capacity
   stays at the longest line seen, so a stream that repeats a large line does
   not grow the buffer again for each one. *)
type t = { held : Buffer.t }

let create () = { held = Buffer.create 4096 }

let feed t chunk =
  let length = String.length chunk in
  let rec lines start completed =
    match String.index_from_opt chunk start '\n' with
    | None ->
        Buffer.add_substring t.held chunk start (length - start);
        List.rev completed
    | Some newline ->
        let line =
          match Buffer.length t.held with
          | 0 -> String.sub chunk start (newline - start)
          | _ ->
              Buffer.add_substring t.held chunk start (newline - start);
              let line = Buffer.contents t.held in
              Buffer.clear t.held;
              line
        in
        lines (newline + 1) (line :: completed)
  in
  lines 0 []
