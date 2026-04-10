"""Tests for Telegram message formatting."""

from __future__ import annotations

from src.formatters import chunk_text, format_footer, strip_state_blocks


class TestStripStateBlocks:
    def test_removes_state_block(self) -> None:
        text = "Hello [STATE]internal data[/STATE] world"
        assert strip_state_blocks(text) == "Hello  world"

    def test_removes_unclosed_state_block(self) -> None:
        text = "Hello [STATE]internal data without end"
        assert strip_state_blocks(text) == "Hello"

    def test_preserves_text_without_state(self) -> None:
        assert strip_state_blocks("plain text") == "plain text"

    def test_handles_empty_string(self) -> None:
        assert strip_state_blocks("") == ""

    def test_removes_multiline_state_block(self) -> None:
        text = "Before\n[STATE]\nline1\nline2\n[/STATE]\nAfter"
        assert strip_state_blocks(text) == "Before\n\nAfter"


class TestChunkText:
    def test_short_text_returns_single_chunk(self) -> None:
        assert chunk_text("hello") == ["hello"]

    def test_splits_on_newline(self) -> None:
        text = "a" * 2000 + "\n" + "b" * 2000
        chunks = chunk_text(text, limit=4096)
        assert len(chunks) == 1  # 4000 < 4096

    def test_splits_long_text(self) -> None:
        text = "word " * 1000  # ~5000 chars
        chunks = chunk_text(text, limit=100)
        assert len(chunks) > 1
        for chunk in chunks:
            assert len(chunk) <= 100

    def test_empty_text(self) -> None:
        assert chunk_text("") == [""]


class TestFormatFooter:
    def test_full_footer(self) -> None:
        result = format_footer("sangsu", "qwen3.5", 4500, 120)
        assert "sangsu" in result
        assert "4.5s" in result
        assert "qwen3.5" in result
        assert "120 tok" in result

    def test_empty_footer(self) -> None:
        assert format_footer("", "", 0, 0) == ""

    def test_partial_footer(self) -> None:
        result = format_footer("sangsu", "", 1000, 0)
        assert "sangsu" in result
        assert "1.0s" in result
