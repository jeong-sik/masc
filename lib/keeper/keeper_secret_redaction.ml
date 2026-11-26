type t =
  { patterns : Re.re list
  ; any_exact_value : Re.re option
  ; exact_values : string list
  ; max_exact_value_len : int
  ; has_multiline_exact_value : bool
  }

type stream_release_mode =
  | Line_buffered
  | Token_incremental

(* A structural token whose start a bounded flush already released as
   [[REDACTED]] while its body was still arriving. Every following byte that
   continues the body belongs to that mask. For a URL credential the bytes
   after an [@] wait in [pending_line]: a later [@] makes them userinfo, the
   end of the authority makes them the host. *)
type owned_token =
  { owner : Secret_patterns.stream_owner
  ; mutable seen_at : bool
  }

type stream_state =
  { redaction : t
  ; mode : stream_release_mode
  ; pending_line : Buffer.t
  ; mutable next_bounded_flush_at : int
  ; mutable consumed : int
  ; mutable prev_ended_word : bool
  ; mutable in_unterminated_pem : bool
  ; mutable owned : owned_token option
  }

type stream_release =
  { pieces : Secret_patterns.source_piece list
  ; consumed : int
  }

let empty =
  { patterns = []
  ; any_exact_value = None
  ; exact_values = []
  ; max_exact_value_len = 0
  ; has_multiline_exact_value = false
  }

let min_secret_len = 8
let max_secret_file_bytes = 64 * 1024
let stream_emit_bytes = 4 * 1024
let structural_pattern_overlap_bytes = 4 * 1024

let ssh_dirname = "ssh"

let ssh_remote_token_file ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat (Common.masc_dir_from_base_path ~base_path) ssh_dirname)
       "redaction")
    (Workspace_utils.safe_filename keeper_name ^ ".token")
;;

let path_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let lstat_opt path =
  try Some (Unix.lstat path) with
  | Unix.Unix_error _ -> None

let read_regular_file path st =
  if st.Unix.st_size < 0 || st.Unix.st_size > max_secret_file_bytes then None
  else
    try
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> Some (really_input_string ic st.Unix.st_size))
    with
    | Sys_error _ | End_of_file -> None

let add_value value acc =
  let trimmed = String.trim value in
  if String.length trimmed >= min_secret_len then trimmed :: acc else acc

let add_lines value acc =
  value
  |> String.split_on_char '\n'
  |> List.fold_left (fun acc line -> add_value line acc) acc

(* A snapshot is a function of the bytes of its source files. Building one
   reads every file and compiles one regex per value, and a fresh [Re.re]
   starts with an empty DFA that [Re.replace_string] fills again on first
   use. Chat loads, connector deliveries and stream projections asked for a
   snapshot per call, and on 2026-09-05 regex compilation was 35% of the
   main domain's busy time (RFC main-domain-scheduler-latency §8.8). The
   walk is therefore split in two: enumerating the regular files with the
   stat that identifies their bytes, then reading them. A call always
   enumerates; it reads and compiles only when a stamp differs from the one
   memoised for the same request key on the same domain. *)
(* [Whole_and_lines] is a file that is a secret: its text, and each of its
   lines, is a value. [Whole_and_mapping_scalars] is a mapping that holds
   secrets among other fields (the GitHub CLI's [hosts.yml]): its text and the
   scalars [add_mapping_scalar_values] picks are values, and its other lines
   are not: a host line ([github.com:]) as a value would mask that text in
   every SSH remote ([git@github.com:owner/repo]). *)
type extraction =
  | Whole_and_lines
  | Whole_and_mapping_scalars

type source =
  { source_path : string
  ; extraction : extraction
  ; st : Unix.stats
  }

let regular_file_source extraction path acc =
  match lstat_opt path with
  | Some st when st.Unix.st_kind = Unix.S_REG -> { source_path = path; extraction; st } :: acc
  | _ -> acc

let strip_matching_quotes value =
  let len = String.length value in
  if len >= 2
     && ((Char.equal value.[0] '"' && Char.equal value.[len - 1] '"')
         || (Char.equal value.[0] '\'' && Char.equal value.[len - 1] '\''))
  then String.sub value 1 (len - 2)
  else value

(* Scalar mining is what catches a bare credential printed without its key
   line — `gh auth status` shows the token alone. The key half decides what
   a scalar is: credential-shaped keys always mine, identity keys (a `user:`
   login) only when [redact_identity_scalars] is set. The default mined
   every scalar, so a GitHub account name — public in every repo URL — was
   masked as [REDACTED] throughout chat text (2026-08-29, keeper edgar.a.poe). *)
(* What makes a key credential-shaped, and the promise this module publishes:
   these values are masked whatever [redact_identity_scalars] says. The list
   is markers rather than key spellings on purpose -- enumerating names
   ("api_key", "apikey", "access_key", ...) is a list that is always one
   spelling short of the file it is about to read.

   [key] over-matches: a `public_key:` line in a secret file is masked too.
   That is the side to be wrong on. The complaint that produced the identity
   switch was a GitHub *account name* showing as [REDACTED] in chat prose,
   not a public key inside a credential file. *)
let credential_shaped_key key =
  List.exists
    (fun marker -> String_util.contains_substring_ci key marker)
    [ "token"
    ; "secret"
    ; "password"
    ; "passwd"
    ; "credential"
    ; "passphrase"
    ; "key"
    ; "auth"
    ; "bearer"
    ; "cookie"
    ; "session"
    ; "signature"
    ]

let add_mapping_scalar_values ~(redact_identity_scalars : bool) value acc =
  value
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun acc line ->
          match String.index_opt line ':' with
          | None -> acc
          | Some separator ->
            let key = String.trim (String.sub line 0 separator) in
            let value_start = separator + 1 in
            let scalar =
              String.sub line value_start (String.length line - value_start)
              |> String.trim
              |> strip_matching_quotes
            in
            if redact_identity_scalars || credential_shaped_key key
            then add_value scalar acc
            else acc)
       acc

