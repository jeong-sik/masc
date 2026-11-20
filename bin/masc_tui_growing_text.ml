(* A stretch's text in two parts: the finished lines, already converted for
   the screen and fed to an MD5 context, and the bytes of the line that has
   not ended, as they arrived. A streaming 1 MB reply converted and digested
   the whole text again for every delta, about a third of each frame. *)
type t = {
  closed_text : Buffer.t;
  mutable closed_md5 : Agent_core_md5.ctx;
  open_line : Buffer.t;
  stretch : int;
}

type snapshot = { text : string; closed : int; identity : Digest.t; stretch : int }

let bytes_converted = Atomic.make 0

let safe text =
  ignore (Atomic.fetch_and_add bytes_converted (String.length text) : int);
  Masc_tui_keeper_chat_projection.terminal_safe_text ~preserve_newlines:true text

let create ~stretch =
  { closed_text = Buffer.create 256; closed_md5 = Agent_core_md5.empty;
    open_line = Buffer.create 64; stretch }

let append t delta =
  match String.rindex_opt delta '\n' with
  | None -> Buffer.add_string t.open_line delta
  | Some last ->
      Buffer.add_substring t.open_line delta 0 (last + 1);
      let finished = safe (Buffer.contents t.open_line) in
      Buffer.clear t.open_line;
      Buffer.add_string t.closed_text finished;
      t.closed_md5 <- Agent_core_md5.feed_string t.closed_md5 finished;
      Buffer.add_substring t.open_line delta (last + 1) (String.length delta - last - 1)

let snapshot t =
  let open_text = safe (Buffer.contents t.open_line) in
  let closed = Buffer.length t.closed_text in
  let text = Bytes.create (closed + String.length open_text) in
  Buffer.blit t.closed_text 0 text 0 closed;
  Bytes.blit_string open_text 0 text closed (String.length open_text);
  let identity =
    Digest.from_hex (Agent_core_md5.to_hex (Agent_core_md5.feed_string t.closed_md5 open_text))
  in
  { text = Bytes.unsafe_to_string text; closed; identity; stretch = t.stretch }

module For_testing = struct
  let bytes_converted () = Atomic.get bytes_converted
end
