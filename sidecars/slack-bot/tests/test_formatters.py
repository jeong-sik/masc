"""Tests for Slack message formatting."""

from __future__ import annotations

from src.formatters import (
    chunk_text,
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


class TestResponseBlocks:
    def test_produces_section_block(self) -> None:
        blocks = response_blocks("Hello world")
        assert len(blocks) == 1
        assert blocks[0]["type"] == "section"
        assert blocks[0]["text"]["text"] == "Hello world"

    def test_includes_context_when_metadata_present(self) -> None:
        blocks = response_blocks("Hi", keeper_name="sangsu", duration_ms=1000)
        assert len(blocks) == 2
        assert blocks[1]["type"] == "context"

    def test_no_context_when_no_metadata(self) -> None:
        blocks = response_blocks("Hi")
        assert len(blocks) == 1