let env_sources env_root acc =
  if not (path_exists env_root) then acc
  else
    match lstat_opt env_root with
    | Some st when st.Unix.st_kind = Unix.S_DIR ->
        (try
           Sys.readdir env_root
           |> Array.to_list
           |> List.fold_left
                (fun acc name ->
                   regular_file_source Whole_and_lines (Filename.concat env_root name) acc)
                acc
         with
         | Sys_error _ -> acc)
    | _ -> acc

let files_tree_sources files_root acc =
  let rec walk path acc =
    match lstat_opt path with
    | Some st when st.Unix.st_kind = Unix.S_DIR ->
        (try
           Sys.readdir path
           |> Array.to_list
           |> List.fold_left
                (fun acc name -> walk (Filename.concat path name) acc)
                acc
         with
         | Sys_error _ -> acc)
    | Some st when st.Unix.st_kind = Unix.S_REG ->
        { source_path = path; extraction = Whole_and_lines; st } :: acc
    | _ -> acc
  in
  if path_exists files_root then walk files_root acc else acc

let sources ~additional_secret_files ~base_path ~keeper_name =
  Keeper_secret_projection.secret_roots ~base_path ~keeper_name
  |> List.fold_left
       (fun acc info ->
          let env_root = Filename.concat info.Keeper_secret_projection.root "env" in
          let files_root = Filename.concat info.Keeper_secret_projection.root "files" in
          acc |> env_sources env_root |> files_tree_sources files_root)
       []
  |> regular_file_source Whole_and_lines (ssh_remote_token_file ~base_path ~keeper_name)
  |> fun acc ->
  List.fold_left
    (fun acc path -> regular_file_source Whole_and_mapping_scalars path acc)
    acc
    additional_secret_files

let values_of_source ~(redact_identity_scalars : bool) { source_path; extraction; st } acc =
  match read_regular_file source_path st with
  | None -> acc
  | Some value ->
      let acc = add_value (Keeper_secret_projection.strip_one_final_newline value) acc in
      (match extraction with
       | Whole_and_lines -> add_lines value acc
       | Whole_and_mapping_scalars ->
           add_mapping_scalar_values ~redact_identity_scalars value acc)

