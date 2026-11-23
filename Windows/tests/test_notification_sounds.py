"""Check durable, atomic imports of custom transfer sounds."""

import os
import shutil
import struct
import wave
from collections import deque
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import TestCase, skipUnless
from unittest.mock import Mock

from downaudible_windows.notification_sounds import (
    duration_ms,
    import_notification_sound,
)

FFMPEG = os.environ.get("DOWNAUDIBLE_FFMPEG") or shutil.which("ffmpeg")

try:
    from downaudible_windows.app import MainFrame
except ModuleNotFoundError as error:
    if error.name != "wx":
        raise
    MainFrame = None


class NotificationSoundTests(TestCase):
    def test_preserves_a_sound_after_the_original_moves_and_reuses_identical_bytes(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "A short chime.wav"
            with wave.open(str(original), "wb") as sound:
                sound.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
                sound.writeframes(b"\x00\x00" * 8)
            expected = original.read_bytes()
            profile = root / "profile"

            stored = import_notification_sound(original, profile)
            imported_again = import_notification_sound(original, profile)
            original.rename(root / "moved.wav")

            self.assertEqual(stored.parent, profile / "Notification Sounds")
            self.assertEqual(imported_again, stored)
            self.assertEqual(stored.read_bytes(), expected)
            self.assertEqual(list(stored.parent.iterdir()), [stored])

    def test_non_wave_file_is_not_published(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "Not a wave.wav"
            original.write_bytes(b"synthetic invalid WAV")
            profile = root / "profile"

            with self.assertRaisesRegex(ValueError, "Choose an audio file"):
                import_notification_sound(original, profile)
            self.assertFalse(list((profile / "Notification Sounds").iterdir()))

    @skipUnless(FFMPEG, "Requires FFmpeg")
    def test_imports_aiff_as_a_playable_wave_file(self):
        frames = 800
        samples = b"\x00\x00" * frames
        rate_8000 = bytes.fromhex("400bfa00000000000000")
        common = b"COMM" + struct.pack(">IhIh", 18, 1, frames, 16) + rate_8000
        sound = b"SSND" + struct.pack(">III", len(samples) + 8, 0, 0) + samples
        body = b"AIFF" + common + sound
        with TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "Chime.aiff"
            original.write_bytes(b"FORM" + struct.pack(">I", len(body)) + body)
            stored = import_notification_sound(original, root / "profile", ffmpeg=Path(FFMPEG))
            original.unlink()
            self.assertEqual(duration_ms(stored), 100)

    @skipUnless(MainFrame, "Requires wxPython")
    def test_finish_uses_current_preferences_and_opens_the_finished_batch(self):
        job = {"id": "book", "title": "Demo Book", "status": "Completed"}
        queue = Mock()
        queue.snapshot.return_value = {"current": None, "history": [{"id": "batch", "jobs": [job]}]}
        frame = SimpleNamespace(
            _closed=False, _load_receipts=Mock(), library=Mock(), queue=queue, notify=Mock(),
            settings={"notifications": {"downloadCompleted": {"delivery": "both", "sound": "warmChord"}}},
            _feedback_sounds=deque(), _feedback_timer=None, _play_next_feedback=Mock(), open_notification=Mock(),
        )

        MainFrame.finish_batch(frame, "batch", {"downloadCompleted": ["book"]}, {"notifications": {}})

        self.assertEqual(frame.notify.call_args.args, ("Demo Book", "Download Completed"))
        frame.notify.call_args.kwargs["on_click"]()
        frame.open_notification.assert_called_once_with("batch", ["book"])
        self.assertEqual(list(frame._feedback_sounds), [("warmChord", "")])
        frame._play_next_feedback.assert_called_once_with()
