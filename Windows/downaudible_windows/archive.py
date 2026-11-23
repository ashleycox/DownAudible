from __future__ import annotations

import os
import re
import unicodedata
from collections import Counter, defaultdict
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from stat import S_ISREG

from .archive_ascii import ascii_name
from .media import PROTECTED_FORMATS, LocalAudio, check_cancel
from .state import DEFAULT_FOLDER_TEMPLATE, default_archive

DEFAULT_CHAPTER_TEMPLATE = '{title} - {chapterNumber} - {chapter}'
TOKENS = frozenset({'title', 'subtitle', 'author', 'authors', 'narrator', 'narrators', 'series', 'seriesNumber',
                    'publisher', 'year', 'language', 'asin', 'format', 'chapter', 'chapterNumber', 'partNumber'})
INVALID_CHARACTERS = re.compile(r'[<>:"/\\|?*\x00-\x1f\x7f]')
RESERVED_NAMES = re.compile(r'(?i)^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|(?:COM|LPT)[1-9¹²³])$')
PATTERN_TOKEN = re.compile(r'\{([A-Za-z][A-Za-z0-9]*)\}')
OPTIONAL_SEGMENT = re.compile(r'\{\?([A-Za-z][A-Za-z0-9]*)\|((?:[^{}]|\{[A-Za-z][A-Za-z0-9]*\})+)\}')
FILENAME_ASIN = re.compile(r'(?i)(?<![A-Z0-9])B0[A-Z0-9]{8}(?![A-Z0-9])')
AUDIBLE_SUFFIX = re.compile(r'(?i)_AAXC?(?:_[0-9]+)*$')
WINDOWS_PATH_UNITS = 259
# An archive save creates a sibling filename of the form .<32 hex digits>.partial.
WINDOWS_ARCHIVE_FOLDER_UNITS = WINDOWS_PATH_UNITS - len('/.0123456789abcdef0123456789abcdef.partial')


class ArchiveError(ValueError):
    pass


def _reserved(name: str) -> bool:
    return RESERVED_NAMES.fullmatch(name.partition('.')[0].rstrip(' ')) is not None


def _fit(value: str, limit: int) -> str:
    return value.encode('utf-8', errors='replace')[:limit].decode('utf-8', errors='ignore').rstrip(' .')


def safe_filename(value: str, max_bytes: int = 180) -> str:
    safe = _fit(INVALID_CHARACTERS.sub('-', str(value)).strip().strip('. '), max_bytes) or 'Unknown'
    if _reserved(safe):
        safe = _fit(f'_{safe}', max_bytes)
    return safe


def windows_path_units(value) -> int:
    return len(str(value).encode('utf-16-le', errors='surrogatepass')) // 2


def _folder_names(root, names):
    if os.name != 'nt':
        return names
    budget = WINDOWS_ARCHIVE_FOLDER_UNITS - windows_path_units(root) - len(names)
    lengths = [windows_path_units(name) for name in names]
    if sum(lengths) <= budget:
        return names
    if sum(min(length, 7) for length in lengths) > budget:
        raise ArchiveError('The archive folder path is too long. Choose a shorter destination in Settings > Files.')
    limit = 7
    while sum(min(length, limit + 1) for length in lengths) <= budget:
        limit += 1
    return [safe_filename(name, limit) if length > limit else name for name, length in zip(names, lengths, strict=True)]


def _path_key(path: Path) -> str:
    return unicodedata.normalize('NFC', str(Path(path).absolute())).casefold()


