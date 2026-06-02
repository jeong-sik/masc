#!/usr/bin/env python3
"""
Hybrid Voice Chat System
- STT: Whisper (local)
- LLM: Claude API
- TTS: ElevenLabs
"""

import os
import sys
import json
import time
import wave
import pyaudio
import requests
import subprocess
from pathlib import Path
from anthropic import Anthropic

# =============================================================================
# Configuration
# =============================================================================

WHISPER_URL = os.getenv("WHISPER_URL", "http://127.0.0.1:8010/v1/audio/transcriptions")
ELEVEN_API_KEY = os.getenv("ELEVEN_API_KEY")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")

# Audio settings
SAMPLE_RATE = 16000
CHANNELS = 1
CHUNK = 1024
RECORD_SECONDS = 10  # Max recording time
SILENCE_THRESHOLD = 500  # Adjust based on environment
SILENCE_DURATION = 1.5  # Seconds of silence to stop recording

# ElevenLabs settings
ELEVEN_VOICE_ID = "21m00Tcm4TlvDq8ikWAM"  # Rachel (default)
ELEVEN_MODEL = "eleven_multilingual_v2"

# =============================================================================
# Audio Recording
# =============================================================================

def record_audio(filename: str, max_duration: int = RECORD_SECONDS) -> str:
    """Record audio from microphone with silence detection"""
    print("🎤 Recording... (speak now)")

    audio = pyaudio.PyAudio()
    stream = audio.open(
        format=pyaudio.paInt16,
        channels=CHANNELS,
        rate=SAMPLE_RATE,
        input=True,
        frames_per_buffer=CHUNK
    )

    frames = []
    silent_chunks = 0
    chunks_per_second = SAMPLE_RATE // CHUNK
    silence_chunks_needed = int(SILENCE_DURATION * chunks_per_second)

    for i in range(0, int(SAMPLE_RATE / CHUNK * max_duration)):
        data = stream.read(CHUNK)
        frames.append(data)

        # Simple silence detection
        amplitude = sum(abs(int.from_bytes(data[i:i+2], 'little', signed=True))
                       for i in range(0, len(data), 2)) / (len(data) // 2)

        if amplitude < SILENCE_THRESHOLD:
            silent_chunks += 1
            if silent_chunks >= silence_chunks_needed and len(frames) > chunks_per_second:
                log.info(f"✅ Silence detected, stopping...")
                break
        else:
            silent_chunks = 0

    stream.stop_stream()
    stream.close()
    audio.terminate()

    # Save to WAV file
    wf = wave.open(filename, 'wb')
    wf.setnchannels(CHANNELS)
    wf.setsampwidth(audio.get_sample_size(pyaudio.paInt16))
    wf.setframerate(SAMPLE_RATE)
    wf.writeframes(b''.join(frames))
    wf.close()

    print(f"💾 Saved audio: {filename}")
    return filename

# =============================================================================
# Whisper STT
# =============================================================================

def transcribe_audio(audio_file: str) -> str:
    """Transcribe audio using local Whisper server"""
    print("🎧 Transcribing with Whisper...")

    with open(audio_file, 'rb') as f:
        files = {'file': ('audio.wav', f, 'audio/wav')}
        data = {'model': 'whisper-1', 'language': 'ko'}

        response = requests.post(WHISPER_URL, files=files, data=data)
        response.raise_for_status()

        result = response.json()
        text = result.get('text', '').strip()

    print(f"📝 Transcription: {text}")
    return text

# =============================================================================
# Claude LLM
# =============================================================================

def get_claude_response(user_message: str) -> str:
    """Get response from Claude API"""
    print("🤖 Getting Claude response...")

    client = Anthropic(api_key=ANTHROPIC_API_KEY)

    message = client.messages.create(
        model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-5-20250929"),
        max_tokens=1024,
        messages=[
            {"role": "user", "content": user_message}
        ]
    )

    response_text = message.content[0].text
    print(f"💬 Claude: {response_text[:100]}...")
    return response_text

# =============================================================================
# ElevenLabs TTS
# =============================================================================

def text_to_speech_eleven(text: str, output_file: str) -> str:
    """Convert text to speech using ElevenLabs"""
    print("🔊 Generating speech with ElevenLabs...")

    url = f"https://api.elevenlabs.io/v1/text-to-speech/{ELEVEN_VOICE_ID}"

    headers = {
        "Accept": "audio/mpeg",
        "Content-Type": "application/json",
        "xi-api-key": ELEVEN_API_KEY
    }

    data = {
        "text": text,
        "model_id": ELEVEN_MODEL,
        "voice_settings": {
            "stability": 0.5,
            "similarity_boost": 0.5
        }
    }

    response = requests.post(url, json=data, headers=headers)
    response.raise_for_status()

    with open(output_file, 'wb') as f:
        f.write(response.content)

    print(f"💾 Saved speech: {output_file}")
    return output_file

# =============================================================================
# Audio Playback
# =============================================================================

def play_audio(audio_file: str):
    """Play audio file using subprocess"""
    print(f"🔊 Playing: {audio_file}")

    try:
        if sys.platform == "darwin":  # macOS
            subprocess.run(["afplay", audio_file], check=True)
        elif sys.platform == "linux":
            subprocess.run(["aplay", audio_file], check=True)
        else:
            log.warning(f"⚠️ Playback not supported on this platform")
    except subprocess.CalledProcessError as e:
        log.warning(f"⚠️ Playback error: {e}")

# =============================================================================
# Main Loop
# =============================================================================

def main():
    log_script_start(log, "Voice Chat Elevenlabs")

    """Main voice chat loop"""

    # Check API keys
    if not ELEVEN_API_KEY:
        log.error(f"❌ ELEVEN_API_KEY not set")
        sys.exit(1)

    if not ANTHROPIC_API_KEY:
        log.error(f"❌ ANTHROPIC_API_KEY not set")
        sys.exit(1)

    print("=" * 60)
    print("🎙️ Whisper + ElevenLabs Voice Chat")
    print("=" * 60)
    print("STT: Whisper large-v3 (local)")
    print("LLM: Claude Sonnet 4.5")
    print("TTS: ElevenLabs (Rachel)")
    print("=" * 60)
    print()

    temp_dir = Path("/tmp/voice-chat")
    temp_dir.mkdir(exist_ok=True)

    turn = 0

    try:
        while True:
            turn += 1
            print(f"\n{'='*60}")
            print(f"Turn {turn}")
            print(f"{'='*60}\n")

            # 1. Record audio
            audio_input = temp_dir / f"input_{turn}.wav"
            record_audio(str(audio_input))

            # 2. Transcribe with Whisper
            user_text = transcribe_audio(str(audio_input))

            if not user_text:
                log.warning(f"⚠️ No speech detected, try again...")
                continue

            # Check for exit command
            if user_text.lower() in ['exit', 'quit', 'bye', '종료', '끝']:
                print("👋 Goodbye!")
                break

            # 3. Get Claude response
            response_text = get_claude_response(user_text)

            # 4. Generate speech with ElevenLabs
            audio_output = temp_dir / f"output_{turn}.mp3"
            text_to_speech_eleven(response_text, str(audio_output))

            # 5. Play response
            play_audio(str(audio_output))

            print(f"\n✅ Turn {turn} complete!")

    except KeyboardInterrupt:
        print("\n\n👋 Interrupted by user. Goodbye!")
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')
        traceback.print_exc()

if __name__ == "__main__":
    main()
