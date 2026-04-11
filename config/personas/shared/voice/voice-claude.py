#!/usr/bin/env python3
"""
Voice-activated Claude terminal interface
Usage: op run -- python3 voice-claude.py
"""

import os
import sys
import time
import subprocess
import tempfile
from pathlib import Path
from threading import Thread, Event
from pynput import keyboard
from openai import OpenAI
from anthropic import Anthropic

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')

# API clients
openai_client = OpenAI(api_key=os.environ.get("OPENAI_API_KEY"))
anthropic_client = Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

# State
recording = Event()
should_exit = Event()
audio_file_path = None


def print_banner():
    """Display welcome banner"""
    print("\n" + "=" * 50)
    print("🎤 Voice Claude - Interactive Voice Mode")
    print("=" * 50)
    print("\nCommands:")
    print("  Space:   Hold to record, release to send")
    print("  Ctrl+C:  Exit voice mode")
    print("=" * 50 + "\n")


def on_press(key):
    """Handle key press events"""
    try:
        if key == keyboard.Key.space and not recording.is_set():
            recording.set()
            print("\n🔴 Recording... (release Space to send)", flush=True)
    except AttributeError:
        pass


def on_release(key):
    """Handle key release events"""
    try:
        if key == keyboard.Key.space and recording.is_set():
            recording.clear()
            return False  # Stop listener
    except AttributeError:
        pass


def record_audio() -> str:
    """Record audio from microphone until Space is released"""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        audio_path = f.name

    try:
        # Start ffmpeg recording
        cmd = [
            "ffmpeg",
            "-f", "avfoundation",
            "-i", ":0",  # Default microphone
            "-acodec", "pcm_s16le",
            "-ar", "16000",
            "-ac", "1",
            "-y",
            audio_path
        ]

        process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        # Wait for Space release
        while recording.is_set():
            time.sleep(0.1)

        # Stop recording
        process.terminate()
        process.wait(timeout=5)

        return audio_path

    except Exception as e:
        log.error(f"❌ Recording error: {e}", file=sys.stderr)
        if os.path.exists(audio_path):
            os.unlink(audio_path)
        return None


def transcribe_audio(audio_path: str) -> str:
    """Transcribe audio using Whisper API"""
    try:
        print("📝 Transcribing...", flush=True)

        with open(audio_path, "rb") as audio_file:
            transcript = openai_client.audio.transcriptions.create(
                model="whisper-1",
                file=audio_file,
                language="ko"  # Korean support
            )

        return transcript.text.strip()

    except Exception as e:
        log.error(f"❌ Transcription error: {e}", file=sys.stderr)
        return None
    finally:
        # Cleanup audio file
        if os.path.exists(audio_path):
            os.unlink(audio_path)


def query_claude(text: str):
    """Query Claude API with streaming response"""
    try:
        print(f"\n💬 You: {text}")
        print("🤖 Claude: ", end="", flush=True)

        with anthropic_client.messages.stream(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=4096,
            messages=[{"role": "user", "content": text}]
        ) as stream:
            for text_chunk in stream.text_stream:
                print(text_chunk, end="", flush=True)

        print("\n")

    except Exception as e:
        print(f"\n❌ Claude error: {e}", file=sys.stderr)


def main():
    log_script_start(log, "Voice Claude")

    """Main voice mode loop"""
    # Check dependencies
    if not os.environ.get("OPENAI_API_KEY"):
        log.error(f"❌ OPENAI_API_KEY not found. Run with 'op run --'", file=sys.stderr)
        sys.exit(1)

    if not os.environ.get("ANTHROPIC_API_KEY"):
        log.error(f"❌ ANTHROPIC_API_KEY not found. Run with 'op run --'", file=sys.stderr)
        sys.exit(1)

    print_banner()

    try:
        while not should_exit.is_set():
            # Wait for Space press
            print("🎤 Ready to listen... (Press Space to talk)", flush=True)

            # Setup keyboard listener
            with keyboard.Listener(
                on_press=on_press,
                on_release=on_release
            ) as listener:
                listener.join()

            if should_exit.is_set():
                break

            # Record audio
            audio_path = record_audio()
            if not audio_path:
                continue

            # Transcribe
            text = transcribe_audio(audio_path)
            if not text:
                continue

            # Check for exit command
            if text.lower() in ["종료", "exit", "quit", "끝"]:
                print("👋 Exiting voice mode...")
                break

            # Query Claude
            query_claude(text)

            print("-" * 50)

    except KeyboardInterrupt:
        print("\n\n👋 Voice mode terminated.")

    finally:
        should_exit.set()


if __name__ == "__main__":
    main()