def available_path(directory, stem, extension, *, max_bytes=230, occupied=(), suffix='') -> Path:
    directory = Path(directory).absolute()
    extension = str(extension).lower().lstrip('.')
    if not re.fullmatch(r'[a-z0-9]+', extension):
        raise ArchiveError('The output file needs a valid extension.')
    limit = min(255, max(16, int(max_bytes))) - len(extension) - 1 - len(suffix.encode('utf-8'))
    if limit < 7:
        raise ArchiveError('The filename limit is too short for this output format.')
    if os.name == 'nt':
        limit = min(limit, WINDOWS_PATH_UNITS - windows_path_units(directory) - windows_path_units(f'/{suffix}.{extension}'))
        if limit < 7:
            raise ArchiveError('The output path is too long. Choose a shorter destination.')
    taken = {_path_key(path) for path in occupied}
    if directory.is_dir():
        taken.update(_path_key(entry) for entry in directory.iterdir())
    for number in range(1, 10_001):
        duplicate = '' if number == 1 else f' ({number})'
        if limit - len(duplicate) < 7:
            break
        name = f'{safe_filename(stem, limit - len(duplicate))}{suffix}{duplicate}.{extension}'
        candidate = directory / name
        if _path_key(candidate) not in taken and not os.path.lexists(candidate):
            return candidate
    raise ArchiveError('DownAudible could not find an unused filename in the destination folder.')


def _valid_component(pattern: str) -> bool:
    if not pattern.strip() or pattern.strip() in {'.', '..'} or len(pattern.encode('utf-8')) > 240:
        return False
    if re.search(r'[/\\\x00-\x1f\x7f]', pattern):
        return False
    if any(match[1] not in TOKENS for match in OPTIONAL_SEGMENT.finditer(pattern)):
        return False
    pattern = OPTIONAL_SEGMENT.sub(lambda match: match[2], pattern)
    if any(token not in TOKENS for token in PATTERN_TOKEN.findall(pattern)):
        return False
    remaining = PATTERN_TOKEN.sub('', pattern)
    return '{' not in remaining and '}' not in remaining


def _values(value) -> list[str]:
    if isinstance(value, (tuple, list)):
        return [str(item) for item in value if item]
    return [str(value)] if value else []


def _book_values(book: Mapping | LocalAudio) -> dict[str, str]:
    if isinstance(book, LocalAudio):
        book = {**book.metadata, 'title': book.title, 'author': book.author, 'asin': book.asin}
    authors = _values(book.get('authors'))
    narrators = _values(book.get('narrators'))
    year = book.get('year') or str(book.get('releaseDate') or '')[:4]
    return {
        'title': str(book.get('title') or 'Untitled'),
        'subtitle': str(book.get('subtitle') or ''),
        'author': str(book.get('author') or (authors[0] if authors else '') or 'Unknown Author'),
        'authors': ', '.join(authors) or str(book.get('author') or ''),
        'narrator': str(book.get('narrator') or (narrators[0] if narrators else '')),
        'narrators': ', '.join(narrators) or str(book.get('narrator') or ''),
        'series': str(book.get('series') or ''),
        'seriesNumber': str(book.get('seriesNumber') or book.get('seriesSequence') or ''),
        'publisher': str(book.get('publisher') or ''),
        'year': str(year),
        'language': str(book.get('language') or ''),
        'asin': str(book.get('asin') or 'No ASIN'),
    }


def _render(pattern, values):
    return PATTERN_TOKEN.sub(lambda match: values.get(match[1], ''), pattern)


def _active_segments(pattern, values):
    return OPTIONAL_SEGMENT.sub(lambda match: match[2] if values.get(match[1], '').strip() else '', pattern)


