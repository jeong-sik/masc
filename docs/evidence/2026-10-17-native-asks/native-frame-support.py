"""Render captured native terminal cells for manual review.

Paint every cell background before any glyph, preserving wide Korean glyphs.
This is a PTY-cell rendering, not an emulator screenshot or physical paint clock.
"""
import os
import signal
import socket
import subprocess
from PIL import Image, ImageDraw, ImageFont


def free_port():
    with socket.socket() as handle:
        handle.bind(("127.0.0.1", 0))
        return handle.getsockname()[1]


def stop(process):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def frame_image(screen, destination):
    cell_w, cell_h = 10, 21
    canvas = Image.new("RGB", (screen.columns * cell_w, screen.lines * cell_h), "#111418")
    draw = ImageDraw.Draw(canvas)
    latin = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15)
    korean = ImageFont.truetype("/System/Library/Fonts/AppleSDGothicNeo.ttc", 16)
    colours = {"default": "#d8dde5", "black": "#111418", "red": "#e06c75",
               "green": "#98c379", "brown": "#e5c07b", "blue": "#61afef",
               "magenta": "#c678dd", "cyan": "#56b6c2", "white": "#d8dde5"}

    def colour(value, fallback):
        if value in colours:
            return colours[value]
        if len(value) == 6 and all(c in "0123456789abcdefABCDEF" for c in value):
            return "#" + value
        return fallback

    foregrounds = {}
    for row in range(screen.lines):
        for col in range(screen.columns):
            cell = screen.buffer[row][col]
            foreground = colour(cell.fg, "#d8dde5")
            background = "#111418" if cell.bg == "default" else colour(cell.bg, "#111418")
            if cell.reverse:
                foreground, background = background, foreground
            foregrounds[row, col] = foreground
            x, y = col * cell_w, row * cell_h
            draw.rectangle((x, y, x + cell_w - 1, y + cell_h - 1), fill=background)
    for row in range(screen.lines):
        for col in range(screen.columns):
            cell = screen.buffer[row][col]
            if cell.data and cell.data != " ":
                font = korean if any(ord(c) > 0x2fff for c in cell.data) else latin
                draw.text((col * cell_w, row * cell_h), cell.data, font=font,
                          fill=foregrounds[row, col])
    canvas.save(destination)
