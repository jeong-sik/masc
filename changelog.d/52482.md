### Internal

- The board duplicate-comment guard fixtures post varied bodies: `test_identical_comments_are_distinct_writes` now keeps identical comments distinct across different authors and asserts the same-author repeat is refused with the guard message, and four fixtures (`test_changed_comment_dependency`, `test_durable_unlink_and_unselected_work`, `test_sweep_takes_an_expired_reply_out_of_the_post_count`, `test_board_source_is_acked_after_completed_turn`) vary their repeated comment bodies so `#52239`s guard no longer breaks them. Closes the Board cluster of the v0.73.0 release audit.