@dataclass(frozen=True)
class ArchiveLayout:
    root: Path
    folder_template: str = DEFAULT_FOLDER_TEMPLATE
    filename_template: str = ''
    chapter_filename_template: str = DEFAULT_CHAPTER_TEMPLATE
    filename_style: str = 'unicode'
    max_filename_bytes: int = 230
    filename_spaces: str = 'keep'
    filename_case: str = 'original'
    ascii_names: bool = False
    keep_aax_filename: bool = False

    def __post_init__(self):
        object.__setattr__(self, 'root', Path(self.root).resolve())
        # Keep the established recipe identity used by saved archive receipts.
        object.__setattr__(self, 'folder_template', self.folder_template.replace('\\', '/'))

    @classmethod
    def from_settings(cls, settings, root=None):
        root = root or settings.get('archive_root') or default_archive()
        return cls(root, **{name: settings[name] for name in cls.__dataclass_fields__ if name != 'root' and name in settings})

    @property
    def is_valid(self) -> bool:
        pieces = self.folder_template.split('/')
        return (len(pieces) <= 12 and all(_valid_component(piece) for piece in pieces)
                and (not self.filename_template or _valid_component(self.filename_template))
                and (not self.chapter_filename_template or _valid_component(self.chapter_filename_template)))

    def _apply(self, text: str) -> str:
        if self.ascii_names:
            text = ascii_name(text)
        if self.filename_spaces in {'hyphen', 'underscore'}:
            text = ('-' if self.filename_spaces == 'hyphen' else '_').join(text.split())
        if self.filename_case == 'lowercase':
            text = text.lower()
        if self.filename_case == 'uppercase':
            text = text.upper()
        return text

    def _fallback(self, values: Mapping) -> str:
        title, asin = values['title'], values['asin']
        if self.filename_style in {'ascii', 'asinASCII'}:
            title = ascii_name(title)
        if asin != 'No ASIN':
            if self.filename_style == 'asinOnly':
                return asin
            if self.filename_style in {'asinUnicode', 'asinASCII'}:
                return f'{asin} - {title}'
        return title

    @staticmethod
    def _substitutions(book, format, chapter_number, chapter_title, part_number):
        return {**_book_values(book), 'format': str(format), 'chapter': str(chapter_title or ''),
                'chapterNumber': f'{chapter_number:02d}' if chapter_number is not None else '',
                'partNumber': f'{part_number:02d}' if part_number is not None else ''}

    def _directory(self, values):
        if not self.is_valid:
            raise ArchiveError('Check the folder and filename templates. Use one backslash between folder names.')
        root = self.root
        directory = root
        names = []
        for component in self.folder_template.split('/'):
            active = _active_segments(component, values)
            if active.strip():
                names.append(safe_filename(self._apply(_render(active, values))))
        for name in _folder_names(root, names):
            candidate = directory / name
            if candidate.is_symlink() or candidate.is_junction():
                raise ArchiveError('A symbolic link or junction inside the archive points to another location.')
            candidate = candidate.resolve()
            if not candidate.is_relative_to(root):
                raise ArchiveError('The output path is outside the archive destination.')
            directory = candidate
        return directory

    def directory(self, book, format, chapter_number=None, chapter_title=None, part_number=None) -> Path:
        return self._directory(self._substitutions(book, format, chapter_number, chapter_title, part_number))

    def _keep_original(self, original_name) -> bool:
        return (self.keep_aax_filename and isinstance(original_name, str) and original_name.lower().endswith('.aax')
                and not original_name.startswith('.') and len(original_name.encode('utf-8')) <= self.max_filename_bytes
                and not INVALID_CHARACTERS.search(original_name) and bool(original_name[:-4].strip(' .'))
                and not _reserved(original_name))

    def destination(self, book, format, chapter_number=None, chapter_title=None, part_number=None,
                    original_name=None, occupied=(), edited=False, *, folder_format=None, name_suffix='') -> Path:
        values = self._substitutions(book, format, chapter_number, chapter_title, part_number)
        directory = self._directory(values if folder_format is None else dict(values, format=folder_format))
        keep_original = format == 'aax' and self._keep_original(original_name)
        original_fits = os.name != 'nt' or not keep_original or windows_path_units(directory / original_name) <= WINDOWS_PATH_UNITS
        if keep_original and original_fits:
            stem = original_name[:-4]
        else:
            template = self.filename_template if chapter_number is None else self.chapter_filename_template
            fallback = self._fallback(values)
            active = _active_segments(template, values)
            stem = _render(active, values) if template else fallback
            if not template and chapter_number is not None:
                stem += f' - {chapter_number:02d}'
                if chapter_title:
                    stem += f' - {chapter_title}'
            if part_number is not None and '{partNumber}' not in active:
                stem += f' - Part {part_number}'
            stem = self._apply(stem).strip() or self._apply(fallback)
        return available_path(directory, stem, format, max_bytes=self.max_filename_bytes,
                              occupied=occupied, suffix=' - Edited' if edited else name_suffix)


