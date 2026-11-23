"""Keep durable copies of user-selected Windows notification sounds."""

import os
import shutil
import subprocess
import wave
from hashlib import file_digest
from math import ceil
from pathlib import Path
from tempfile import TemporaryDirectory


def duration_ms(source: Path) -> int:
    try:
        with wave.open(str(source), "rb") as audio:
            rate = audio.getframerate()
            return ceil(audio.getnframes() * 1000 / rate) if rate else 0
    except (OSError, EOFError, wave.Error):
        return 0


def import_notification_sound(source: Path, data_dir: Path, *, ffmpeg: Path | None = None) -> Path:
    storage = data_dir / "Notification Sounds"
    storage.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".import-", dir=storage) as scratch:
        staged = Path(scratch) / "sound.wav"
        if duration_ms(source):
            shutil.copyfile(source, staged)
        elif ffmpeg is not None:
            try:
                result = subprocess.run(
                    [ffmpeg, "-nostdin", "-v", "error", "-i", source, "-map", "0:a:0",
                     "-c:a", "pcm_s16le", "-ac", "2", staged],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), timeout=60,
                )
            except subprocess.TimeoutExpired as error:
                raise ValueError("DownAudible could not prepare this sound in time.") from error
            if result.returncode:
                raise ValueError("Choose an audio file DownAudible can play, such as WAV, AIFF, M4A, or MP3.")
        if not duration_ms(staged):
            raise ValueError("Choose an audio file DownAudible can play, such as WAV, AIFF, M4A, or MP3.")
        with staged.open("r+b") as stream:
            digest = file_digest(stream, "sha256").hexdigest()
            os.fsync(stream.fileno())
        sound = storage / f"{digest}.wav"
        if not sound.is_file():
            staged.replace(sound)
        return sound
