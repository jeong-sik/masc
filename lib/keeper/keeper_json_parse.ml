(** Simple JSON parser — hand-written recursive descent parser.

    Parses RFC 8259 JSON with the following supported values:
    null, true, false, decimal integers, floating-point numbers,
    double-quoted strings with standard escapes, arrays, and objects. *)

type json =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Array of json list
  | Object of (string * json) list

type state =
  { src : string
  ; mutable pos : int
  ; mutable line : int
  ; mutable col : int
  }

let make_state src =
  { src; pos = 0; line = 1; col = 1 }

let err state fmt =
  Format.kasprintf (fun msg ->
    Error (Printf.sprintf "line %d, col %d: %s" state.line state.col msg))
    fmt

let peek state =
  if state.pos >= String.length state.src then None
  else Some state.src.[state.pos]

let nul_char = Char.chr 0

let advance state =
  if state.pos < String.length state.src then begin
    let c = state.src.[state.pos] in
    state.pos <- state.pos + 1;
    if c = '\n' then begin state.line <- state.line + 1; state.col <- 1 end
    else state.col <- state.col + 1;
    c
  end else
    nul_char

let expect state ch =
  if peek state = Some ch then ignore (advance state)
  else err state "expected '%c'" ch

(* ----- whitespace ----- *)

let skip_ws state =
  let rec loop () =
    match peek state with
    | Some (' ' | '\t' | '\n' | '\r') -> ignore (advance state); loop ()
    | _ -> ()
  in
  loop ()

(* ----- string ----- *)

let parse_string state =
  let buf = Buffer.create 64 in
  (* skip opening quote *)
  if peek state <> Some '"' then
    err state "expected string"
  else ignore (advance state);
  let rec loop () =
    match peek state with
    | None -> err state "unterminated string"
    | Some '"' -> ignore (advance state); Ok (Buffer.contents buf)
    | Some '\\' ->
      ignore (advance state);
      (match peek state with
       | None -> err state "unterminated escape sequence"
       | Some c ->
         ignore (advance state);
         let ch =
           match c with
           | '"'  -> '"'
           | '\\' -> '\\'
           | '/'  -> '/'
           | 'n'  -> '\n'
           | 't'  -> '\t'
           | 'r'  -> '\r'
           | 'b'  -> Char.chr 8
           | 'f'  -> Char.chr 12
           | 'u'  ->
             (* crude 4-hex-digit unicode escape *)
             let hex =
               try
                 let s = String.sub state.src state.pos 4 in
                 state.pos <- state.pos + 4;
                 state.col <- state.col + 4;
                 int_of_string ("0x" ^ s)
               with _ ->
                 let _ = err state "invalid unicode escape" in
                 0xFFFD
             in
             if hex < 0x80 then Char.chr hex
             else '?'  (* non-ASCII placeholder for simplicity *)
           | _ ->
             let _ = err state "invalid escape char '%c'" c in
             '?'
         in
         Buffer.add_char buf ch;
         loop ())
    | Some c ->
      ignore (advance state);
      Buffer.add_char buf c;
      loop ()
  in
  loop ()

(* ----- number ----- *)

let parse_number state =
  let buf = Buffer.create 16 in
  (* optional minus *)
  if peek state = Some '-' then begin
    Buffer.add_char buf '-';
    ignore (advance state)
  end;
  (* integer part *)
  let rec digits () =
    match peek state with
    | Some c when c >= '0' && c <= '9' ->
      Buffer.add_char buf c; ignore (advance state); digits ()
    | _ -> ()
  in
  (match peek state with
   | Some '0' -> Buffer.add_char buf '0'; ignore (advance state)
   | Some c when c >= '1' && c <= '9' -> digits ()
   | _ -> ());
  (* fractional part *)
  let has_frac =
    if peek state = Some '.' then begin
      Buffer.add_char buf '.'; ignore (advance state);
      digits ();
      true
    end else false
  in
  (* exponent *)
  let has_exp =
    match peek state with
    | Some ('e' | 'E') ->
      Buffer.add_char buf (advance state);
      (match peek state with
       | Some ('+' | '-') -> Buffer.add_char buf (advance state)
       | _ -> ());
      digits ();
      true
    | _ -> false
  in
  if Buffer.length buf = 0 || (Buffer.length buf = 1 && buf.[0] = '-') then
    err state "invalid number literal"
  else if has_frac || has_exp then
    Ok (Float (float_of_string (Buffer.contents buf)))
  else
    Ok (Int (int_of_string (Buffer.contents buf)))