def _name_key(value) -> str:
    folded = unicodedata.normalize('NFKD', str(value or '')).casefold()
    characters = (character if character.isalnum() else ' ' for character in folded
                  if not unicodedata.combining(character) and character not in "'’")
    return ' '.join(''.join(characters).split())


def _title_key(value) -> str:
    neutral = re.sub(r'\s*(?:\(unabridged\)|\[unabridged\]|-\s+unabridged)\s*$', '', str(value or ''), flags=re.IGNORECASE)
    return _name_key(neutral)


@dataclass(frozen=True)
class Candidate:
    audio: LocalAudio
    titles: frozenset[str]
    authors: frozenset[str]
    filename_key: str
    compact_filename: str
    folder_title: str
    folder_author: str
    in_format_folder: bool

    @classmethod
    def from_audio(cls, audio: LocalAudio):
        filename = audio.path.stem
        file_key = _title_key(FILENAME_ASIN.sub('', AUDIBLE_SUFFIX.sub('', filename)))
        titles = frozenset(map(_title_key, (audio.title, audio.collection, file_key))) - {''}
        authors = frozenset(map(_name_key, (audio.author, audio.collection_author))) - {''}
        return cls(audio, titles, authors, file_key, file_key.replace(' ', '') if AUDIBLE_SUFFIX.search(filename) else '',
                   _title_key(audio.path.parent.name), _name_key(audio.path.parent.parent.name),
                   audio.path.parent.parent.parent.name.lower() == audio.format)

    def duration_matches(self, expected) -> bool:
        actual = self.audio.duration_seconds
        return not (expected and actual) or abs(actual - expected) <= min(120, max(5, expected * 0.03))

    def evidence(self, titles, authors, filenames, compact_titles, duration) -> int:
        if not self.duration_matches(duration):
            return 0
        title_matches = bool(self.titles & titles) or self.compact_filename in compact_titles
        author_matches = bool(self.authors & authors)
        in_author_folder = self.folder_author in authors
        folder_matches = in_author_folder and self.folder_title in titles
        if authors and self.authors and not author_matches:
            return int(self.in_format_folder and folder_matches and title_matches)
        if title_matches:
            return 3 if author_matches or in_author_folder else 2
        if self.filename_key in filenames:
            return 3
        if folder_matches and (self.audio.format in PROTECTED_FORMATS or bool(self.audio.duration_seconds and duration)):
            return 1
        return 0


