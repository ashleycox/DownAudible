from __future__ import annotations

import json
import math
import os
import re
import shutil
import stat
import subprocess
import tempfile
from collections.abc import Callable, Iterable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from io import BytesIO
from pathlib import Path
from threading import Event

AUDIO_FORMATS = frozenset({'aa', 'aax', 'aaxc', 'm4a', 'm4b', 'mp3'})
PROTECTED_FORMATS = frozenset({'aa', 'aax', 'aaxc'})
OUTPUT_FORMATS = frozenset({'m4a', 'm4b', 'mp3'})
SAMPLE_RATES = (8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000)
AUDIO_MAPPING = ['-map', '0:a:0', '-map_metadata', '-1', '-map_chapters', '-1']
Progress = Callable[[float], None]


class MediaError(ValueError):
    pass


class MediaCancelled(MediaError):
    def __init__(self):
        super().__init__('The operation was cancelled.')


class ActivationRequired(MediaError):
    def __init__(self):
        super().__init__('This AAX file needs the eight activation characters from the account that downloaded it.')


@dataclass(frozen=True)
class MediaInput:
    path: Path
    activation_bytes: str = field(default='', repr=False)
    audible_key: str = field(default='', repr=False)
    audible_iv: str = field(default='', repr=False)
    expected_revision: tuple[int, int, int, int] | None = None

    def __post_init__(self):
        object.__setattr__(self, 'path', Path(self.path).absolute())

    @property
    def format(self) -> str:
        return self.path.suffix.lower().lstrip('.')


@dataclass(frozen=True)
class Chapter:
    start_ms: int
    end_ms: int
    title: str


@dataclass(frozen=True)
class BookSection:
    id: int
    source_index: int
    title: str
    start_ms: int
    end_ms: int
    chapter_index: int | None


@dataclass(frozen=True)
class OutputSpec:
    format: str
    chapter_number: int | None = None
    chapter_title: str | None = None
    edited: bool = False
    name_suffix: str = ''


@dataclass(frozen=True)
class LocalAudio:
    path: Path
    format: str
    asin: str | None
    title: str
    author: str | None
    duration_seconds: float | None
    collection: str | None = None
    collection_author: str | None = None
    metadata: dict[str, str] = field(default_factory=dict)
    is_segment: bool = False


@dataclass(frozen=True)
class AudioProbe:
    payload: dict

    @property
    def audio(self) -> dict:
        return next((stream for stream in self.payload.get('streams', ()) if stream.get('codec_type') == 'audio'), {})

    @property
    def artwork(self) -> dict | None:
        return next((stream for stream in self.payload.get('streams', ())
                     if stream.get('codec_type') == 'video'
                     and stream.get('disposition', {}).get('attached_pic') == 1
                     and stream.get('codec_name') in {'mjpeg', 'png'}
                     and 0 < stream.get('width', 0) <= 8192
                     and 0 < stream.get('height', 0) <= 8192), None)

    @property
    def duration_ms(self) -> int:
        return next((time for value in (self.audio.get('duration'), self.payload.get('format', {}).get('duration'))
                     if (time := milliseconds(value))), 0)

    @property
    def tags(self) -> dict[str, str]:
        return {key.lower(): str(value) for key, value in self.payload.get('format', {}).get('tags', {}).items()}

    @property
    def legacy_clock(self) -> bool:
        return (self.payload.get('format', {}).get('format_name') == 'aa'
                or self.audio.get('codec_name') == 'sipr')

    @property
    def concat_parameters(self) -> tuple:
        return tuple(self.audio.get(key) for key in ('codec_name', 'profile', 'sample_rate', 'channels', 'extradata_hash'))

    def chapters(self, start_number: int) -> list[Chapter]:
        return [Chapter(milliseconds(raw.get('start_time')), milliseconds(raw.get('end_time')),
                        str(raw.get('tags', {}).get('title', '')).strip() or f'Chapter {number}')
                for number, raw in enumerate(self.payload.get('chapters', ()), start_number)]


@dataclass(frozen=True)
class PreparedInput:
    source: MediaInput
    probe: AudioProbe
    arguments: list[str]
    revision: tuple[int, int, int, int]


@dataclass(frozen=True)
class ConversionOptions:
    format: str = 'm4b'
    chapter_mode: str = 'single'
    audio_mode: str = 'automatic'
    bitrate: int = 0
    channels: int = 0
    sample_rate: int = 0
    mp3_bitrate_mode: str = 'automatic'
    mp3_quality: int = 2
    embed_artwork: bool = True
    preserve_metadata: bool = True
    embed_chapters: bool = True
    copy_chapter_audio: bool = False
    move_aax_to_trash: bool = False

    @classmethod
    def read(cls, values: Mapping | ConversionOptions | None) -> ConversionOptions:
        if isinstance(values, cls):
            return values
        return cls(**{key: values[key] for key in cls.__dataclass_fields__ if values and key in values})

    @property
    def muxer(self) -> str:
        return 'mp3' if self.format == 'mp3' else 'ipod'

    @property
    def variable_mp3(self) -> bool:
        return self.format == 'mp3' and self.mp3_bitrate_mode == 'variable'

    @property
    def maximum_channels(self) -> int:
        return 2 if self.format == 'mp3' else 6

    def maximum_bitrate(self, rate: int, channels: int) -> int:
        if self.format == 'mp3':
            return 320 if rate >= 32000 else 160 if rate >= 16000 else 64
        return rate * channels * 6 // 1000

    @property
    def has_incompatible_bitrate(self) -> bool:
        return bool(self.sample_rate and not self.variable_mp3 and
                    self.bitrate > self.maximum_bitrate(self.sample_rate, self.channels or self.maximum_channels))

    @property
    def can_copy_chapter_audio(self) -> bool:
        return (self.chapter_mode == 'separate' and self.format != 'mp3'
                and not any((self.bitrate, self.channels, self.sample_rate)))

    def validate(self):
        if (self.format not in OUTPUT_FORMATS or self.chapter_mode not in {'single', 'separate'}
                or self.audio_mode not in {'automatic', 'encode'}
                or self.mp3_bitrate_mode not in {'automatic', 'constant', 'variable'}
                or self.channels not in {0, 1, 2} or self.sample_rate not in (0, *SAMPLE_RATES)
                or self.mp3_quality not in range(10) or not isinstance(self.bitrate, int)
                or not 0 <= self.bitrate <= 320):
            raise MediaError('Check the output format and audio settings before converting.')
        if self.has_incompatible_bitrate:
            raise MediaError('Choose a lower bitrate or a higher sample rate for these audio settings.')


