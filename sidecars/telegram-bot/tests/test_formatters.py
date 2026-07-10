"""Tests for Telegram message formatting."""

from __future__ import annotations

from src.formatters import (
    chunk_text,
    format_footer,
    format_footer_html,
    render_response_text,
    structured_html_text,
)


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


class TestFormatFooterHtml:
    def test_escapes_footer_fields(self) -> None:
        result = format_footer_html("<keeper>", "qwen&sonnet", 1000, 2)
        assert result == "<i>&lt;keeper&gt;  |  1.0s  |  qwen&amp;sonnet  |  2 tok</i>"

    def test_empty_footer(self) -> None:
        assert format_footer_html("", "", 0, 0) == ""


class TestStructuredHtmlText:
    def test_projects_dashboard_blocks_to_telegram_html(self) -> None:
        result = structured_html_text(
            {
                "blocks": [
                    {"t": "p", "html": "hello &lt;world&gt;"},
                    {"t": "h4", "html": "Plan"},
                    {"t": "ul", "items": ["one", "two"]},
                    {"t": "callout", "severity": "warn", "html": "careful"},
                    {
                        "t": "table",
                        "head": ["name", {"v": "count", "num": True}],
                        "rows": [["alpha", "2"]],
                    },
                    {
                        "t": "code",
                        "cap": "python",
                        "html": "print(&quot;fallback&quot;)",
                        "source": 'print("<ok>")',
                    },
                    {
                        "t": "image",
                        "src": "https://example.com/chart.png?a=1&b=2",
                        "cap": "Chart <A>",
                    },
                    {"t": "mermaid", "source": "graph TD\nA-->B"},
                    {"t": "svg", "svg": "<svg><path /></svg>", "cap": "Icon"},
                    {
                        "t": "link",
                        "url": "https://example.com/post",
                        "title": "Post <one>",
                        "meta": "example.com",
                    },
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
                    {"t": "fusion", "board_post_id": "p-123", "run_id": "fus-9"},
                ]
            }
        )

        assert "hello &lt;world&gt;" in result
        assert "<b>Plan</b>" in result
        assert "- one\n- two" in result
        assert "<b>Callout (warn):</b> careful" in result
        assert "<pre>name | count\nalpha | 2</pre>" in result
        assert "<b>Code: python</b>" in result
        assert '<pre><code>print(&quot;&lt;ok&gt;&quot;)</code></pre>' in result
        assert (
            'Image: <a href="https://example.com/chart.png?a=1&amp;b=2">'
            "Chart &lt;A&gt;</a>"
        ) in result
        assert "<b>Mermaid</b>" in result
        assert "graph TD\nA--&gt;B" in result
        assert "<b>SVG: Icon</b>" in result
        assert "&lt;svg&gt;&lt;path /&gt;&lt;/svg&gt;" in result
        assert '<a href="https://example.com/post">Post &lt;one&gt;</a>' in result
        assert "<b>Audio (tts)</b>" in result
        assert '<a href="https://example.com/a.mp3">https://example.com/a.mp3</a>' in result
        assert "<b>Attachment (video):</b> clip.mp4" in result
        assert "<b>Video:</b> Demo" in result
        assert "<b>Fusion result</b>" in result
        assert "board_post_id: <code>p-123</code>" in result

    def test_ignores_malformed_blocks(self) -> None:
        assert structured_html_text({"blocks": [{"t": "image"}]}) == ""


class TestRenderResponseText:
    def test_returns_html_mode_for_structured_blocks(self) -> None:
        text, parse_mode = render_response_text(
            "fallback",
            {"blocks": [{"t": "p", "html": "structured"}]},
        )
        assert text == "structured"
        assert parse_mode == "HTML"

    def test_falls_back_to_plain_reply(self) -> None:
        text, parse_mode = render_response_text("plain <reply>", None)
        assert text == "plain <reply>"
        assert parse_mode is None