(* Tool-call arguments are JSON text wherever an operator reads them: a
   provider streams them as JSON and the approval gate prints the parsed
   value. Inside a JSON string a double quote, a backslash, a line break and
   the other control characters are written as backslash escapes, and the
   passes below compare bytes, so a value holding one of those was masked in
   plain text and readable in a tool call (#53444). The short lines of a
   multi-line value had the same gap: a line shorter than [min_secret_len] is
   covered by the whole value alone, and the whole value did not match where
   its line breaks were escaped.

   The spelling is taken from [Yojson.Safe.to_string], the printer the gate
   uses, so the two cannot drift.

   A spelling is an exact value like the one it spells, and it is held to the
   size that one is. A JSON string writes a control character in six bytes, so
   a value made of them is six times as long there. The longest exact value
   is what an unterminated stream line keeps back, and every exact value is
   compiled again by each copy of the snapshot, so a spelling past
   [max_secret_file_bytes] would let one file raise both past the bound the
   file was read under.

   Not covered: a spelling longer than [max_secret_file_bytes], a value quoted
   a second time inside that string (a JSON body in a shell command), and an
   escape this printer does not write (a quote or a non-ASCII character as
   its code point, a slash behind a backslash). *)
let json_string_spelling value =
  let printed = Yojson.Safe.to_string (`String value) in
  let spelling = String.sub printed 1 (String.length printed - 2) in
  if String.equal spelling value || String.length spelling > max_secret_file_bytes
  then None
  else Some spelling

let with_json_string_spellings values =
  List.concat_map
    (fun value ->
       match json_string_spelling value with
       | None -> [ value ]
       | Some spelling -> [ value; spelling ])
    values

let dedupe values =
  List.sort_uniq
    (fun a b ->
       let len_cmp = Int.compare (String.length b) (String.length a) in
       if len_cmp <> 0 then len_cmp else String.compare b a)
    values

let compile_exact_values values =
  let patterns = List.map (fun value -> Re.compile (Re.str value)) values in
  let any_exact_value =
    match values with
    | [] -> None
    | values -> Some (Re.compile (Re.alt (List.map Re.str values)))
  in
  let max_exact_value_len =
    List.fold_left (fun longest value -> max longest (String.length value)) 0 values
  in
  let has_multiline_exact_value =
    List.exists
      (fun value -> String.contains value '\n' || String.contains value '\r')
      values
  in
  { patterns
  ; any_exact_value
  ; exact_values = values
  ; max_exact_value_len
  ; has_multiline_exact_value
  }

let build ~redact_identity_scalars sources =
  let values =
    List.fold_left
      (fun acc source -> values_of_source ~redact_identity_scalars source acc)
      []
      sources
    |> with_json_string_spellings
    |> dedupe
  in
  compile_exact_values values

let copy_for_current_domain snapshot =
  compile_exact_values snapshot.exact_values

let same_policy left right =
  left == right || List.equal String.equal left.exact_values right.exact_values

(* The memo is per domain: a compiled [Re.re] fills its DFA tables lazily
   while matching, so one must not be shared between domains. Fibers of one
   domain interleave only at suspension points and matching has none. *)
type memo_key =
  { key_base_path : string
  ; key_keeper_name : string
  ; key_redact_identity_scalars : bool
  ; key_additional_secret_files : string list
  }

type source_stamp =
  { stamp_path : string
  ; device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

type memo_entry =
  { key : memo_key
  ; stamps : source_stamp list
  ; snapshot : t
  }

let key_equal a b =
  String.equal a.key_base_path b.key_base_path
  && String.equal a.key_keeper_name b.key_keeper_name
  && Bool.equal a.key_redact_identity_scalars b.key_redact_identity_scalars
  && List.equal String.equal a.key_additional_secret_files b.key_additional_secret_files

let stamp_equal a b =
  String.equal a.stamp_path b.stamp_path
  && Int.equal a.device b.device
  && Int.equal a.inode b.inode
  && Int.equal a.size b.size
  && Float.equal a.mtime b.mtime

let memo : memo_entry list ref Domain.DLS.key = Domain.DLS.new_key (fun () -> ref [])

let stamp_of_source { source_path; st; extraction = _ } =
  { stamp_path = source_path
  ; device = st.Unix.st_dev
  ; inode = st.Unix.st_ino
  ; size = st.Unix.st_size
  ; mtime = st.Unix.st_mtime
  }

let snapshot_with_additional_secret_files
      ~(redact_identity_scalars : bool)
      ~additional_secret_files
      ~base_path
      ~keeper_name
  =
  let sources = sources ~additional_secret_files ~base_path ~keeper_name in
  let key =
    { key_base_path = base_path
    ; key_keeper_name = keeper_name
    ; key_redact_identity_scalars = redact_identity_scalars
    ; key_additional_secret_files = additional_secret_files
    }
  in
  let stamps = List.map stamp_of_source sources in
  let entries = Domain.DLS.get memo in
  match List.find_opt (fun entry -> key_equal entry.key key) !entries with
  | Some entry when List.equal stamp_equal entry.stamps stamps -> entry.snapshot
  | Some _ | None ->
      let snapshot = build ~redact_identity_scalars sources in
      entries
        := { key; stamps; snapshot }
           :: List.filter (fun entry -> not (key_equal entry.key key)) !entries;
      snapshot

let snapshot ~base_path ~keeper_name =
  snapshot_with_additional_secret_files
    ~redact_identity_scalars:true
    ~additional_secret_files:[]
    ~base_path
    ~keeper_name
;;

(* A text contains one of the exact values when [any_exact_value] matches it,
   and a replacement pass that finds nothing returns its input, so a text
   [any_exact_value] does not match leaves the passes with nothing to do. The
   passes keep their longest-value-first order when something matches: a value
   that contains another must be replaced before the shorter one splits it. *)
let redact_exact_pieces t text =
  let pieces =
    if String.equal text "" then []
    else
      [ Secret_patterns.Copied
          { source = { first_byte = 0; past_byte = String.length text }; text }
      ]
  in
  match t.any_exact_value with
  | Some any_exact_value when Re.execp any_exact_value text ->
      List.fold_left
        (fun pieces pattern -> Secret_patterns.mask_matches pattern pieces)
        pieces
        t.patterns
  | Some _ | None -> pieces

let redact_text_mapped t text =
  Secret_patterns.redact_pieces (redact_exact_pieces t text)

let redact_text_mapped_with_lookbehind ~prev_ended_word t text =
  Secret_patterns.redact_pieces_with_lookbehind ~prev_ended_word
    (redact_exact_pieces t text)

let redact_text t text = Secret_patterns.render_pieces (redact_text_mapped t text)

let stream_overlap_bytes redaction =
  max structural_pattern_overlap_bytes (max 0 (redaction.max_exact_value_len - 1))
;;

let stream_flush_threshold redaction =
  stream_overlap_bytes redaction + stream_emit_bytes
;;

let create_stream_state ?(mode = Line_buffered) redaction =
  { redaction
  ; mode
  ; pending_line = Buffer.create 256
  ; next_bounded_flush_at = stream_flush_threshold redaction
  ; consumed = 0
  ; prev_ended_word = false
  ; in_unterminated_pem = false
  ; owned = None
  }
;;

let exact_value_starts_at text ~index value =
  let value_len = String.length value in
  let rec equal offset =
    offset = value_len
    || (Char.equal text.[index + offset] value.[offset] && equal (offset + 1))
  in
  index + value_len <= String.length text
  && Char.equal text.[index] value.[0]
  && equal 1
;;

let exact_value_at redaction text index =
  List.find_opt (exact_value_starts_at text ~index) redaction.exact_values
;;

let shift_piece offset = function
  | Secret_patterns.Copied { source; text } ->
      Secret_patterns.Copied
        { source = { first_byte = source.first_byte + offset; past_byte = source.past_byte + offset }; text }
  | Secret_patterns.Masked { source; replacement } ->
      Secret_patterns.Masked
        { source = { first_byte = source.first_byte + offset; past_byte = source.past_byte + offset }; replacement }

let rec last_nonempty_piece_char = function
  | [] -> None
  | piece :: rest ->
      match last_nonempty_piece_char rest with
      | Some _ as found -> found
      | None ->
          let text =
            match piece with
            | Secret_patterns.Copied { text; _ } -> text
            | Secret_patterns.Masked { replacement; _ } -> replacement
          in
          let len = String.length text in
          if len = 0 then None else Some text.[len - 1]

let update_prev_ended_word state pieces =
  match last_nonempty_piece_char pieces with
  | None -> ()
  | Some ch -> state.prev_ended_word <- Secret_patterns.is_word_char ch

let emit_mapped (state : stream_state) emitted ~source_length pieces =
  let pieces = List.map (shift_piece state.consumed) pieces in
  emitted := List.rev_append pieces !emitted;
  state.consumed <- state.consumed + source_length

(* Largest [k <= max_len] such that [s[0..k-1]] does not end with an incomplete
   UTF-8 codepoint (including at [max_len = String.length s], where
   [String_util.utf8_char_boundary] returns [len] verbatim). Invalid lead bytes
   or stray continuation runs that cannot be completed by future bytes are left
   at [max_len] so streaming never stalls on binary input. *)
let complete_utf8_prefix_len s max_len =
  let max_len = min max_len (String.length s) in
  if max_len <= 0 then 0
  else
    let last_b = Char.code s.[max_len - 1] in
    if last_b < 0x80 then max_len
    else
      let rec find_lead k cont_count =
        if k < 0 then -1
        else
          let b = Char.code s.[k] in
          if (b land 0xC0) = 0x80 then
            if cont_count >= 3 then -1 else find_lead (k - 1) (cont_count + 1)
          else k
      in
      let lead = find_lead (max_len - 1) 0 in
      if lead < 0 then max_len
      else
        let b = Char.code s.[lead] in
        let expected_width =
          if b < 0x80 then 1
          else if b >= 0xC2 && b <= 0xDF then 2
          else if b >= 0xE0 && b <= 0xEF then 3
          else if b >= 0xF0 && b <= 0xF4 then 4
          else 0
        in
        if expected_width <= 1 then max_len
        else if lead + expected_width <= max_len then max_len
        else lead

let is_prefix_of_value text ~start ~len value =
  let suffix_len = len - start in
  suffix_len <= String.length value
  &&
  let rec loop offset =
    offset = suffix_len
    || (Char.equal text.[start + offset] value.[offset] && loop (offset + 1))
  in
  loop 0

let exact_suffix_hold_from redaction text =
  let len = String.length text in
  if len = 0 || redaction.max_exact_value_len = 0 then len
  else
    let first = max 0 (len - redaction.max_exact_value_len) in
    let rec scan i =
      if i >= len then len
      else if List.exists (is_prefix_of_value text ~start:i ~len) redaction.exact_values
      then i
      else scan (i + 1)
    in
    scan first

let source_offset_of_rendered pieces rendered_offset =
  let rec walk rendered_pos = function
    | [] -> 0
    | piece :: rest ->
        let source, piece_len, is_masked =
          match piece with
          | Secret_patterns.Copied { source; text } -> source, String.length text, false
          | Secret_patterns.Masked { source; replacement } ->
              source, String.length replacement, true
        in
        if rendered_offset <= rendered_pos then source.first_byte
        else if rendered_offset < rendered_pos + piece_len then
          if is_masked then source.first_byte
          else source.first_byte + (rendered_offset - rendered_pos)
        else if rest = [] then source.past_byte
        else walk (rendered_pos + piece_len) rest
  in
  walk 0 pieces

let rendered_offset_of_source pieces source_offset =
  let rec walk rendered_pos = function
    | [] -> rendered_pos
    | piece :: rest ->
        let source, piece_len =
          match piece with
          | Secret_patterns.Copied { source; text } -> source, String.length text
          | Secret_patterns.Masked { source; replacement } ->
              source, String.length replacement
        in
        if source_offset <= source.first_byte then rendered_pos
        else if source_offset < source.past_byte then
          rendered_pos + (source_offset - source.first_byte)
        else walk (rendered_pos + piece_len) rest
  in
  walk 0 pieces

let pull_back_straddling_exact_masks exact_pieces cut =
  List.fold_left
    (fun cut piece ->
       match piece with
       | Secret_patterns.Copied _ -> cut
       | Secret_patterns.Masked { source; _ } ->
           if source.first_byte < cut && cut < source.past_byte
           then min cut source.first_byte
           else cut)
    cut
    exact_pieces

let safe_incremental_cut state pending =
  let len = String.length pending in
  if len = 0 then 0
  else
    let h_exact = exact_suffix_hold_from state.redaction pending in
    let exact_pieces = redact_exact_pieces state.redaction pending in
    let exact_rendered =
      match exact_pieces with
      | [ Secret_patterns.Copied { text; _ } ] when text == pending -> pending
      | [] | (Secret_patterns.Copied _ | Secret_patterns.Masked _) :: _ ->
          Secret_patterns.render_pieces exact_pieces
    in
    let h_struct_raw =
      Secret_patterns.safe_stream_prefix_len
        ~prev_ended_word:state.prev_ended_word
        pending
    in
    let h_struct =
      if exact_rendered == pending then h_struct_raw
      else
        let h_struct_exact =
          Secret_patterns.safe_stream_prefix_len
            ~prev_ended_word:state.prev_ended_word
            exact_rendered
          |> source_offset_of_rendered exact_pieces
        in
        min h_struct_raw h_struct_exact
    in
    let initial_cut = min h_exact h_struct in
    let rec tighten cut =
      if cut <= 0 then 0
      else
        let cut1 = complete_utf8_prefix_len pending cut in
        let cut2 = pull_back_straddling_exact_masks exact_pieces cut1 in
        let cut3 =
          if cut2 <= 0 || cut2 = len then cut2
          else
            let rendered_cut = rendered_offset_of_source exact_pieces cut2 in
            let safe_rendered_cut =
              Secret_patterns.cut_before_straddling_match
                ~prev_ended_word:state.prev_ended_word
                exact_rendered
                rendered_cut
            in
            let cut_from_exact =
              if safe_rendered_cut = rendered_cut then cut2
              else min cut2 (source_offset_of_rendered exact_pieces safe_rendered_cut)
            in
            if exact_rendered == pending then cut_from_exact
            else
              let safe_raw_cut =
                Secret_patterns.cut_before_straddling_match
                  ~prev_ended_word:state.prev_ended_word
                  pending
                  cut_from_exact
              in
              min cut_from_exact safe_raw_cut
        in
        if cut3 < cut then tighten cut3 else cut3
    in
    tighten initial_cut

let emit_bounded_prefix state emitted stop =
  let pending = Buffer.contents state.pending_line in
  (* Each emitted piece reaches its reader as a separate string (a dashboard
     row, a JSON field in an SSE event), so the piece must end between
     characters: a cut inside a Hangul syllable showed as U+FFFD at the end of
     one piece and the start of the next. Moving the cut back keeps at most
     three more bytes pending. A prefix with no character boundary in it is
     not UTF-8, and the byte cut stands so the pending line stays bounded. *)
  let stop =
    match String_util.utf8_char_boundary pending stop with
    | 0 -> stop
    | boundary -> boundary
  in
  let pieces = ref [] in
  let cursor = ref 0 in
  let copied_from = ref 0 in
  let copy_until past_byte =
    if past_byte > !copied_from then
      pieces := Secret_patterns.Copied
        { source = { first_byte = !copied_from; past_byte };
          text = String.sub pending !copied_from (past_byte - !copied_from) } :: !pieces
  in
  while !cursor < stop do
    match exact_value_at state.redaction pending !cursor with
    | Some value ->
      copy_until !cursor;
      let past_byte = !cursor + String.length value in
      pieces := Secret_patterns.Masked
        { source = { first_byte = !cursor; past_byte }; replacement = "[REDACTED]" } :: !pieces;
      cursor := past_byte;
      copied_from := past_byte
    | None -> incr cursor
  done;
  copy_until !cursor;
  let redacted =
    match state.mode with
    | Line_buffered -> Secret_patterns.redact_pieces (List.rev !pieces)
    | Token_incremental ->
        if !cursor >= 27
           && Secret_patterns.has_unclosed_pem_block (String.sub pending 0 !cursor)
        then state.in_unterminated_pem <- true;
        let redacted =
          Secret_patterns.redact_pieces_with_lookbehind
            ~prev_ended_word:state.prev_ended_word
            (List.rev !pieces)
        in
        update_prev_ended_word state redacted;
        redacted
  in
  emit_mapped state emitted ~source_length:!cursor redacted;
  Buffer.clear state.pending_line;
  Buffer.add_substring
    state.pending_line
    pending
    !cursor
    (String.length pending - !cursor)
;;

let flush_complete_record state emitted =
  let pending = Buffer.contents state.pending_line in
  let len = String.length pending in
  if len > 0 then (
    let redacted =
      if state.in_unterminated_pem then
        [ Secret_patterns.Masked
            { source = { first_byte = 0; past_byte = len }
            ; replacement = "[REDACTED]"
            }
        ]
      else
        match state.mode with
        | Line_buffered -> redact_text_mapped state.redaction pending
        | Token_incremental ->
            redact_text_mapped_with_lookbehind
              ~prev_ended_word:state.prev_ended_word
              state.redaction
              pending
    in
    emit_mapped state emitted ~source_length:len redacted;
    match state.mode with
    | Line_buffered -> ()
    | Token_incremental -> update_prev_ended_word state redacted);
  Buffer.clear state.pending_line;
  state.next_bounded_flush_at <- stream_flush_threshold state.redaction
;;

let flush_bounded_prefix_if_needed state emitted =
  let pending_len = Buffer.length state.pending_line in
  if pending_len >= state.next_bounded_flush_at
  then (
    let overlap = stream_overlap_bytes state.redaction in
    let stop = pending_len - overlap in
    emit_bounded_prefix state emitted stop;
    state.next_bounded_flush_at <- stream_flush_threshold state.redaction)
;;

let flush_unterminated_pem_bounded state emitted pending pending_len =
  let overlap = stream_overlap_bytes state.redaction in
  let stop = pending_len - overlap in
  if stop > 0 then (
    let pieces =
      [ Secret_patterns.Masked
          { source = { first_byte = 0; past_byte = stop }
          ; replacement = "[REDACTED]"
          }
      ]
    in
    emit_mapped state emitted ~source_length:stop pieces;
    state.prev_ended_word <- false;
    Buffer.clear state.pending_line;
    Buffer.add_substring state.pending_line pending stop (pending_len - stop);
    state.next_bounded_flush_at <- stream_flush_threshold state.redaction)

let handle_unterminated_pem_byte state emitted char =
  Buffer.add_char state.pending_line char;
  let pending_len = Buffer.length state.pending_line in
  if Char.equal char '-' && pending_len >= 25 then (
    let pending = Buffer.contents state.pending_line in
    match Secret_patterns.find_pem_footer_end pending with
    | Some end_pos ->
        let pieces =
          [ Secret_patterns.Masked
              { source = { first_byte = 0; past_byte = end_pos }
              ; replacement = "[REDACTED]"
              }
          ]
        in
        emit_mapped state emitted ~source_length:end_pos pieces;
        state.prev_ended_word <- false;
        state.in_unterminated_pem <- false;
        Buffer.clear state.pending_line;
        Buffer.add_substring state.pending_line pending end_pos (pending_len - end_pos);
        state.next_bounded_flush_at <- stream_flush_threshold state.redaction
    | None ->
        if pending_len >= state.next_bounded_flush_at
        then flush_unterminated_pem_bounded state emitted pending pending_len)
  else if pending_len >= state.next_bounded_flush_at then
    let pending = Buffer.contents state.pending_line in
    flush_unterminated_pem_bounded state emitted pending pending_len

let should_hold_across_newline state =
  let pending_len = Buffer.length state.pending_line in
  let pem_holds =
    pending_len >= 27
    && Secret_patterns.has_unclosed_pem_block (Buffer.contents state.pending_line)
  in
  if pem_holds then true
  else if state.redaction.has_multiline_exact_value then
    let pending = Buffer.contents state.pending_line in
    exact_suffix_hold_from state.redaction pending < pending_len
  else false

let flush_safe_incremental_prefix state emitted =
  let pending_len = Buffer.length state.pending_line in
  if pending_len > 0 && (not state.in_unterminated_pem) && Option.is_none state.owned then (
    let pending = Buffer.contents state.pending_line in
    let cut = safe_incremental_cut state pending in
    if cut > 0 then (
      let prefix =
        if cut = pending_len then pending else String.sub pending 0 cut
      in
      let redacted =
        redact_text_mapped_with_lookbehind
          ~prev_ended_word:state.prev_ended_word
          state.redaction
          prefix
      in
      emit_mapped state emitted ~source_length:cut redacted;
      update_prev_ended_word state redacted;
      Buffer.clear state.pending_line;
      if cut < pending_len then
        Buffer.add_substring state.pending_line pending cut (pending_len - cut);
      state.next_bounded_flush_at <- stream_flush_threshold state.redaction))

(* Mask the next [source_length] source bytes as part of the token whose
   [[REDACTED]] was already released. They extend that mask when it is the
   last piece of this release, and otherwise add no text. *)
let absorb_into_owned_mask (state : stream_state) emitted ~source_length =
  if source_length > 0 then (
    let first_byte = state.consumed in
    let past_byte = first_byte + source_length in
    (match !emitted with
     | Secret_patterns.Masked { source; replacement } :: rest
       when source.past_byte = first_byte ->
         emitted :=
           Secret_patterns.Masked { source = { source with past_byte }; replacement }
           :: rest
     | [] | (Secret_patterns.Copied _ | Secret_patterns.Masked _) :: _ ->
         emitted :=
           Secret_patterns.Masked { source = { first_byte; past_byte }; replacement = "" }
           :: !emitted);
    state.consumed <- past_byte)

(* Token_incremental bounded flush (#55006 follow-up). The plain flush released
   [0, stop) and kept the rest pending, so a structural token running across
   [stop] was masked only up to [stop] and its body after [stop] left as
   copied text. Here the release ends before any structural match that
   crosses [stop] and before any pattern still in progress. When such a token
   starts at byte 0 and fills the whole release window, holding it back would
   leave the pending line unbounded, so the window is released masked and the
   stream owns the token until its body ends. *)
let rec token_incremental_char state emitted char =
  match state.owned with
  | Some owned -> owned_token_char state emitted owned char
  | None -> token_incremental_plain_char state emitted char

and token_incremental_plain_char state emitted char =
  if state.in_unterminated_pem then handle_unterminated_pem_byte state emitted char
  else (
    Buffer.add_char state.pending_line char;
    if (Char.equal char '\n' || Char.equal char '\r')
       && not (should_hold_across_newline state)
    then flush_complete_record state emitted
    else if Buffer.length state.pending_line >= state.next_bounded_flush_at
    then (
      emit_token_incremental_bounded state emitted;
      state.next_bounded_flush_at <- stream_flush_threshold state.redaction))

and owned_token_char state emitted owned char =
  let continues = Secret_patterns.stream_owner_continues owned.owner char in
  match owned.owner with
  | Secret_patterns.Url_userinfo ->
      if Char.equal char '@' then (
        absorb_into_owned_mask state emitted
          ~source_length:(Buffer.length state.pending_line + 1);
        Buffer.clear state.pending_line;
        owned.seen_at <- true)
      else if continues then
        if owned.seen_at then (
          Buffer.add_char state.pending_line char;
          let held = Buffer.length state.pending_line in
          if held >= stream_flush_threshold state.redaction then (
            (* Bounded: an authority this long after an [@] stays masked. *)
            absorb_into_owned_mask state emitted ~source_length:held;
            Buffer.clear state.pending_line))
        else absorb_into_owned_mask state emitted ~source_length:1
      else (
        (* The authority ended: bytes after its last [@] are the host. *)
        state.owned <- None;
        token_incremental_plain_char state emitted char)
  | Secret_patterns.Sk_token_body
  | Secret_patterns.Stripe_token_body
  | Secret_patterns.Dotted_token_body
  | Secret_patterns.Header_value ->
      if continues then absorb_into_owned_mask state emitted ~source_length:1
      else (
        state.owned <- None;
        token_incremental_plain_char state emitted char)

and emit_token_incremental_bounded state emitted =
  let pending = Buffer.contents state.pending_line in
  let pending_len = String.length pending in
  let stop = pending_len - stream_overlap_bytes state.redaction in
  let stop =
    match String_util.utf8_char_boundary pending stop with
    | 0 -> stop
    | boundary -> boundary
  in
  let prev_ended_word = state.prev_ended_word in
  let before_complete =
    Secret_patterns.cut_before_straddling_match ~prev_ended_word pending stop
  in
  let safe_stop =
    match Secret_patterns.first_stream_hold ~prev_ended_word pending with
    | Some { start; _ } when start < before_complete -> start
    | Some _ | None -> before_complete
  in
  if safe_stop > 0 then emit_bounded_prefix state emitted safe_stop
  else own_token_at_window_start state emitted pending stop

and own_token_at_window_start state emitted pending stop =
  let window = String.sub pending 0 stop in
  let prev_ended_word = state.prev_ended_word in
  match Secret_patterns.first_stream_hold ~prev_ended_word window with
  | Some { start = 0; owner = Some owner } ->
      let redacted =
        redact_text_mapped_with_lookbehind ~prev_ended_word state.redaction window
      in
      let pieces =
        match owner, List.rev redacted with
        | ( ( Secret_patterns.Sk_token_body
            | Secret_patterns.Stripe_token_body
            | Secret_patterns.Dotted_token_body
            | Secret_patterns.Header_value )
          , Secret_patterns.Masked { source; _ } :: _ )
          when source.past_byte = stop -> redacted
        | ( ( Secret_patterns.Sk_token_body
            | Secret_patterns.Stripe_token_body
            | Secret_patterns.Dotted_token_body
            | Secret_patterns.Header_value
            | Secret_patterns.Url_userinfo )
          , ([] | (Secret_patterns.Copied _ | Secret_patterns.Masked _) :: _) ) ->
            (* A URL credential has no match until its [@]; mask the window. *)
            [ Secret_patterns.Masked
                { source = { first_byte = 0; past_byte = stop }; replacement = "[REDACTED]" }
            ]
      in
      emit_mapped state emitted ~source_length:stop pieces;
      state.prev_ended_word <- false;
      let seen_at =
        match owner with
        | Secret_patterns.Url_userinfo -> String.contains window '@'
        | Secret_patterns.Sk_token_body
        | Secret_patterns.Stripe_token_body
        | Secret_patterns.Dotted_token_body
        | Secret_patterns.Header_value -> false
      in
      state.owned <- Some { owner; seen_at };
      Buffer.clear state.pending_line;
      state.next_bounded_flush_at <- stream_flush_threshold state.redaction;
      String.iter
        (token_incremental_char state emitted)
        (String.sub pending stop (String.length pending - stop))
  | Some { start = _; owner = Some _ | None } | None ->
      (* No unbounded body at byte 0: a PEM block or a complete match. The
         plain flush masks it and enters PEM ownership itself. *)
      emit_bounded_prefix state emitted stop

let redact_stream_chunk_mapped state chunk =
  let emitted = ref [] in
  (match state.mode with
   | Line_buffered ->
       String.iter
         (fun char ->
            Buffer.add_char state.pending_line char;
            if Char.equal char '\n' || Char.equal char '\r'
            then flush_complete_record state emitted
            else flush_bounded_prefix_if_needed state emitted)
         chunk
   | Token_incremental ->
       String.iter (token_incremental_char state emitted) chunk;
       flush_safe_incremental_prefix state emitted);
  { pieces = List.rev !emitted; consumed = state.consumed }
;;

let redact_stream_finish_mapped state =
  let emitted = ref [] in
  (* Bytes a URL credential owner still holds after its last [@] are the
     host: the authority ended with the stream. *)
  state.owned <- None;
  flush_complete_record state emitted;
  state.prev_ended_word <- false;
  state.in_unterminated_pem <- false;
  { pieces = List.rev !emitted; consumed = state.consumed }
;;

let redact_stream_chunk state chunk =
  Secret_patterns.render_pieces (redact_stream_chunk_mapped state chunk).pieces

let redact_stream_finish state =
  Secret_patterns.render_pieces (redact_stream_finish_mapped state).pieces

(* Keys as well as values. A secret can be the key -- a header name, a
   parameter used as a dict key, {"<secret>": "x"} straight from a tool
   argument -- and a traversal that only rewrites leaves emits it (#22941).
   Doing both here rather than in one caller means every boundary that reaches
   for the redactor gets the same policy; the alternative left two of three
   callers redacting values only, without saying so. *)
let rec redact_json_exact t = function
  | `String s -> `String (redact_text t s)
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) -> (redact_text t key, redact_json_exact t value))
           fields)
  | `List items -> `List (List.map (redact_json_exact t) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as json -> json

let redact_json t json =
  json |> redact_json_exact t |> Observability_redact.redact_json_strings

module For_testing = struct
  let shares_compiled_patterns a b = a.patterns == b.patterns
end