@dataclass(frozen=True)
class AudioEncoding:
    channel_count: int
    sample_rate: int
    copy: bool
    arguments: list[str]

    @classmethod
    def plan(cls, options: ConversionOptions, sources: Sequence[PreparedInput], slicing: bool):
        probes = [source.probe for source in sources]
        channels = options.channels or min(options.maximum_channels,
                                           max(int(probe.audio.get('channels', 1)) for probe in probes))
        source_rate = max(int(probe.audio.get('sample_rate', 44100)) for probe in probes)
        rates = SAMPLE_RATES if options.format == 'mp3' else (*SAMPLE_RATES, 64000, 88200, 96000)
        preferred_rate = next((rate for rate in rates if rate >= source_rate), rates[-1])
        bitrate = 0 if options.variable_mp3 else options.bitrate
        codec = 'mp3' if options.format == 'mp3' else 'aac'

        if (options.audio_mode == 'automatic' and not slicing and not options.bitrate and not options.channels
                and not options.sample_rate and (codec != 'mp3' or options.mp3_bitrate_mode == 'automatic')
                and not any(source.source.format == 'aa' or source.probe.legacy_clock for source in sources)
                and probes[0].audio.get('codec_name') == codec
                and all(probe.concat_parameters == probes[0].concat_parameters for probe in probes)):
            return cls(channels, preferred_rate, True, ['-c:a', 'copy'])

        rate = options.sample_rate or next((rate for rate in rates if rate >= preferred_rate
                                             and bitrate <= options.maximum_bitrate(rate, channels)), preferred_rate)
        max_bitrate = options.maximum_bitrate(rate, channels)
        if bitrate > max_bitrate:
            raise MediaError('Choose a lower bitrate or a higher sample rate for these audio settings.')
        arguments = ['-c:a', 'libmp3lame' if codec == 'mp3' else codec, '-ar', str(rate), '-ac', str(channels)]
        if options.variable_mp3:
            arguments += ['-q:a', str(options.mp3_quality)]
        else:
            bitrate = bitrate or min(64 if channels == 1 else 128, max_bitrate)
            arguments += ['-b:a', f'{bitrate}k']
        return cls(channels, rate, False, arguments)


