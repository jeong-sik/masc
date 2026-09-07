type span =
  { start_line : int
  ; end_line : int
  }

type fenced_code_block =
  { info : string
  ; body : string
  ; span : span
  ; terminated : bool
  }

type block =
  | Text of span
  | Fenced_code of fenced_code_block

type t = block list

type open_fence =
  { fence_char : char
  ; fence_length : int
  ; info : string
  ; start_line : int
  ; body_rev : string list
  }

let fence_run line =
  let trimmed = String.trim line in
  let length = String.length trimmed in
  if length = 0
  then None
  else
    let fence_char = trimmed.[0] in
    if not (Char.equal fence_char '`' || Char.equal fence_char '~')
    then None
    else
      let index = ref 0 in
      while !index < length && Char.equal trimmed.[!index] fence_char do
        incr index
      done;
      if !index < 3
      then None
      else
        Some
          ( fence_char
          , !index
          , String.sub trimmed !index (length - !index) |> String.trim )
;;

let closes_fence open_fence line =
  match fence_run line with
  | Some (fence_char, fence_length, info) ->
    Char.equal fence_char open_fence.fence_char
    && fence_length >= open_fence.fence_length
    && String.equal info ""
  | None -> false
;;

let parse body =
  let lines = String.split_on_char '\n' body in
  let last_line = max 1 (List.length lines) in
  let flush_text blocks text_start end_line =
    match text_start with
    | None -> blocks
    | Some start_line -> Text { start_line; end_line } :: blocks
  in
  let rec scan line_number blocks text_start open_fence = function
    | [] ->
      (match open_fence with
       | Some fence ->
         let blocks = flush_text blocks text_start (fence.start_line - 1) in
         Fenced_code
           { info = fence.info
           ; body = String.concat "\n" (List.rev fence.body_rev)
           ; span = { start_line = fence.start_line; end_line = last_line }
           ; terminated = false
           }
         :: blocks
       | None -> flush_text blocks text_start last_line)
      |> List.rev
    | line :: rest ->
      (match open_fence with
       | Some fence when closes_fence fence line ->
         let blocks = flush_text blocks text_start (fence.start_line - 1) in
         let block =
           Fenced_code
             { info = fence.info
             ; body = String.concat "\n" (List.rev fence.body_rev)
             ; span = { start_line = fence.start_line; end_line = line_number }
             ; terminated = true
             }
         in
         scan (line_number + 1) (block :: blocks) None None rest
       | Some fence ->
         scan
           (line_number + 1)
           blocks
           text_start
           (Some { fence with body_rev = line :: fence.body_rev })
           rest
       | None ->
         (match fence_run line with
          | Some (fence_char, fence_length, info) ->
            scan
              (line_number + 1)
              blocks
              text_start
              (Some
                 { fence_char
                 ; fence_length
                 ; info
                 ; start_line = line_number
                 ; body_rev = []
                 })
              rest
          | None ->
            scan
              (line_number + 1)
              blocks
              (Some (Option.value ~default:line_number text_start))
              None
              rest))
  in
  scan 1 [] None None lines
;;

let fenced_code_blocks ast =
  List.filter_map
    (function
      | Fenced_code block -> Some block
      | Text _ -> None)
    ast
;;