(* ----- value ----- *)

let rec parse_value state =
  skip_ws state;
  match peek state with
  | None -> err state "unexpected end of input"
  | Some '"' -> parse_string state
  | Some '{' -> parse_object state
  | Some '[' -> parse_array state
  | Some 'n' -> parse_literal state "null" Null
  | Some 't' -> parse_literal state "true" (Bool true)
  | Some 'f' -> parse_literal state "false" (Bool false)
  | Some c when c = '-' || (c >= '0' && c <= '9') -> parse_number state
  | Some c -> err state "unexpected character '%c'" c

and parse_literal state expected value =
  let len = String.length expected in
  if String.sub state.src state.pos len = expected then begin
    state.pos <- state.pos + len;
    state.col <- state.col + len;
    Ok value
  end else
    err state "expected '%s'" expected

and parse_array state =
  ignore (advance state);  (* skip '[' *)
  skip_ws state;
  match peek state with
  | Some ']' -> ignore (advance state); Ok (Array [])
  | _ ->
    (match parse_value state with
     | Error _ as e -> e
     | Ok v ->
       let items = ref [v] in
       let rec loop () =
         skip_ws state;
         match peek state with
         | Some ']' -> ignore (advance state); Ok (Array !items)
         | Some ',' ->
           ignore (advance state);
           (match parse_value state with
            | Error _ as e -> e
            | Ok v2 -> items := !items @ [v2]; loop ())
         | _ -> err state "expected ',' or ']'"
       in
       loop ())

and parse_object state =
  ignore (advance state);  (* skip '{' *)
  skip_ws state;
  match peek state with
  | Some '}' -> ignore (advance state); Ok (Object [])
  | _ ->
    (match parse_string state with
     | Error _ as e -> e
     | Ok key ->
       skip_ws state;
       ignore (expect state ':');
       (match parse_value state with
        | Error _ as e -> e
        | Ok v ->
          let fields = ref [(key, v)] in
          let rec loop () =
            skip_ws state;
            match peek state with
            | Some '}' -> ignore (advance state); Ok (Object !fields)
            | Some ',' ->
              ignore (advance state);
              (match parse_string state with
               | Error _ as e -> e
               | Ok key2 ->
                 skip_ws state;
                 ignore (expect state ':');
                 (match parse_value state with
                  | Error _ as e -> e
                  | Ok v2 -> fields := !fields @ [(key2, v2)]; loop ())
               | _ -> err state "expected string key after ','")
            | _ -> err state "expected ',' or '}'"
          in
          loop ()))

(* ----- public API ----- *)

let parse src =
  let state = make_state src in
  match parse_value state with
  | Error _ as e -> e
  | Ok v ->
    skip_ws state;
    if peek state = None then Ok v
    else err state "trailing input at position %d" state.pos

let rec to_string v =
  let open Printf in
  match v with
  | Null -> "null"
  | Bool b -> if b then "true" else "false"
  | Int n -> sprintf "%d" n
  | Float f -> sprintf "%g" f
  | String s -> sprintf "%S" s
  | Array items -> "[" ^ String.concat "," (List.map to_string items) ^ "]"
  | Object fields ->
    let f (k, v) = sprintf "%S:%s" k (to_string v) in
    "{" ^ String.concat "," (List.map f fields) ^ "}"

let rec pp fmt v =
  let indent = ref 0 in
  let sp () = Format.pp_print_string fmt (String.make (!indent * 2) ' ') in
  let rec pp_inner = function
    | Null -> Format.pp_print_string fmt "null"
    | Bool b -> Format.pp_print_string fmt (if b then "true" else "false")
    | Int n -> Format.fprintf fmt "%d" n
    | Float f -> Format.fprintf fmt "%g" f
    | String s -> Format.fprintf fmt "%S" s
    | Array items ->
      Format.fprintf fmt "[@;";
      incr indent;
      List.iteri (fun i v ->
        if i > 0 then Format.fprintf fmt ",@;";
        sp (); pp_inner v) items;
      decr indent;
      Format.fprintf fmt "@;";
      sp (); Format.fprintf fmt "]"
    | Object fields ->
      Format.fprintf fmt "{@;";
      incr indent;
      List.iteri (fun i (k, v) ->
        if i > 0 then Format.fprintf fmt ",@;";
        sp (); Format.fprintf fmt "%S: " k; pp_inner v) fields;
      decr indent;
      Format.fprintf fmt "@;";
      sp (); Format.fprintf fmt "}"
  in
  pp_inner v