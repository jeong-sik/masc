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
    structured_response_blocks,
)


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

    def test_uses_structured_blocks_when_present(self) -> None:
        structured = {
            "blocks": [
                {"t": "p", "html": "hello &lt;world&gt;"},
                {
                    "t": "code",
                    "cap": "python",
                    "html": "print(&quot;fallback&quot;)",
                    "source": 'print("&lt;<ok>")',
                },
                {"t": "image", "src": "https://example.com/chart.png", "cap": "Chart"},
                {
                    "t": "link",
                    "url": "https://example.com/post?a=1&b=2",
                    "title": "Post <one>",
                    "meta": "example.com",
                },
                {"t": "fusion", "board_post_id": "p-123", "run_id": "fus-9"},
            ]
        }
        blocks = response_blocks(
            "fallback",
            keeper_name="sangsu",
            structured=structured,
        )

        assert len(blocks) == 6
        assert blocks[0]["text"]["text"] == "hello &lt;world&gt;"
        assert "*Code:* `python`" in blocks[1]["text"]["text"]
        assert 'print("&amp;lt;&lt;ok&gt;")' in blocks[1]["text"]["text"]
        assert blocks[2]["type"] == "image"
        assert blocks[2]["image_url"] == "https://example.com/chart.png"
        assert "Post &lt;one&gt;" in blocks[3]["text"]["text"]
        assert "a=1&amp;b=2" in blocks[3]["text"]["text"]
        assert "board_post_id: p-123" in blocks[4]["text"]["text"]
        assert blocks[5]["type"] == "context"

    def test_malformed_structured_blocks_fall_back_to_text(self) -> None:
        blocks = response_blocks("<fallback>", structured={"blocks": [{"t": "image"}]})
        assert len(blocks) == 1
        assert blocks[0]["text"]["text"] == "&lt;fallback&gt;"


class TestStructuredResponseBlocks:
    def test_projects_known_dashboard_block_shapes(self) -> None:
        blocks = structured_response_blocks(
            {
                "blocks": [
                    {"t": "p", "html": "hello &amp; goodbye"},
                    {"t": "code", "html": "a &lt; b"},
                    {"t": "image", "src": "https://example.com/a.png"},
                    {
                        "t": "link",
                        "url": "https://example.com",
                        "title": "Example",
                    },
                    {"t": "fusion", "board_post_id": "p-abc"},
                ]
            }
        )

        assert [block["type"] for block in blocks] == [
            "section",
            "section",
            "image",
            "section",
            "section",
        ]
        assert blocks[0]["text"]["text"] == "hello &amp; goodbye"
        assert "a &lt; b" in blocks[1]["text"]["text"]
        assert blocks[2]["alt_text"] == "image"
        assert "*<https://example.com|Example>*" in blocks[3]["text"]["text"]
        assert "p-abc" in blocks[4]["text"]["text"]

    def test_projects_extended_dashboard_block_shapes(self) -> None:
        blocks = structured_response_blocks(
            {
                "blocks": [
                    {"t": "h4", "html": "Plan"},
                    {"t": "ul", "items": ["one", "two"]},
                    {"t": "callout", "severity": "warn", "html": "careful"},
                    {
                        "t": "table",
                        "head": ["name", {"v": "count", "num": True}],
                        "rows": [["alpha", "2"]],
                    },
                    {"t": "mermaid", "source": "graph TD\nA-->B"},
                    {"t": "svg", "svg": "<svg><path /></svg>"},
                    {
                        "t": "voice",
                        "src": "https://example.com/a.mp3",
                        "transcript": "spoken memo",
                        "via": "tts",
                    },
                    {
                        "t": "attach",
                        "name": "clip.mp4",
                        "src": "https://example.com/clip.mp4",
                        "kind": "video",
                    },
                    {
                        "t": "video",
                        "src": "https://example.com/demo.mp4",
                        "cap": "Demo",
                    },
                ]
            }
        )

        assert len(blocks) == 9
        assert blocks[0]["text"]["text"] == "*Plan*"
        assert "- one\n- two" in blocks[1]["text"]["text"]
        assert "*Callout (warn):* careful" in blocks[2]["text"]["text"]
        assert "name | count\nalpha | 2" in blocks[3]["text"]["text"]
        assert "*Code:* `mermaid`" in blocks[4]["text"]["text"]
        assert "*Code:* `svg`" in blocks[5]["text"]["text"]
        assert "*Audio (tts):*" in blocks[6]["text"]["text"]
        assert "Attachment (video)" in blocks[7]["text"]["text"]
        assert "*Video:* Demo" in blocks[8]["text"]["text"]