def match_books(books: Iterable[Mapping], audio: Iterable[LocalAudio], *, cancel=None) -> dict[str, list[Path]]:
    by_id = defaultdict(list)
    by_name = defaultdict(list)
    by_compact = defaultdict(list)
    for item in audio:
        check_cancel(cancel)
        if item.is_segment:
            continue
        candidate = Candidate.from_audio(item)
        if item.asin:
            by_id[item.asin.upper()].append(candidate)
        else:
            for title in (candidate.titles | {candidate.folder_title}) - {''}:
                by_name[title].append(candidate)
            if candidate.compact_filename:
                by_compact[candidate.compact_filename].append(candidate)

    claims = Counter()
    selected = {}
    for book in books:
        check_cancel(cancel)
        asin = str(book.get('asin') or '')
        if not asin:
            continue
        title = str(book.get('title') or '')
        subtitle = str(book.get('subtitle') or '')
        titles = {_title_key(title), _title_key(f'{title}: {subtitle}')} - {''}
        names = _values(book.get('authors'))
        authors = {_name_key(name) for name in [*names, ', '.join(names)]} - {''}
        compact_titles = {title.replace(' ', '') for title in titles}
        filenames = {name for author in authors for title in titles for name in (f'{author} {title}', f'{title} {author}')}
        duration = book.get('durationSeconds')
        duration = duration if isinstance(duration, (int, float)) and duration > 0 else None
        options = {}
        for candidate in (candidate for key in titles | filenames for candidate in by_name[key]):
            options[candidate.audio.path] = candidate
        for candidate in (candidate for key in compact_titles for candidate in by_compact[key]):
            options[candidate.audio.path] = candidate
        by_title = [(score, candidate.audio) for candidate in options.values()
                    if (score := candidate.evidence(titles, authors, filenames, compact_titles, duration))]
        identifiers = by_id.get(asin.upper())
        identified = [(4, candidate.audio) for candidate in identifiers or () if candidate.duration_matches(duration)]
        matches = identified if identifiers else by_title
        claims.update({audio.path for _, audio in [*by_title, *identified]})
        if matches:
            strongest = max(score for score, _ in matches)
            preferred = [audio for score, audio in matches if score == strongest]
            originals = [audio for audio in preferred if audio.format in PROTECTED_FORMATS]
            if len(preferred) == 1:
                selected[asin] = [preferred[0].path]
            elif len(originals) == 1:
                selected[asin] = [originals[0].path]
    return {asin: paths for asin, paths in selected.items() if claims[paths[0]] == 1}


@dataclass(frozen=True)
class ArchiveIssue:
    book: Mapping
    kind: str
    files: tuple[Path, ...] = ()

    @property
    def can_repair(self) -> bool:
        return self.book.get('isDownloadable', True)


def recorded_file(path, sizes):
    try:
        entry = path.stat()
        size = sizes.get(str(path))
        return S_ISREG(entry.st_mode) and (size is None or entry.st_size == size)
    except OSError:
        return False


@dataclass(frozen=True)
class ArchiveCopy:
    files: tuple[Path, ...]
    sizes: Mapping[str, int]
    original: bool

    def missing_files(self) -> tuple[Path, ...]:
        return tuple(path for path in self.files if not recorded_file(path, self.sizes))

    def is_complete(self) -> bool:
        return bool(self.files) and all(recorded_file(path, self.sizes) for path in self.files)


def _groups(values) -> list[tuple[Path, ...]]:
    if not values:
        return []
    if isinstance(values, (Path, str)):
        return [(Path(values),)]
    if isinstance(values[0], (Path, str)):
        return [tuple(map(Path, values))]
    return [tuple(map(Path, group)) for group in values if group]


def verify_archive(books: Sequence[Mapping], matches: Mapping, tools, *, sizes=None,
                   has_partial=None, cancel=None, progress=None) -> list[ArchiveIssue]:
    issues = []
    checked = {}
    size_by_path = {Path(path): size for path, size in (sizes or {}).items()}
    for index, book in enumerate(books, 1):
        check_cancel(cancel)
        groups = _groups(matches.get(book.get('asin')))
        problems = []
        complete = False
        for group in groups:
            copy_problems = []
            for path in group:
                check_cancel(cancel)
                if path not in checked:
                    checked[path] = tools.audio_issue(path, size_by_path.get(path), cancel=cancel)
                if checked[path]:
                    copy_problems.append((checked[path], path))
            if not copy_problems:
                complete = True
                break
            problems.extend(copy_problems)
        if not complete:
            staged = bool(has_partial and has_partial(book))
            failures = {kind for kind, _ in problems}
            if 'unreadable' in failures:
                kind = 'unreadable'
            elif staged or 'incomplete' in failures or any(len(group) > 1 and any(not checked[path] for path in group) for group in groups):
                kind = 'incomplete'
            else:
                kind = 'missing'
            if book.get('isDownloadable', True) or groups or staged:
                issues.append(ArchiveIssue(book, kind, tuple(dict.fromkeys(path for _, path in problems))))
        if progress:
            progress(index / len(books))
    return issues
