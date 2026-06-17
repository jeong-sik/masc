(** Backend mirror of the dashboard's [parseTextToChatBlocks].

    Turns assistant reply text into a list of rich chat blocks so the
    server can own the parsing and the dashboard can render server-provided
    blocks verbatim.

    Supported shapes:
    - Markdown images [![alt](url)] become image blocks.
    - Bare image URLs (png/jpg/gif/webp/svg) on their own line become image blocks.
    - Other standalone URLs become link blocks with a hostname-derived title.
    - Remaining text becomes escaped HTML text blocks. *)

type image_block = {
  src : string;
  cap : string option;
}

type link_block = {
  url : string;
  title : string;
  meta : string;
}

type text_block = { html : string }

type chat_block =
  | Text of text_block
  | Image of image_block
  | Link of link_block

val parse_text_to_blocks : string -> chat_block list
val block_to_yojson : chat_block -> Yojson.Safe.t
val blocks_to_yojson : chat_block list -> Yojson.Safe.t
val blocks_of_yojson : Yojson.Safe.t -> chat_block list option
