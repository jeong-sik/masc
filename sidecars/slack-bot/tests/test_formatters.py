"""Tests for Slack message formatting."""

from __future__ import annotations

from src.formatters import (
    SLACK_BLOCK_TEXT_LIMIT,
    SLACK_MAX_BLOCKS,
    chunk_text,
    escape_mrkdwn_text,
    fallback_text,
    format_context_block,
    response_blocks,
    strip_state_blocks,
)


class TestStripStateBlocks:
    def test_removes_state_block(self) -> None:
        assert strip_state_blocks("Hi [STATE]data[/STATE] there") == "Hi  there"

    def test_removes_unclosed_block(self) -> None:
        assert strip_state_blocks("Hi [STATE]data") == "Hi"

    def test_preserves_plain_text(self) -> None:
        assert strip_state_blocks("plain") == "plain"


class TestChunkText:
    def test_short_text_single_chunk(self) -> None:
        assert chunk_text("hello") == ["hello"]

    def test_splits_long_text(self) -> None:
        text = "word " * 1000
        chunks = chunk_text(text, limit=100)
        assert len(chunks) > 1
        for chunk in chunks:
            assert len(chunk) <= 100


class TestEscapeMrkdwnText:
    def test_escapes_slack_control_chars(self) -> None:
        assert (
            escape_mrkdwn_text("<@U123> & <script>")
            == "&lt;@U123&gt; &amp; &lt;script&gt;"
        )

    def test_fallback_text_escapes_control_chars(self) -> None:
        assert fallback_text("<@U123> & ok") == "&lt;@U123&gt; &amp; ok"


class TestFormatContextBlock:
    def test_full_context(self) -> None:
        result = format_context_block("sangsu", "qwen3.5", 4500, 120)
        assert result is not None
        assert result["type"] == "context"
        text = result["elements"][0]["text"]
        assert "sangsu" in text
        assert "4.5s" in text
        assert "qwen3.5" in text
        assert "120 tok" in text

    def test_empty_returns_none(self) -> None:
        assert format_context_block("", "", 0, 0) is None

    def test_partial(self) -> None:
        result = format_context_block("sangsu", "", 0, 0)
        assert result is not None
        assert "sangsu" in result["elements"][0]["text"]

    def test_escapes_context_fields(self) -> None:
        result = format_context_block("<keeper>", "qwen&sonnet", 0, 0)
        assert result is not None
        text = result["elements"][0]["text"]
        assert "&lt;keeper&gt;" in text
        assert "qwen&amp;sonnet" in text


class TestResponseBlocks:
    def test_produces_section_block(self) -> None:
        blocks = response_blocks("Hello world")
        assert len(blocks) == 1
        assert blocks[0]["type"] == "section"
        assert blocks[0]["text"]["text"] == "Hello world"

    def test_escapes_section_text(self) -> None:
        blocks = response_blocks("<@U123> & <script>")
        assert blocks[0]["text"]["text"] == "&lt;@U123&gt; &amp; &lt;script&gt;"

    def test_includes_context_when_metadata_present(self) -> None:
        blocks = response_blocks("Hi", keeper_name="sangsu", duration_ms=1000)
        assert len(blocks) == 2
        assert blocks[1]["type"] == "context"

    def test_no_context_when_no_metadata(self) -> None:
        blocks = response_blocks("Hi")
        assert len(blocks) == 1

    def test_chunks_section_text_at_slack_block_limit(self) -> None:
        blocks = response_blocks("a" * (SLACK_BLOCK_TEXT_LIMIT + 10))
        assert len(blocks) == 2
        assert len(blocks[0]["text"]["text"]) == SLACK_BLOCK_TEXT_LIMIT
        assert len(blocks[1]["text"]["text"]) == 10

    def test_chunks_after_escape_expansion(self) -> None:
        blocks = response_blocks("<" * SLACK_BLOCK_TEXT_LIMIT)
        assert len(blocks) == 4
        for block in blocks:
            assert len(block["text"]["text"]) <= SLACK_BLOCK_TEXT_LIMIT

    def test_caps_blocks_and_marks_truncation(self) -> None:
        text = "a" * ((SLACK_BLOCK_TEXT_LIMIT * SLACK_MAX_BLOCKS) + 1)
        blocks = response_blocks(text, keeper_name="sangsu")
        assert len(blocks) == SLACK_MAX_BLOCKS
        assert blocks[-1]["type"] == "context"
        assert "[truncated: Slack block limit]" in blocks[-2]["text"]["text"]
        for block in blocks[:-1]:
            assert len(block["text"]["text"]) <= SLACK_BLOCK_TEXT_LIMIT
