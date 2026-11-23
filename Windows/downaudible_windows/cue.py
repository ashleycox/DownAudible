"""Export CUE indexes from one playable audio file’s embedded chapters."""

import os
import tempfile
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from pathlib import Path

from .archive import available_path
from .media import (
    OUTPUT_FORMATS,
    MediaError,
    check_cancel,
    check_source_revision,
    source_revision,
)


def supports_cue(path):
    return Path(path).suffix.lower().lstrip('.') in OUTPUT_FORMATS


def _seconds(value):
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        return None
    return result if result.is_finite() and result >= 0 else None


def _cue_text(value):
    return ' '.join(str(value or '').replace('"', '”').split())


def cue_sheet_data(path, probe):
    path = Path(path)
    if not supports_cue(path) or any(character in path.name for character in '\r\n"'):
        raise MediaError('Choose an M4B, M4A, or MP3 file with a name that can be used in a CUE sheet.')
    markers = probe.payload.get('chapters', ())
    if not markers:
        raise MediaError('This audio file has no embedded chapter markers.')
    if len(markers) > 99:
        raise MediaError('A CUE sheet can contain at most 99 chapters.')
    duration = _seconds(probe.audio.get('duration')) or _seconds(probe.payload.get('format', {}).get('duration'))
    if not duration:
        raise MediaError('The audio file has no usable duration for a CUE sheet.')

    lines = []
    for tag, value in (('TITLE', probe.tags.get('title')),
                       ('PERFORMER', probe.tags.get('artist') or probe.tags.get('author'))):
        if text := _cue_text(value):
            lines.append(f'{tag} "{text}"')
    file_type = 'MP3' if path.suffix.lower() == '.mp3' else 'WAVE'
    lines.append(f'FILE "{path.name}" {file_type}')
    previous = -1
    for number, marker in enumerate(markers, 1):
        start = _seconds(marker.get('start_time'))
        if start is None or start >= duration:
            raise MediaError('A chapter starts outside the audio timeline.')
        frames = int((start * 75).to_integral_value(rounding=ROUND_HALF_UP))
        if frames <= previous or Decimal(frames) >= duration * 75:
            raise MediaError('The chapter starts cannot be represented as distinct CUE indexes.')
        previous = frames
        minutes, remainder = divmod(frames, 60 * 75)
        seconds, frames = divmod(remainder, 75)
        title = _cue_text(marker.get('tags', {}).get('title')) or f'Chapter {number}'
        lines.extend((f'  TRACK {number:02d} AUDIO', f'    TITLE "{title}"',
                      f'    INDEX 01 {minutes:02d}:{seconds:02d}:{frames:02d}'))
    return ('\r\n'.join(lines) + '\r\n').encode('utf-8')


def write_cue_sheet(path, tools, *, cancel=None):
    path = Path(path).absolute()
    if not supports_cue(path):
        raise MediaError('Choose one M4B, M4A, or MP3 audio file.')
    revision = source_revision(path)
    data = cue_sheet_data(path, tools.probe(path, cancel=cancel))
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        for _ in range(100):
            check_cancel(cancel)
            check_source_revision(path, revision)
            target = available_path(path.parent, path.name, 'cue')
            try:
                if os.name == 'nt':
                    temporary.rename(target)
                else:
                    os.link(temporary, target)
            except FileExistsError:
                continue
            return target
        raise MediaError('DownAudible could not save the CUE sheet to an unused filename.')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
