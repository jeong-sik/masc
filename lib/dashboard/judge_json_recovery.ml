(* Recover a JSON object from LLM output that prefixes or suffixes prose.

   Locate the first balanced {...} block in the raw string and return it
   as a candidate for re-parsing. String-literal aware: a [{] inside a
   pair of [" "] does not open a nested object, and escaped quotes inside
   a string literal are honoured, so valid prose containing stray braces
   inside a string literal does not unbalance the scan.

   Returns None when no opening brace appears at all, or when the scan
   reaches EOF with unbalanced depth. *)

let extract_balanced_object (s : string) : string option =
  let len = String.length s in
  let start_idx = String.index_opt s '{' in
  match start_idx with
  | None -> None
  | Some start ->
      let depth = ref 0 in
      let in_string = ref false in
      let escape = ref false in
      let end_idx = ref None in
      let i = ref start in
      while !end_idx = None && !i < len do
        let c = s.[!i] in
        if !in_string then begin
          if !escape then escape := false
          else if c = '\\' then escape := true
          else if c = '"' then in_string := false
        end else begin
          match c with
          | '"' -> in_string := true
          | '{' -> incr depth
          | '}' ->
              decr depth;
              if !depth = 0 then end_idx := Some !i
          | _ -> ()
        end;
        incr i
      done;
      match !end_idx with
      | Some finish -> Some (String.sub s start (finish - start + 1))
      | None -> None
