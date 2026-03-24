#!/usr/bin/env python3
"""
상수 Voice Client - Whisper STT + ElevenLabs TTS + Emotion Detection

**Services**:
- STT: ElevenLabs proxy (Railway) or WHISPER_URL env var
- TTS: ElevenLabs proxy (Railway) or TTS_URL env var
- Emotion: SpeechBrain emotion-recognition-wav2vec2-IEMOCAP

**Usage**:
  from sangsu_voice_client import VoiceClient

  client = VoiceClient()
  text, emotion = client.listen()  # Record + transcribe + emotion
  client.speak("안녕")    # Text to speech
"""

import io
import os
import wave
import tempfile
import subprocess
import requests
import pyaudio
import struct
import math
import threading
import time
from typing import Optional, Tuple


class VoiceClient:
    """음성 입출력 클라이언트"""

    # Local ElevenLabs proxy defaults (Voicemode docker: port 8010)
    DEFAULT_STT_URL = "http://127.0.0.1:8010/v1/audio/transcriptions"
    DEFAULT_TTS_URL = "http://127.0.0.1:8010/v1/audio/speech"

    def __init__(self,
                 stt_url: str = None,
                 tts_url: str = None,
                 voice: str = "CwhRBWXzGAHq8TQ4Fs17",
                 enable_emotion_detection: bool = True):
        self.stt_url = stt_url or os.getenv("WHISPER_URL", self.DEFAULT_STT_URL)
        self.tts_url = tts_url or os.getenv("TTS_URL", self.DEFAULT_TTS_URL)
        self.voice = voice
        self.enable_emotion_detection = enable_emotion_detection

        # Audio settings (Whisper 호환)
        self.CHUNK = 1024
        self.FORMAT = pyaudio.paInt16
        self.CHANNELS = 1
        self.RATE = 16000

        # VAD settings (간단한 에너지 기반)
        self.SILENCE_THRESHOLD = 500  # RMS threshold
        self.SILENCE_DURATION = 1.5   # seconds of silence to stop
        self.MIN_RECORD_DURATION = 1.0  # minimum recording time

        # Interrupt settings
        self.INTERRUPT_THRESHOLD = 800  # Higher than silence threshold
        self.interrupt_flag = threading.Event()

        self.audio = pyaudio.PyAudio()

        # Emotion detection (lazy loading)
        self.emotion_classifier = None
        if self.enable_emotion_detection:
            self._init_emotion_classifier()

    def _init_emotion_classifier(self):
        """Initialize SpeechBrain emotion classifier (lazy loading)"""
        try:
            from speechbrain.inference.classifiers import EncoderClassifier
            print("🧠 Loading emotion recognition model...")
            self.emotion_classifier = EncoderClassifier.from_hparams(
                source="speechbrain/emotion-recognition-wav2vec2-IEMOCAP",
                savedir=os.path.expanduser("~/me/.cache/speechbrain/emotion-recognition")
            )
            print("   ✅ Emotion model loaded")
        except Exception as e:
            print(f"   ⚠️  Failed to load emotion model: {e}")
            print("   Continuing without emotion detection...")
            self.emotion_classifier = None
            self.enable_emotion_detection = False

    def _calculate_rms(self, audio_chunk: bytes) -> float:
        """Calculate RMS (Root Mean Square) energy"""
        count = len(audio_chunk) / 2
        format_str = f"{int(count)}h"
        shorts = struct.unpack(format_str, audio_chunk)
        sum_squares = sum(s ** 2 for s in shorts)
        return math.sqrt(sum_squares / count)

    def _detect_emotion(self, wav_path: str) -> Optional[str]:
        """
        Detect emotion from audio file

        Returns:
            Emotion label (neutral, anger, happiness, sadness) or None
        """
        if not self.enable_emotion_detection or self.emotion_classifier is None:
            return None

        try:
            # Predict emotion
            out_prob, score, index, text_lab = self.emotion_classifier.classify_file(wav_path)

            # text_lab is a list, e.g., ['neu']
            emotion = text_lab[0] if text_lab else 'neutral'

            # Map IEMOCAP labels to our labels
            emotion_map = {
                'neu': 'neutral',
                'ang': 'anger',
                'hap': 'happiness',
                'sad': 'sadness'
            }

            return emotion_map.get(emotion, emotion)

        except Exception as e:
            print(f"   ⚠️  Emotion detection failed: {e}")
            return None

    def listen(self,
               max_duration: float = 10.0,
               verbose: bool = True) -> Tuple[Optional[str], Optional[str]]:
        """
        마이크로 녹음 + STT + Emotion Detection

        Args:
            max_duration: 최대 녹음 시간 (초)
            verbose: 상태 출력

        Returns:
            (text, emotion) tuple or (None, None)
        """
        if verbose:
            print("🎤 듣는 중... (말씀하세요)")

        stream = self.audio.open(
            format=self.FORMAT,
            channels=self.CHANNELS,
            rate=self.RATE,
            input=True,
            frames_per_buffer=self.CHUNK
        )

        frames = []
        silent_chunks = 0
        silence_threshold_chunks = int(self.SILENCE_DURATION * self.RATE / self.CHUNK)
        min_chunks = int(self.MIN_RECORD_DURATION * self.RATE / self.CHUNK)
        max_chunks = int(max_duration * self.RATE / self.CHUNK)

        try:
            for i in range(max_chunks):
                data = stream.read(self.CHUNK, exception_on_overflow=False)
                frames.append(data)

                # Energy-based VAD
                rms = self._calculate_rms(data)

                if rms < self.SILENCE_THRESHOLD:
                    silent_chunks += 1
                else:
                    silent_chunks = 0
                    if verbose and i == 0:
                        print("   🎙️  감지됨!")

                # Stop on silence (after minimum duration)
                if i > min_chunks and silent_chunks > silence_threshold_chunks:
                    if verbose:
                        print("   ✅ 침묵 감지, 종료")
                    break

        finally:
            stream.stop_stream()
            stream.close()

        if not frames:
            if verbose:
                print("   ⚠️  녹음 없음")
            return (None, None)

        # Save to WAV file
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_wav:
            wav_path = temp_wav.name
            wf = wave.open(wav_path, 'wb')
            wf.setnchannels(self.CHANNELS)
            wf.setsampwidth(self.audio.get_sample_size(self.FORMAT))
            wf.setframerate(self.RATE)
            wf.writeframes(b''.join(frames))
            wf.close()

        # Detect emotion (before STT, while we have the WAV file)
        voice_emotion = self._detect_emotion(wav_path) if self.enable_emotion_detection else None

        # Transcribe via Whisper
        try:
            with open(wav_path, 'rb') as audio_file:
                files = {
                    'file': ('audio.wav', audio_file, 'audio/wav')
                }
                data = {
                    'model': 'large-v3',
                    'language': 'ko'
                }

                response = requests.post(
                    self.stt_url,
                    files=files,
                    data=data,
                    timeout=30
                )

            os.unlink(wav_path)

            if response.status_code == 200:
                result = response.json()
                text = result.get('text', '').strip()

                if verbose:
                    print(f"   📝 인식: \"{text}\"")
                    if voice_emotion:
                        print(f"   🎭 음성 감정: {voice_emotion}")

                return (text if text else None, voice_emotion)
            else:
                if verbose:
                    print(f"   ❌ STT 실패: {response.status_code}")
                return (None, None)

        except Exception as e:
            if verbose:
                print(f"   ❌ STT 오류: {e}")
            return (None, None)

    def speak(self,
              text: str,
              speed: float = 1.0,
              stability: float = 0.5,
              similarity_boost: float = 0.75,
              verbose: bool = True) -> bool:
        """
        Text to Speech (ElevenLabs)

        Args:
            text: 발화할 텍스트
            speed: 말하기 속도 (0.25 ~ 4.0, default 1.0)
            stability: 음성 안정성 (0.0 ~ 1.0, default 0.5)
            similarity_boost: 음성 유사도 (0.0 ~ 1.0, default 0.75)
            verbose: 상태 출력

        Returns:
            Success boolean
        """
        if verbose:
            speed_emoji = "🐢" if speed < 0.9 else "🏃" if speed > 1.1 else "🔊"
            print(f"{speed_emoji} 말하는 중: \"{text}\" (speed={speed:.1f})")

        try:
            response = requests.post(
                self.tts_url,
                json={
                    'model': 'eleven_multilingual_v2',
                    'input': text,
                    'voice': self.voice,
                    'voice_settings': {
                        'stability': stability,
                        'similarity_boost': similarity_boost
                    }
                },
                timeout=30
            )

            if response.status_code == 200:
                # Save audio
                with tempfile.NamedTemporaryFile(suffix='.mp3', delete=False) as temp_mp3:
                    temp_mp3.write(response.content)
                    mp3_path = temp_mp3.name

                # Adjust speed if needed (using ffmpeg)
                if speed != 1.0:
                    adjusted_path = mp3_path.replace('.mp3', '_adjusted.mp3')
                    # ffmpeg -i input.mp3 -filter:a "atempo=1.5" output.mp3
                    result = subprocess.run([
                        'ffmpeg', '-i', mp3_path,
                        '-filter:a', f'atempo={speed}',
                        '-y',  # Overwrite
                        adjusted_path
                    ], capture_output=True, check=False)

                    if result.returncode == 0:
                        os.unlink(mp3_path)
                        mp3_path = adjusted_path
                    else:
                        # Fallback: use original speed
                        if verbose:
                            print(f"   ⚠️  Speed adjustment failed, using normal speed")

                # Play audio (macOS afplay) - SECURE: static command, no user input
                subprocess.run(['afplay', mp3_path], check=False)
                os.unlink(mp3_path)

                if verbose:
                    print("   ✅ 재생 완료")

                return True
            else:
                if verbose:
                    print(f"   ❌ TTS 실패: {response.status_code}")
                return False

        except Exception as e:
            if verbose:
                print(f"   ❌ TTS 오류: {e}")
            return False

    def _monitor_interrupt(self, duration: float = 10.0):
        """
        Background thread: monitor microphone for interrupt signal

        Args:
            duration: How long to monitor (seconds)
        """
        stream = self.audio.open(
            format=self.FORMAT,
            channels=self.CHANNELS,
            rate=self.RATE,
            input=True,
            frames_per_buffer=self.CHUNK
        )

        try:
            max_chunks = int(duration * self.RATE / self.CHUNK)

            for i in range(max_chunks):
                if self.interrupt_flag.is_set():
                    break

                data = stream.read(self.CHUNK, exception_on_overflow=False)
                rms = self._calculate_rms(data)

                # Detect interrupt (loud sound)
                if rms > self.INTERRUPT_THRESHOLD:
                    self.interrupt_flag.set()
                    break

        finally:
            stream.stop_stream()
            stream.close()

    def speak_with_interrupt(self,
                            text: str,
                            speed: float = 1.0,
                            stability: float = 0.5,
                            similarity_boost: float = 0.75,
                            verbose: bool = True) -> tuple[bool, bool]:
        """
        Speak with interrupt detection

        Returns:
            (success, interrupted)
        """
        # Reset interrupt flag
        self.interrupt_flag.clear()

        if verbose:
            speed_emoji = "🐢" if speed < 0.9 else "🏃" if speed > 1.1 else "🔊"
            print(f"{speed_emoji} 말하는 중 (interruptible): \"{text}\" (speed={speed:.1f})")

        try:
            # Generate TTS
            response = requests.post(
                self.tts_url,
                json={
                    'model': 'eleven_multilingual_v2',
                    'input': text,
                    'voice': self.voice,
                    'voice_settings': {
                        'stability': stability,
                        'similarity_boost': similarity_boost
                    }
                },
                timeout=30
            )

            if response.status_code != 200:
                if verbose:
                    print(f"   ❌ TTS 실패: {response.status_code}")
                return False, False

            # Save audio
            with tempfile.NamedTemporaryFile(suffix='.mp3', delete=False) as temp_mp3:
                temp_mp3.write(response.content)
                mp3_path = temp_mp3.name

            # Adjust speed if needed
            if speed != 1.0:
                adjusted_path = mp3_path.replace('.mp3', '_adjusted.mp3')
                result = subprocess.run([
                    'ffmpeg', '-i', mp3_path,
                    '-filter:a', f'atempo={speed}',
                    '-y',
                    adjusted_path
                ], capture_output=True, check=False)

                if result.returncode == 0:
                    os.unlink(mp3_path)
                    mp3_path = adjusted_path

            # Start interrupt monitoring thread
            # Estimate audio duration (rough)
            audio_duration = len(text) * 0.1  # ~0.1s per char
            monitor_thread = threading.Thread(
                target=self._monitor_interrupt,
                args=(audio_duration,)
            )
            monitor_thread.start()

            # Play audio in background (non-blocking)
            play_process = subprocess.Popen(
                ['afplay', mp3_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )

            # Wait for either completion or interrupt
            while play_process.poll() is None:
                if self.interrupt_flag.is_set():
                    # Interrupt detected!
                    play_process.terminate()
                    play_process.wait()

                    if verbose:
                        print("   ⚠️  인터럽트 감지! 중단")

                    os.unlink(mp3_path)
                    monitor_thread.join()
                    return True, True  # success, interrupted

                time.sleep(0.05)  # Check every 50ms

            # Completed without interrupt
            os.unlink(mp3_path)
            monitor_thread.join()

            if verbose:
                print("   ✅ 재생 완료")

            return True, False  # success, not interrupted

        except Exception as e:
            if verbose:
                print(f"   ❌ 오류: {e}")
            return False, False

    def __del__(self):
        """Cleanup"""
        if hasattr(self, 'audio'):
            self.audio.terminate()


def test_voice_client():
    """테스트"""
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎤 Voice Client 테스트")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

    client = VoiceClient()

    # Test TTS
    print("[1] TTS 테스트...")
    client.speak("야, 뭐해?")

    print("\n[2] STT 테스트...")
    text = client.listen(max_duration=5.0)

    if text:
        print(f"\n✅ 인식됨: \"{text}\"")
    else:
        print("\n⚠️  인식 실패")


if __name__ == "__main__":
    test_voice_client()
