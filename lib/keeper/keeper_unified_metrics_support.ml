let visible_text_feedback ~has_text ~is_visible_reply ~response_text =
  if has_text then short_preview response_text
  else ""