@dataclass(frozen=True)
class LosslessChapter:
    source_index: int
    sample_rate: int
    sample_count: int
    start_sample: int

    def _microseconds(self, samples: int) -> int:
        return (samples * 1_000_000 + self.sample_rate // 2) // self.sample_rate

    @property
    def seek_arguments(self) -> list[str]:
        seek = max(0, self.start_sample - self.sample_rate // 4)
        offset = self.start_sample - seek
        if not offset:
            return []
        return ['-ss', f'{self._microseconds(seek)}us', '-itsoffset', f'-{self._microseconds(offset)}us']

    @property
    def output_arguments(self) -> list[str]:
        return ['-c:a', 'copy', '-t', f'{self._microseconds(self.sample_count)}us',
                '-bsf:a', f"setts=duration='max(1,min(DURATION,{self.sample_count}-PTS))'",
                '-avoid_negative_ts', 'disabled', '-use_editlist', '1', '-movie_timescale', str(self.sample_rate)]

    def matches(self, probe: AudioProbe) -> bool:
        return (probe.audio.get('codec_name') == 'aac' and probe.audio.get('time_base') == f'1/{self.sample_rate}'
                and probe.audio.get('start_pts') == 0 and probe.audio.get('duration_ts') == self.sample_count)


def check_cancel(cancel: Event | None):
    if cancel is not None and cancel.is_set():
        raise MediaCancelled()


def source_revision(path: Path) -> tuple[int, int, int, int]:
    try:
        attributes = path.stat()
    except OSError:
        raise MediaError('The source audio file is missing or unavailable.') from None
    if not stat.S_ISREG(attributes.st_mode):
        raise MediaError('Choose a regular audio file.')
    return attributes.st_dev, attributes.st_ino, attributes.st_size, attributes.st_mtime_ns


def check_source_revision(path: Path, revision):
    if source_revision(path) != tuple(revision):
        raise MediaError('The source audio changed. Select the file again or reopen Edit Book.')


def milliseconds(value) -> int:
    try:
        seconds = float(value)
        return math.floor(seconds * 1000 + 0.5) if math.isfinite(seconds) and 0 <= seconds < 1e12 else 0
    except (TypeError, ValueError):
        return 0


def _seconds(value: int) -> str:
    return f'{value // 1000}.{value % 1000:03d}'


def _hex(value: str, size: int) -> bool:
    return isinstance(value, str) and re.fullmatch(rf'[0-9a-fA-F]{{{size}}}', value) is not None


def valid_activation_bytes(value: str) -> bool:
    return _hex(value, 8)


def _activation_failure(errors: bytes) -> bool:
    diagnostics = errors.lower()
    return any(message in diagnostics for message in (b'[aax] mismatch in checksums',
               b'[aax] error in drm blob decryption', b'[aax] activation_bytes option is missing',
               b'[aax] activation_bytes value needs to be 4 bytes'))


def _source_arguments(source: Path, private_options: Sequence[str] = ()) -> list[str]:
    return [*private_options, '-format_whitelist', 'aa,mov,mp3', '-i', str(source)]


def _media_inputs(sources: Path | str | MediaInput | Iterable[Path | MediaInput]) -> list[MediaInput]:
    if isinstance(sources, (Path, str, MediaInput)):
        sources = [sources]
    result = [source if isinstance(source, MediaInput) else MediaInput(source) for source in sources]
    if not result:
        raise MediaError('Choose at least one audio file.')
    if any(source.format not in AUDIO_FORMATS for source in result):
        raise MediaError('Choose an AA, AAX, AAXC, M4A, M4B or MP3 audio file.')
    return result


def _scale_progress(progress: Progress | None, start: float, span: float) -> Progress | None:
    if progress is None:
        return None
    return lambda fraction: progress(start + fraction * span)


def _run(executable: Path, arguments: Sequence[str], cancel: Event | None, *,
         progress: Progress | None = None, duration: int = 0, cwd: Path | None = None) -> tuple[int, bytes, bytes]:
    check_cancel(cancel)
    try:
        with (
            tempfile.TemporaryFile() as diagnostics,
            subprocess.Popen(
                [str(executable), *arguments], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=diagnostics, cwd=cwd, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
            ) as process,
        ):
            try:
                if progress and duration:
                    _read_progress(process, progress, duration, cancel)
                    output = b''
                else:
                    while True:
                        check_cancel(cancel)
                        try:
                            output, _ = process.communicate(timeout=0.2)
                            break
                        except subprocess.TimeoutExpired:
                            continue
            except BaseException:
                if process.poll() is None:
                    process.kill()
                process.wait()
                raise
            diagnostics.seek(0)
            return process.returncode, output, diagnostics.read(65536)
    except OSError as error:
        if error.errno == 28 or getattr(error, 'winerror', 0) in {39, 112}:
            raise MediaError('The destination ran out of space.') from None
        raise MediaError('DownAudible could not start its bundled media tool.') from None


def _read_progress(process: subprocess.Popen, progress: Progress, duration: int, cancel: Event | None):
    # A reader thread keeps progress responsive even when the child stops writing.
    def read():
        assert process.stdout is not None
        for line in process.stdout:
            if line.startswith(b'out_time_us='):
                value = line.partition(b'=')[2].strip()
                if value.isdigit():
                    progress(min(0.99, int(value) / (duration * 1000)))

    with ThreadPoolExecutor(max_workers=1) as reader:
        result = reader.submit(read)
        while process.poll() is None:
            if result.done():
                result.result()
            if cancel is not None and cancel.wait(0.2):
                process.kill()
                break
            try:
                process.wait(timeout=0.2 if cancel is None else 0)
            except subprocess.TimeoutExpired:
                pass
        process.wait()
        check_cancel(cancel)
        result.result()


def read_voucher(path: Path) -> tuple[str, str] | None:
    sidecar = Path(path).with_suffix('.voucher')
    data = _read_companion(sidecar, 1_048_576)
    if data is None:
        return None
    try:
        payload = json.loads(data.decode('utf-8-sig'))
        license_response = payload.get('content_license', {}).get('license_response', payload)
        key = license_response.get('key') or license_response.get('contentKey')
        iv = license_response.get('iv') or license_response.get('contentIV')
        return (key, iv) if _hex(key, 32) and _hex(iv, 32) else None
    except (ValueError, AttributeError):
        return None


def _read_companion(path: Path, limit: int) -> bytes | None:
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or _is_link(path) or not 0 < before.st_size <= limit:
            return None
        mode = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_BINARY', 0)
        with os.fdopen(os.open(path, mode), 'rb') as stream:
            opened = os.fstat(stream.fileno())
            if not os.path.samestat(before, opened) or opened.st_mtime_ns != before.st_mtime_ns:
                return None
            data = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
            if len(data) == before.st_size and after.st_size == before.st_size and after.st_mtime_ns == before.st_mtime_ns:
                return data
    except OSError:
        return None
    return None


class MediaTools:
    def __init__(self, ffmpeg: Path, ffprobe: Path):
        self.ffmpeg = Path(ffmpeg).absolute()
        self.ffprobe = Path(ffprobe).absolute()

    def probe(self, path: Path, *, metadata_only=False, cancel: Event | None = None,
              arguments: Sequence[str] | None = None) -> AudioProbe:
        path = Path(path).absolute()
        if not path.is_file():
            raise MediaError('The source audio file is missing or unavailable.')
        mode = ['-nofind_stream_info'] if metadata_only else ['-analyzeduration', '1000000', '-probesize', '65536']
        command = ['-v', 'error', *mode, '-show_format', '-show_streams', '-show_chapters',
                   '-show_data_hash', 'sha256', '-of', 'json', *(arguments or _source_arguments(path))]
        status, output, errors = _run(self.ffprobe, command, cancel)
        diagnostic = errors.lower()
        if path.suffix.lower() == '.aax' and _activation_failure(errors):
            raise ActivationRequired()
        if status and b'permission denied' in diagnostic:
            raise MediaError('DownAudible does not have permission to read the source audio.')
        if status:
            raise MediaError('DownAudible could not read the audio file.')
        try:
            probe = AudioProbe(json.loads(output))
            audio = probe.audio
        except (ValueError, AttributeError):
            raise MediaError('DownAudible could not read the audio file.') from None
        if not audio:
            raise MediaError('The file does not contain an audio track.')
        return probe

    def scan(self, path: Path, *, cancel: Event | None = None) -> list[LocalAudio]:
        path = Path(path).absolute()
        if path.is_file():
            files = [path]
        elif path.is_dir():
            files = []
            for folder, directories, names in os.walk(path, followlinks=False):
                check_cancel(cancel)
                directories[:] = [name for name in directories if not name.startswith('.')
                                  and not _is_link(Path(folder) / name)]
                files.extend(Path(folder) / name for name in names if not name.startswith('.'))
        else:
            raise MediaError('Choose an audio file or a folder that contains audio.')
        audio = [file for file in files if file.suffix.lower().lstrip('.') in AUDIO_FORMATS
                 and file.is_file() and not _is_link(file)]
        with ThreadPoolExecutor(max_workers=4) as workers:
            results = workers.map(lambda file: self._local_audio(file, cancel), audio)
            return sorted(results, key=lambda item: (item.title.casefold(), str(item.path).casefold()))

    def _local_audio(self, path: Path, cancel: Event | None) -> LocalAudio:
        tags = {}
        duration = None
        stream_language = None
        try:
            probe = self.probe(path, metadata_only=True, cancel=cancel)
            tags, duration = probe.tags, probe.duration_ms / 1000 or None
            stream_language = probe.audio.get('tags', {}).get('language')
        except MediaCancelled:
            raise
        except MediaError:
            pass
        def tag(*names):
            return next((value for key in names if (value := (tags.get(key) or tags.get('com.apple.itunes:' + key)
                                                              or '').strip())), None)

        identifier = _tagged_identifier(tags)
        if identifier is None and (match := re.search(r'(?<![A-Z0-9])B0[A-Z0-9]{8}(?![A-Z0-9])', path.stem,
                                                      flags=re.IGNORECASE)):
            identifier = match[0].upper()
        collection = tag('parent_title', 'album')
        stem = re.sub(r'_AAXC?(?:_[0-9]+)*$', '', path.stem, flags=re.IGNORECASE)
        fallback = re.sub(r'(?<![A-Z0-9])B0[A-Z0-9]{8}(?![A-Z0-9])', '', stem, flags=re.IGNORECASE)
        title = tag('title') or collection or fallback.replace('_', ' ').strip(' -[]()') or path.stem
        author = tag('artist', 'author', 'album_artist')
        collection_author = tag('author', 'album_artist')
        format = path.suffix.lower().lstrip('.')
        narrator = tag('narrator', 'narrated_by', 'read_by', 'reader', 'nrt')
        if not narrator and (format in {*PROTECTED_FORMATS, 'm4b'} or 'audiobook' in (tag('genre') or '').casefold()):
            narrator = tag('composer')
        year = re.search(r'(?<!\d)\d{4}(?!\d)', tag('date', 'release_date', 'pubdate', 'year') or '')
        fields = {'authors': tag('authors', 'artist', 'author', 'album_artist'), 'subtitle': tag('subtitle'),
                  'narrator': narrator, 'narrators': tag('narrators') or narrator, 'series': tag('series', 'series_title'),
                  'seriesNumber': tag('series-part', 'series_part', 'series_number', 'series_sequence'),
                  'publisher': tag('publisher', 'provider'), 'year': year[0] if year else None,
                  'language': tag('language', 'lang') or (stream_language if stream_language != 'und' else None)}
        totals = [tag(key) for key in ('tracktotal', 'totaltracks', 'disctotal', 'totaldiscs')]
        totals += [(tag(key) or '').partition('/')[2] for key in ('track', 'disc')]
        is_segment = _is_edited(tags) or any(total and total.isascii() and total.isdecimal() and int(total) > 1
                                             for total in totals)
        return LocalAudio(path, format, identifier, title, author, duration, collection, collection_author,
                          {key: value for key, value in fields.items() if value}, is_segment)

    def audio_issue(self, path: Path, expected_size: int | None = None, *, cancel: Event | None = None) -> str | None:
        path = Path(path).absolute()
        try:
            before = path.lstat()
        except FileNotFoundError:
            return 'missing'
        except OSError:
            return 'unreadable'
        if not stat.S_ISREG(before.st_mode) or _is_link(path):
            return 'unreadable'
        if not before.st_size or (expected_size is not None and before.st_size != expected_size):
            return 'incomplete'
        try:
            if path.suffix.lower().lstrip('.') in PROTECTED_FORMATS:
                readable = self.probe(path, metadata_only=True, cancel=cancel).duration_ms > 0
            else:
                status, _, errors = _run(self.ffmpeg, ['-nostdin', '-v', 'error', '-xerror', *_source_arguments(path),
                                                       '-map', '0:a:0', '-vn', '-sn', '-dn', '-f', 'null', '-'], cancel)
                readable = not status and not errors
            if source_revision(path) != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) or _is_link(path):
                return 'incomplete'
            return None if readable else 'unreadable'
        except MediaCancelled:
            raise
        except MediaError:
            return 'unreadable'

    def _prepare(self, inputs, workspace, activation, refresh_activation, cancel):
        result = []
        refreshed = None
        for index, source in enumerate(inputs):
            check_cancel(cancel)
            revision = source.expected_revision or source_revision(source.path)
            if source.format == 'aax':
                source = replace(source, activation_bytes=refreshed or source.activation_bytes or activation)
            try:
                result.append(self._prepare_input(source, index, workspace, cancel, revision=revision))
            except ActivationRequired:
                if source.format != 'aax' or refresh_activation is None or refreshed is not None:
                    raise
                refreshed = refresh_activation()
                source = replace(source, activation_bytes=refreshed)
                result.append(self._prepare_input(source, index, workspace, cancel, revision=revision))
        return result

    def _prepare_input(self, source, index, workspace, cancel, *, revision=None):
        revision = revision or source_revision(source.path)
        check_source_revision(source.path, revision)
        private_options = []
        if source.format == 'aax':
            if not valid_activation_bytes(source.activation_bytes):
                raise ActivationRequired()
            private_options = self._private_arguments(workspace, index, {'activation_bytes': source.activation_bytes})
        if source.format == 'aaxc':
            key, iv = source.audible_key, source.audible_iv
            if not (_hex(key, 32) and _hex(iv, 32)):
                key, iv = read_voucher(source.path) or ('', '')
            if not (_hex(key, 32) and _hex(iv, 32)):
                raise MediaError('This AAXC file needs the saved licence or a compatible .voucher beside the audio.')
            private_options = self._private_arguments(workspace, index, {'audible_key': key, 'audible_iv': iv})
        arguments = _source_arguments(source.path, private_options)
        probe = self.probe(source.path, cancel=cancel, arguments=arguments)
        if source.format in {'aax', 'aaxc'}:
            status, _, diagnostics = _run(self.ffmpeg, ['-nostdin', '-v', 'error', '-xerror', *arguments,
                                            '-map', '0:a:0', '-frames:a', '3', '-f', 'null', '-'], cancel)
            if source.format == 'aax' and _activation_failure(diagnostics):
                raise ActivationRequired()
            if status:
                if source.format == 'aaxc':
                    raise MediaError('DownAudible could not read the AAXC audio with the saved licence.')
                raise MediaError('DownAudible could not decode the AAX audio. Check that the source file is complete.')
        check_source_revision(source.path, revision)
        return PreparedInput(source, probe, arguments, revision)

    @staticmethod
    def _private_arguments(workspace, index, secrets):
        arguments = []
        for name, secret in secrets.items():
            path = workspace / f'{name}-{index}'
            path.write_text(secret, encoding='ascii')
            arguments.extend([f'-/{name}', str(path)])
        return arguments

    def sections(self, inputs, *, activation_bytes='', chapters=None, chapter_repair=None, refresh_activation=None,
                 cancel: Event | None = None) -> list[BookSection]:
        with tempfile.TemporaryDirectory(prefix='DownAudible-') as directory:
            sources = self._prepare(_media_inputs(inputs), Path(directory), activation_bytes, refresh_activation, cancel)
            markers = _repair_markers(sources, chapter_repair) if chapter_repair is not None else _chapters(sources, chapters)
            return _section_layout(sources, markers)

    def preview(self, inputs, section: BookSection, destination: Path, *, end=False,
                activation_bytes='', refresh_activation=None, cancel: Event | None = None) -> Path:
        inputs = _media_inputs(inputs)
        if not 0 <= section.source_index < len(inputs):
            raise MediaError('The source audio has changed. Open Edit Book again.')
        with tempfile.TemporaryDirectory(prefix='DownAudible-') as directory:
            workspace = Path(directory)
            source, = self._prepare([inputs[section.source_index]], workspace, activation_bytes, refresh_activation, cancel)
            if not 0 <= section.start_ms < section.end_ms <= source.probe.duration_ms:
                raise MediaError('The source audio has changed. Open Edit Book again.')
            length = min(10000, section.end_ms - section.start_ms)
            start = section.end_ms - length if end else section.start_ms
            destination = Path(destination).absolute()
            arguments = self._section_arguments(source, start, start + length)
            with tempfile.TemporaryDirectory(prefix='.DownAudible-', dir=destination.parent) as staging:
                preview = Path(staging) / 'preview.wav'
                self._encode([*arguments, '-c:a', 'pcm_s16le', '-ac', '2', '-ar', '44100', '-f', 'wav', str(preview)],
                             workspace, cancel)
                check_source_revision(source.source.path, source.revision)
                _publish([preview], [destination], {}, cancel)
            return destination

    def convert(self, inputs, destination: Path, options: Mapping | ConversionOptions | None = None, *,
                metadata: Mapping | None = None, chapters=None, artwork: Path | None = None,
                excluded_sections: Iterable[int] = (), expected_sections=None, destinations=None, chapter_repair=None,
                refresh_activation=None, progress: Progress | None = None, cancel: Event | None = None) -> list[Path]:
        profile = ConversionOptions.read(options)
        profile.validate()
        excluded = set(excluded_sections)
        if (excluded or chapter_repair is not None) and (profile.format != 'm4b' or profile.chapter_mode != 'single'):
            raise MediaError('Book edits require a single M4B file.')
        if chapter_repair is not None:
            profile = replace(profile, embed_chapters=True)
        activation = options.get('activation_bytes', '') if isinstance(options, Mapping) else ''
        selected = Path(destination).absolute()
        destination = selected.resolve()
        with tempfile.TemporaryDirectory(prefix='DownAudible-') as directory:
            workspace = Path(directory)
            sources = self._prepare(_media_inputs(inputs), workspace, activation, refresh_activation, cancel)
            return self._convert(sources, destination, selected, profile, workspace, metadata or {}, chapters, artwork,
                                 excluded, expected_sections, destinations, progress, cancel, chapter_repair)

    def _convert(self, sources, destination, selected, profile, workspace, metadata, chapters, artwork,
                 excluded, expected_sections, destinations, progress, cancel, chapter_repair):
        markers = _repair_markers(sources, chapter_repair) if chapter_repair is not None else _chapters(sources, chapters)
        duration = sum(source.probe.duration_ms for source in sources)
        segments = []
        if excluded or expected_sections is not None:
            layout = _section_layout(sources, markers)
            if expected_sections is not None and layout != [section if isinstance(section, BookSection)
                                                            else BookSection(**section) for section in expected_sections]:
                raise MediaError('The source audio or chapters have changed. Open Edit Book again.')
            if excluded:
                segments, markers = _select_sections(layout, excluded)
                duration = sum(end - start for _, start, end in segments)

        edited = bool(excluded)
        edited_tags = edited or any(_is_edited(source.probe.tags) for source in sources)
        clips = _clips(profile, markers, duration, edited)
        if chapter_repair is not None and not edited:
            clips = [(replace(spec, name_suffix=' - Chapters Repaired'), bounds) for spec, bounds in clips]
        encoding = AudioEncoding.plan(profile, sources, bool(segments) or clips[0][1] is not None)
        lossless = _lossless_chapters(profile, clips, sources)
        output_specs = [spec for spec, _ in clips]
        paths = destinations(output_specs) if destinations else _default_destinations(destination, sources, output_specs, metadata)
        final_paths = []
        for path in paths:
            path = Path(path).absolute()
            if path.is_relative_to(selected):
                path = destination / path.relative_to(selected)
            final_paths.append(path)
        if len(final_paths) != len(clips) or len({_path_key(path) for path in final_paths}) != len(clips):
            raise MediaError('The conversion needs a different destination for each output file.')
        if any(os.path.lexists(path) for path in final_paths):
            raise MediaError('The conversion destination is already in use.')
        stage_dirs = {}
        directory_ids = {}
        staged = []
        try:
            for final in final_paths:
                parent = final.parent
                if parent not in stage_dirs:
                    directory_ids[parent] = _prepare_output_folder(destination, parent)
                    staging = Path(tempfile.mkdtemp(prefix='.DownAudible-', dir=parent))
                    directory_ids[staging] = _directory_identity(staging)
                    stage_dirs[parent] = staging
                staged.append(stage_dirs[parent] / f'{len(staged)}.{profile.format}')

            span = 0.5 if segments or len(sources) > 1 else 0
            audio, filter_arguments, inputs, direct = self._audio_source(
                sources, segments, profile, encoding, workspace, slices=clips[0][1] is not None,
                progress=_scale_progress(progress, 0, span), cancel=cancel)
            artwork = _prepare_artwork(artwork, workspace) if profile.embed_artwork else None
            covers = self._covers(sources, artwork, inputs, direct) if profile.embed_artwork else []
            tags = _tags(sources, metadata, profile) if profile.preserve_metadata else {}
            for index, ((spec, bounds), target) in enumerate(zip(clips, staged, strict=True)):
                clip_metadata = workspace / f'metadata-{index}.txt'
                keep_markers = bounds is None and profile.embed_chapters
                clip_tags = _split_tags(tags, spec, len(clips))
                if edited_tags:
                    clip_tags[_tag_key('DOWNAUDIBLE_EDITED', profile)] = '1'
                _write_metadata(clip_metadata, clip_tags, markers if keep_markers else ())
                report = _scale_progress(progress, span + index * (1 - span) / len(clips), (1 - span) / len(clips))
                copied = lossless[index]
                if copied is not None:
                    source = sources[copied.source_index]
                    copied_covers = self._covers([source], artwork, 1, True) if profile.embed_artwork else []
                    try:
                        self._render(target, profile, [*copied.seek_arguments, *source.arguments], [], 1,
                                     copied.output_arguments, clip_metadata, copied_covers, workspace, cancel,
                                     bounds[1] - bounds[0], report)
                        if copied.matches(self.probe(target, metadata_only=True, cancel=cancel)):
                            continue
                    except MediaCancelled:
                        raise
                    except MediaError:
                        pass
                    target.unlink(missing_ok=True)
                seek = ['-ss', _seconds(bounds[0])] if bounds and bounds[0] else []
                duration_args = ['-t', _seconds(bounds[1] - bounds[0])] if bounds else []
                self._render(target, profile, [*seek, *audio], filter_arguments, inputs,
                             [*encoding.arguments, *duration_args], clip_metadata, covers, workspace, cancel,
                             bounds[1] - bounds[0] if bounds else duration, report)
            for source in sources:
                check_source_revision(source.source.path, source.revision)
            _publish(staged, final_paths, directory_ids, cancel)
            if progress:
                progress(1)
            return final_paths
        finally:
            for staging in stage_dirs.values():
                if _same_directory(staging, directory_ids[staging]):
                    shutil.rmtree(staging, ignore_errors=True)

    def _audio_source(self, sources, segments, profile, encoding, workspace, *, slices, progress, cancel):
        needs_intermediate = segments or (len(sources) > 1 and (slices or encoding.copy))
        needs_intermediate = needs_intermediate or (slices and sources[0].probe.legacy_clock)
        if needs_intermediate:
            copy_parts = encoding.copy and not segments
            extension = ('mp3' if profile.format == 'mp3' else 'm4a') if copy_parts else 'flac'
            pieces = segments or [(index, 0, source.probe.duration_ms) for index, source in enumerate(sources)]
            filenames = []
            for index, (source_index, start, end) in enumerate(pieces):
                source = sources[source_index]
                part = workspace / f'part-{index}.{extension}'
                if copy_parts:
                    arguments = [*source.arguments, *AUDIO_MAPPING, '-c:a', 'copy', '-avoid_negative_ts', 'make_zero']
                    if extension == 'm4a':
                        arguments += ['-use_editlist', '0']
                    arguments += ['-f', profile.muxer]
                else:
                    arguments = [*self._section_arguments(source, start, end), '-c:a', 'flac', '-sample_fmt', 's32',
                                 '-bits_per_raw_sample', '24', '-ar', str(encoding.sample_rate), '-ac',
                                 str(encoding.channel_count), '-f', 'flac']
                self._encode([*arguments, str(part)], workspace, cancel, end - start,
                             _scale_progress(progress, index / len(pieces), 1 / len(pieces)))
                filenames.append(part.name)
            manifest = workspace / 'parts.ffconcat'
            manifest.write_text('ffconcat version 1.0\n' + ''.join(f"file '{name}'\n" for name in filenames),
                                encoding='ascii', newline='\n')
            return ['-f', 'concat', '-safe', '1', '-i', str(manifest)], [], 1, False
        if len(sources) == 1:
            source = sources[0]
            reset_clock = ['-af', 'asetpts=N/SR/TB'] if source.probe.legacy_clock and not encoding.copy else []
            return source.arguments, reset_clock, 1, True
        normalized = [f'[{index}:a:0]aformat=sample_rates={encoding.sample_rate}:'
                      f'channel_layouts={encoding.channel_count}c,asetpts=N/SR/TB[a{index}]'
                      for index in range(len(sources))]
        pads = ''.join(f'[a{index}]' for index in range(len(sources)))
        normalized.append(f'{pads}concat=n={len(sources)}:v=0:a=1[book]')
        return [value for source in sources for value in source.arguments], ['-filter_complex', ';'.join(normalized)], len(sources), False

    @staticmethod
    def _section_arguments(source, start, end):
        length = end - start
        if source.probe.legacy_clock and length:
            audio_filter = f'asetpts=N/SR/TB,atrim=start={_seconds(start)}:duration={_seconds(length)},asetpts=N/SR/TB'
            return [*source.arguments, *AUDIO_MAPPING, '-af', audio_filter]
        seek = ['-ss', _seconds(start)] if start else []
        limit = ['-t', _seconds(length)] if length else []
        return [*seek, *source.arguments, *AUDIO_MAPPING, *limit]

    @staticmethod
    def _covers(sources, artwork, inputs, direct):
        candidates = []
        if artwork is not None:
            demuxer = 'png_pipe' if artwork.suffix == '.png' else 'jpeg_pipe'
            candidates.append((['-f', demuxer, '-max_pixels', '67108864', '-i', str(artwork)], f'{inputs}:v:0'))
        for source in sources:
            if cover := source.probe.artwork:
                arguments = [] if direct else source.arguments
                candidates.append((arguments, f'{0 if direct else inputs}:{cover["index"]}'))
                break
        return candidates

    def _render(self, target, profile, audio, filter_arguments, inputs, encoding, metadata, covers,
                workspace, cancel, duration, progress):
        for cover_args, cover_stream in [*covers, ([], None)]:
            metadata_index = str(inputs + bool(cover_args))
            map_audio = '[book]' if '-filter_complex' in filter_arguments else '0:a:0'
            arguments = [*audio, *cover_args, '-f', 'ffmetadata', '-i', str(metadata), *filter_arguments,
                         '-map', map_audio, '-map_metadata', metadata_index, '-map_chapters', metadata_index, *encoding]
            if cover_stream is not None:
                arguments += ['-map', cover_stream, '-c:v', 'copy', '-disposition:v', 'attached_pic']
                if profile.format == 'mp3':
                    arguments += ['-metadata:s:v', 'comment=Cover (front)']
            arguments += ['-id3v2_version', '3'] if profile.format == 'mp3' else ['-movflags', '+faststart']
            arguments += ['-f', profile.muxer, str(target)]
            try:
                self._encode(arguments, workspace, cancel, duration, progress)
                return
            except MediaCancelled:
                raise
            except MediaError:
                if cover_stream is None:
                    raise
                target.unlink(missing_ok=True)

    def _encode(self, arguments, workspace, cancel, duration=0, progress=None):
        prefix = ['-hide_banner', '-loglevel', 'error', '-nostdin', '-n', '-xerror']
        if progress and duration:
            prefix += ['-progress', 'pipe:1']
        status, _, errors = _run(self.ffmpeg, [*prefix, *arguments], cancel,
                                 progress=progress, duration=duration, cwd=workspace)
        if status:
            diagnostic = errors.lower()
            if b'no space left' in diagnostic or b'disk full' in diagnostic:
                raise MediaError('The destination ran out of space.')
            if b'permission denied' in diagnostic:
                raise MediaError('DownAudible does not have permission to write the conversion.')
            raise MediaError('DownAudible could not convert the selected audio.')


def _is_link(path: Path) -> bool:
    return path.is_symlink() or path.is_junction()


def _directory_identity(path: Path) -> tuple[int, int]:
    attributes = path.lstat()
    # Windows reparse tags mark path-redirecting entries with the name-surrogate bit.
    name_surrogate = getattr(attributes, 'st_reparse_tag', 0) & 0x20000000
    if (not stat.S_ISDIR(attributes.st_mode) or path != path.resolve() or _is_link(path)
            or name_surrogate):
        raise MediaError('An output folder is a link or was moved. Choose a different destination.')
    return attributes.st_dev, attributes.st_ino


def _same_directory(path: Path, identity) -> bool:
    try:
        return _directory_identity(path) == identity
    except (OSError, MediaError):
        return False


def _prepare_output_folder(root: Path, parent: Path) -> tuple[int, int]:
    if not parent.is_relative_to(root) or parent != parent.resolve():
        raise MediaError('The conversion output must stay inside the destination folder.')
    if os.name == 'nt':
        from .archive import WINDOWS_PATH_UNITS, windows_path_units

        # The temporary directory and numbered output filename need room within MAX_PATH.
        if windows_path_units(parent) > WINDOWS_PATH_UNITS - 34:
            raise MediaError('The output folder path is too long. Choose a shorter destination.')
    root.mkdir(parents=True, exist_ok=True)
    identity = _directory_identity(root)
    directory = root
    for component in parent.relative_to(root).parts:
        directory = directory / component
        directory.mkdir(exist_ok=True)
        identity = _directory_identity(directory)
    return identity


def _path_key(path: Path) -> str:
    return str(path.resolve()).casefold()


def _prepare_artwork(path: Path | None, workspace: Path) -> Path | None:
    if path is None:
        return None
    data = _read_companion(Path(path), 25_000_000)
    if data is None:
        return None
    try:
        try:
            from PIL import Image
        except ImportError:
            # The shipped runtime includes Pillow. A source checkout can still copy PNG/JPEG through FFmpeg.
            if data.startswith(b'\x89PNG\r\n\x1a\n'):
                kind = 'PNG'
            elif data.startswith(b'\xff\xd8\xff'):
                kind = 'JPEG'
            else:
                return None
        else:
            try:
                with Image.open(BytesIO(data), formats=['JPEG', 'PNG', 'WEBP']) as image:
                    if not (1 <= image.width <= 8192 and 1 <= image.height <= 8192):
                        return None
                    kind = image.format
                    if kind == 'WEBP':
                        image.thumbnail((4096, 4096))
                        destination = workspace / 'cover.png'
                        image.convert('RGBA').save(destination, format='PNG')
                        return destination
                    image.verify()
            except (OSError, ValueError, Image.DecompressionBombError):
                return None
        destination = workspace / ('cover.png' if kind == 'PNG' else 'cover.jpg')
        destination.write_bytes(data)
        return destination
    except OSError:
        return None


def _default_destinations(directory: Path, sources: Sequence[PreparedInput], specs: Sequence[OutputSpec], metadata: Mapping) -> list[Path]:
    from .archive import available_path

    tags = sources[0].probe.tags
    title = metadata.get('title') or tags.get('title') or tags.get('parent_title') or sources[0].source.path.stem
    result = []
    for spec in specs:
        stem = title
        if spec.chapter_number is not None:
            stem += f' - {spec.chapter_number:02d} - {spec.chapter_title}'
        result.append(available_path(directory, stem, spec.format, occupied=result,
                                     suffix=' - Edited' if spec.edited else spec.name_suffix))
    return result


def _publish(staged: Sequence[Path], final: Sequence[Path], directory_ids, cancel: Event | None):
    published = []
    try:
        for source, destination in zip(staged, final, strict=True):
            check_cancel(cancel)
            for folder in (source.parent, destination.parent):
                if folder in directory_ids and not _same_directory(folder, directory_ids[folder]):
                    raise MediaError('An output folder was moved or replaced during conversion.')
            identity = source.lstat()
            if not stat.S_ISREG(identity.st_mode) or _is_link(source):
                raise MediaError('A temporary output changed during conversion.')
            if os.name == 'nt':
                source.rename(destination)
            else:
                # A Unix rename would replace an existing file, even after an existence check.
                os.link(source, destination)
            published.append((destination, identity))
    except BaseException as error:
        for path, identity in published:
            try:
                parent_identity = directory_ids.get(path.parent)
                if (parent_identity is None or _same_directory(path.parent, parent_identity)) and os.path.samestat(path.lstat(), identity):
                    path.unlink()
            except OSError:
                pass
        if isinstance(error, FileExistsError):
            raise MediaError('The conversion destination is already in use.') from None
        raise


def _clips(profile: ConversionOptions, markers: Sequence[Chapter], duration: int, edited: bool):
    if profile.chapter_mode != 'separate' or not duration or not markers:
        return [(OutputSpec(profile.format, edited=edited), None)]
    starts = [(marker.start_ms, marker.title) for marker in markers if marker.start_ms < duration]
    if not starts:
        return [(OutputSpec(profile.format, edited=edited), None)]
    if starts[0][0] > 0:
        starts.insert(0, (0, 'Introduction'))
    ends = [start for start, _ in starts[1:]] + [duration]
    return [(OutputSpec(profile.format, index, title), (start, end))
            for index, ((start, title), end) in enumerate(zip(starts, ends, strict=True), 1)]


def _lossless_chapters(profile, clips, sources):
    results = [None] * len(clips)
    if not profile.copy_chapter_audio or not profile.can_copy_chapter_audio or clips[0][1] is None:
        return results
    first = sources[0].probe
    rate = int(first.audio.get('sample_rate', 0))
    if first.audio.get('codec_name') != 'aac' or first.audio.get('profile') != 'LC' or not 7350 <= rate <= 96000:
        return results
    ranges = []
    offset = 0
    for source in sources:
        probe = source.probe
        size = probe.audio.get('duration_ts', 0)
        if (probe.concat_parameters != first.concat_parameters or probe.audio.get('time_base') != f'1/{rate}'
                or probe.audio.get('start_pts') != 0 or not isinstance(size, int) or size <= 0):
            return results
        ranges.append((offset, offset + size))
        offset += size
    for index, (_, (start, end)) in enumerate(clips):
        start_sample = (start * rate + 500) // 1000
        end_sample = offset if index + 1 == len(clips) else (end * rate + 500) // 1000
        for source_index, (low, high) in enumerate(ranges):
            if low <= start_sample < end_sample <= high:
                results[index] = LosslessChapter(source_index, rate, end_sample - start_sample, start_sample - low)
                break
    return results


def _clean_markers(markers: Iterable[Chapter], duration: int = 0) -> list[Chapter]:
    result = []
    for marker in sorted(markers, key=lambda item: item.start_ms):
        if duration:
            marker = replace(marker, end_ms=min(marker.end_ms, duration))
        if 0 <= marker.start_ms < marker.end_ms and (not result or marker.start_ms != result[-1].start_ms):
            result.append(marker)
    return result


def _chapters(sources: Sequence[PreparedInput], supplied: Iterable[Mapping | Chapter] | None) -> list[Chapter]:
    markers = []
    offset = 0
    durations_known = True
    for index, source in enumerate(sources, 1):
        duration = source.probe.duration_ms
        embedded = _clean_markers(source.probe.chapters(len(markers) + 1), duration)
        if not embedded and duration:
            title = f'Part {index}' if len(sources) > 1 else (source.probe.tags.get('title') or source.source.path.stem)
            embedded = [Chapter(0, duration, title)]
        markers.extend(Chapter(marker.start_ms + offset, marker.end_ms + offset, marker.title) for marker in embedded)
        if not (duration or embedded):
            durations_known = False
            break
        offset += duration or embedded[-1].end_ms
    provided = []
    for raw in supplied or ():
        if isinstance(raw, Chapter):
            provided.append(raw)
            continue
        try:
            start = int(raw.get('start_ms', raw.get('startMilliseconds', milliseconds(raw.get('startSeconds')))))
            end = raw.get('end_ms')
            length = raw.get('length_ms', raw.get('durationMilliseconds', milliseconds(raw.get('durationSeconds'))))
            end = int(end) if end is not None else start + int(length)
        except (TypeError, ValueError):
            continue
        provided.append(Chapter(start, end, str(raw.get('title') or f'Chapter {len(provided) + 1}')))
    provided = _clean_markers(provided)
    sources_named = all(source.probe.payload.get('chapters') and all(str(chapter.get('tags', {}).get('title', '')).strip()
                        for chapter in source.probe.payload['chapters']) for source in sources)
    if provided and (not durations_known or abs(provided[-1].end_ms - offset) <= 15000) and (
            len(provided) > len(markers) or (not sources_named and len(provided) >= len(markers))):
        usable = _clean_markers(provided, offset if durations_known else 0)
        if usable:
            return usable
    return _clean_markers(markers)


def _tagged_identifier(tags):
    for key in ('asin', 'audible_asin', 'audibleasin'):
        identifier = (tags.get(key) or tags.get('com.apple.itunes:' + key) or '').strip()
        if re.fullmatch(r'[A-Za-z0-9]{10}', identifier):
            return identifier.upper()
    return None


def _repair_markers(sources, repair):
    if not sources or any(_is_edited(source.probe.tags) for source in sources):
        raise MediaError('Chapter repair needs the complete audiobook. Open the original or an unabridged copy before repairing it.')
    asin = repair.get('asin')
    if asin and any(tag != asin.upper() for source in sources if (tag := _tagged_identifier(source.probe.tags))):
        raise MediaError('The chapter data belongs to a different Audible edition.')
    runtime = repair.get('runtimeMilliseconds')
    chapters = repair.get('chapters')
    max_runtime = 30 * 24 * 60 * 60 * 1000
    invalid = 'The chapter data has invalid or overlapping time ranges.'
    if type(runtime) is not int or not 0 < runtime <= max_runtime or not isinstance(chapters, list) or not chapters:
        raise MediaError(invalid)
    lengths = [source.probe.duration_ms for source in sources]
    duration = sum(lengths)
    if not all(0 < length <= max_runtime for length in lengths) or duration > max_runtime:
        raise MediaError('DownAudible couldn’t determine the duration of the source audio.')
    tolerance = min(2000, max(250, runtime // 1000))
    if abs(runtime - duration) > tolerance:
        raise MediaError('The chapter runtime does not match this audio. Choose chapter data for this edition and make sure every part is present.')
    markers, prior_end = [], 0
    for raw in chapters:
        if not isinstance(raw, Mapping):
            raise MediaError(invalid)
        start, length, title = raw.get('startMilliseconds'), raw.get('durationMilliseconds'), raw.get('title')
        if type(start) is not int or type(length) is not int or not isinstance(title, str) or not title.strip():
            raise MediaError(invalid)
        end = start + length
        if not prior_end <= start < min(end, duration) or end > runtime:
            raise MediaError(invalid)
        source_end = duration if end == runtime else min(end, duration)
        markers.append(Chapter(start, source_end, title))
        prior_end = end
    return markers


def _section_layout(sources: Sequence[PreparedInput], chapters: Sequence[Chapter]) -> list[BookSection]:
    sections = []
    offset = 0
    marker_index = 0
    clipped_ends = [min(chapter.end_ms, chapters[index + 1].start_ms) if index + 1 < len(chapters)
                    else chapter.end_ms for index, chapter in enumerate(chapters)]
    for index, source in enumerate(sources):
        if source.probe.duration_ms <= 0:
            raise MediaError('DownAudible could not determine the source audio duration.')
        part_end = offset + source.probe.duration_ms
        position = offset
        while position < part_end:
            while marker_index < len(chapters) and clipped_ends[marker_index] <= position:
                marker_index += 1
            marker = chapters[marker_index] if marker_index < len(chapters) else None
            chapter_index = None
            if marker is not None and marker.start_ms <= position:
                end = min(part_end, clipped_ends[marker_index])
                title = marker.title
                chapter_index = marker_index
            else:
                end = min(part_end, marker.start_ms) if marker else part_end
                if position == offset and end == part_end:
                    title = f'Part {index + 1}'
                elif position == offset:
                    title = 'Opening audio'
                else:
                    title = 'Closing audio' if end == part_end else 'Audio between chapters'
            sections.append(BookSection(len(sections), index, title, position - offset, end - offset, chapter_index))
            position = end
        offset = part_end
    return sections


def _select_sections(layout: Sequence[BookSection], excluded: set[int]):
    if not excluded.issubset(section.id for section in layout):
        raise MediaError('The source audio or chapters have changed. Open Edit Book again.')
    segments = []
    markers = []
    position = 0
    prior_chapter = None
    for section in layout:
        if section.id in excluded:
            continue
        source = section.source_index
        duration = section.end_ms - section.start_ms
        if segments and (segments[-1][0], segments[-1][2]) == (source, section.start_ms):
            segments[-1] = (source, segments[-1][1], section.end_ms)
        else:
            segments.append((source, section.start_ms, section.end_ms))
        if section.chapter_index is not None:
            if prior_chapter == section.chapter_index:
                markers[-1] = replace(markers[-1], end_ms=position + duration)
            else:
                markers.append(Chapter(position, position + duration, section.title))
        prior_chapter = section.chapter_index
        position += duration
    if not segments:
        raise MediaError('Keep at least one section to convert the book.')
    return segments, markers


_NATIVE_TAGS = frozenset({
    'title', 'artist', 'album_artist', 'composer', 'album', 'date', 'encoding_tool', 'comment', 'genre', 'copyright',
    'grouping', 'lyrics', 'description', 'synopsis', 'show', 'episode_id', 'network', 'keywords', 'episode_sort',
    'season_number', 'media_type', 'hd_video', 'gapless_playback', 'compilation', 'track', 'disc', 'tempo',
    'location', 'creation_time',
})
_CONTAINER_TAGS = frozenset({'major_brand', 'minor_version', 'compatible_brands', 'downaudible_edited',
                             'com.apple.itunes:downaudible_edited'})


def _is_edited(tags: Mapping) -> bool:
    return tags.get('downaudible_edited') == '1' or tags.get('com.apple.itunes:downaudible_edited') == '1'


def _tag_key(key: str, profile: ConversionOptions) -> str:
    if key.lower() in _NATIVE_TAGS:
        return key.lower()
    if key.lower().startswith('com.apple.itunes:'):
        key = key.split(':', 1)[1]
    return key if profile.format == 'mp3' else f'com.apple.iTunes:{key}'


def _tags(sources: Sequence[PreparedInput], metadata: Mapping, profile: ConversionOptions) -> dict[str, str]:
    tags = {}
    for source in sources:
        raw = source.probe.payload.get('format', {}).get('tags', {})
        for key, value in raw.items():
            if value and key.lower() not in _CONTAINER_TAGS:
                tags.setdefault(_tag_key(key, profile), str(value))
    first = sources[0]
    tags['title'] = metadata.get('title') or tags.get('title') or first.probe.tags.get('parent_title') or first.source.path.stem
    tags.setdefault('album', tags['title'])
    authors = _joined(metadata.get('authors')) or metadata.get('author')
    narrators = _joined(metadata.get('narrators')) or metadata.get('narrator')
    if authors:
        tags['artist'] = tags['album_artist'] = authors
    elif artist := tags.get('artist') or first.probe.tags.get('author'):
        tags['artist'] = artist
        tags.setdefault('album_artist', artist)
    if narrators:
        tags.setdefault('composer', narrators)
        tags[_tag_key('NARRATOR', profile)] = narrators
    if description := metadata.get('description'):
        tags['description'] = tags['synopsis'] = description
    if release := metadata.get('releaseDate') or metadata.get('date') or tags.get('date') or first.probe.tags.get('pubdate'):
        tags['date'] = release
    tags.setdefault('genre', _joined(metadata.get('genres')) or 'Audiobook')
    if profile.format == 'm4b':
        tags['media_type'] = '2'
    else:
        tags.pop('media_type', None)
    for key, name in [('SUBTITLE', 'subtitle'), ('PUBLISHER', 'publisher'), ('ASIN', 'asin'),
                       ('SERIES', 'series'), ('SERIES-PART', 'seriesSequence'), ('LANGUAGE', 'language'), ('GENRES', 'genres')]:
        if value := _joined(metadata.get(name)):
            tags[_tag_key(key, profile)] = value
    return tags


def _joined(values) -> str:
    if isinstance(values, (tuple, list)):
        return ', '.join(str(value) for value in values if value)
    return str(values) if values is not None else ''


def _split_tags(tags, spec: OutputSpec, count: int):
    tags = tags.copy()
    if tags and spec.chapter_number is not None:
        title = (spec.chapter_title or '').strip()
        label = f'Chapter {spec.chapter_number}'
        tags['title'] = title if re.match(r'^chapter\s+\d+\b', title, re.IGNORECASE) else f'{label} - {title}' if title else label
        tags['track'] = f'{spec.chapter_number}/{count}'
    return tags


def _metadata_escape(value: str) -> str:
    value = str(value).replace('\0', '').replace('\r\n', '\n').replace('\r', ' ')
    return re.sub(r'([\\=;#\n])', r'\\\1', value)


def _write_metadata(path: Path, tags: Mapping, markers: Iterable[Chapter]):
    lines = [';FFMETADATA1']
    lines.extend(f'{_metadata_escape(key)}={_metadata_escape(value)}' for key, value in sorted(tags.items()) if value)
    for chapter in markers:
        lines.extend(['[CHAPTER]', 'TIMEBASE=1/1000', f'START={chapter.start_ms}', f'END={chapter.end_ms}',
                      f'title={_metadata_escape(chapter.title)}'])
    path.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
