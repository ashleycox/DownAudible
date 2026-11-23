import json
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave
import zlib
from pathlib import Path
from threading import Event
from unittest.mock import Mock, patch

from downaudible_windows.archive import (
    ArchiveError,
    ArchiveLayout,
    match_books,
    verify_archive,
)
from downaudible_windows.media import (
    ActivationRequired,
    AudioProbe,
    Chapter,
    LocalAudio,
    MediaCancelled,
    MediaError,
    MediaInput,
    MediaTools,
    read_voucher,
    source_revision,
)
from downaudible_windows.media_recycle import recycle_source

FFMPEG = os.environ.get('DOWNAUDIBLE_FFMPEG') or shutil.which('ffmpeg')
FFPROBE = os.environ.get('DOWNAUDIBLE_FFPROBE') or shutil.which('ffprobe')
FIXTURE_FFMPEG = shutil.which('ffmpeg') or FFMPEG


def synthetic_aa_book(codec: bytes, samples: bytes) -> bytes:
    # The seed and header words select an all-zero fixture key.
    attributes = {
        b'codec': codec,
        b'HeaderSeed': b'0',
        b'HeaderKey': b'889652015 1223818326 3852425851 3488566897',
        b'title': b'Synthetic Legacy Book',
    }
    dictionary = struct.pack('>I', len(attributes)) + b''.join(
        struct.pack('>BII', 0, len(name), len(value)) + name + value
        for name, value in attributes.items()
    )
    chapters = (struct.pack('>II', len(samples), 0) + samples) * 2
    audio_offset = 16 + 24 + 24 + len(dictionary)
    header = struct.pack('>4I', audio_offset + len(chapters), 1469084982, 2, 0)
    contents = struct.pack('>6I', 0, 0, 0, 1, audio_offset, len(chapters))
    return header + contents + bytes(24) + dictionary + chapters


def synthetic_sipr_book() -> bytes:
    # 55 blank SIPR frames per chapter occupy 1,045 bytes (990 ms).
    encrypted_zeros = bytes.fromhex('ed285da1455b33c1')
    return synthetic_aa_book(b'acelp85', encrypted_zeros * 130 + bytes(5))


def synthetic_mp3_aa_book() -> bytes:
    # Empty MPEG-2 Layer III mono frames, 32 kbps at 22.05 kHz.
    samples = (bytes.fromhex('fff340c4') + bytes(100)) * 117

    def encrypt(block):
        left, right = struct.unpack('>II', block)
        step = 0
        mask = 0xffffffff
        for _ in range(8):
            step = (step + 0x9e3779b9) & mask
            left = (left + ((right << 4) ^ (right + step) ^ (right >> 5))) & mask
            right = (right + ((left << 4) ^ (left + step) ^ (left >> 5))) & mask
        return struct.pack('>II', left, right)

    def encrypt_packet(packet):
        # Each AA packet ends with at most seven unencrypted bytes.
        full_blocks = len(packet) // 8 * 8
        blocks = (encrypt(packet[index:index + 8]) for index in range(0, full_blocks, 8))
        return b''.join(blocks) + packet[full_blocks:]

    return synthetic_aa_book(b'mp332', b''.join(
        encrypt_packet(samples[index:index + 3982]) for index in range(0, len(samples), 3982)
    ))


class ArchiveTests(unittest.TestCase):
    def test_ascii_names_keep_accent_folding_without_system_icu(self):
        with tempfile.TemporaryDirectory() as folder, patch('downaudible_windows.archive_ascii._windows_icu', return_value=None):
            layout = ArchiveLayout(folder, ascii_names=True)
            path = layout.destination({'title': 'Écho', 'authors': ['Renée']}, 'm4b')
            self.assertEqual(path.relative_to(layout.root), Path('m4b/Renee/Echo/Echo.m4b'))

    @unittest.skipUnless(os.name == 'nt', 'Windows system ICU is exercised on Windows')
    def test_ascii_archive_names_transliterate_non_latin_sources(self):
        samples = {'Москва': 'Moskva', 'Αθήνα': 'Athena', '北京': 'bei jing', 'العربية': 'alrbyt',
                   'キャンパス': 'kyanpasu', 'Привет 🌍': 'Privet', 'Écho': 'Echo'}
        with tempfile.TemporaryDirectory() as folder:
            layout = ArchiveLayout(folder, ascii_names=True)
            for title, expected in samples.items():
                with self.subTest(title=title):
                    path = layout.destination({'title': title, 'authors': ['Renée']}, 'm4b')
                    self.assertEqual(path.relative_to(layout.root), Path('m4b', 'Renee', expected, f'{expected}.m4b'))

    def test_windows_names_and_duplicate_files(self):
        with tempfile.TemporaryDirectory() as folder:
            layout = ArchiveLayout(folder, filename_template='{title}', filename_spaces='underscore', max_filename_bytes=40)
            book = {'title': 'My Book: A Note?', 'authors': ['CON'], 'asin': 'B000000001'}
            path = layout.destination(book, 'm4b')
            self.assertEqual(path.relative_to(layout.root), Path('m4b/_CON/My_Book-_A_Note-/My_Book-_A_Note-.m4b'))
            path.parent.mkdir(parents=True)
            path.with_name(path.name.upper()).touch()
            self.assertEqual(layout.destination(book, 'm4b').stem, 'My_Book-_A_Note- (2)')
            name = layout.destination({'title': 'é' * 100}, 'm4b').name
            self.assertLessEqual(len(name.encode('utf-8')), 40)
            for reserved in ('NUL', 'LPT¹', 'com6.txt', 'CONOUT$'):
                self.assertTrue(layout.destination({'title': reserved}, 'm4b').stem.startswith('_'))
            long_book = {'title': 'Long ' * 40}
            edited = layout.destination(long_book, 'm4b', edited=True)
            self.assertTrue(edited.stem.endswith(' - Edited'))
            duplicate = layout.destination(long_book, 'm4b', occupied=[edited], edited=True)
            self.assertTrue(duplicate.stem.endswith(' - Edited (2)'))
            self.assertLessEqual(len(duplicate.name.encode('utf-8')), 40)

    def test_templates_cannot_escape_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'Audio'
            root.mkdir()
            outside = Path(folder) / 'Outside'
            outside.mkdir()
            try:
                (root / 'm4b').symlink_to(outside, target_is_directory=True)
            except OSError:
                pass
            else:
                with self.assertRaises(ArchiveError):
                    ArchiveLayout(root).destination({'title': 'Book'}, 'm4b')
            with self.assertRaises(ArchiveError):
                ArchiveLayout(root, folder_template='../{author}').destination({'title': 'Book'}, 'm4b')
            with self.assertRaises(ArchiveError):
                ArchiveLayout(root, filename_template='{unknown}').destination({'title': 'Book'}, 'm4b')

    def test_matching_ignores_segments_and_ambiguous_claims(self):
        book = {'asin': 'B000000001', 'title': 'Écho', 'authors': ['Author'], 'durationSeconds': 200}
        copy = LocalAudio(Path('/archive/Echo.m4b'), 'm4b', None, 'Echo', 'Author', 200)
        segment = LocalAudio(Path('/archive/Chapter.m4b'), 'm4b', 'B000000001', 'Echo', 'Author', 200, is_segment=True)
        self.assertEqual(match_books([book], [copy, segment]), {'B000000001': [copy.path]})
        self.assertEqual(match_books([book, dict(book, asin='B000000002')], [copy, segment]), {})

    def test_matching_recognizes_combined_authors_in_tags(self):
        book = {'asin': 'B000000001', 'title': 'Family Story', 'authors': ['Ada Brown', 'Fred Jones']}
        audio = LocalAudio(Path('/archive/Story.m4b'), 'm4b', None, 'Family Story', 'Ada Brown, Fred Jones', None)
        self.assertEqual(match_books([book], [audio]), {'B000000001': [audio.path]})

    def test_verification_requires_a_whole_group(self):
        class Tools:
            @staticmethod
            def audio_issue(path, size=None, cancel=None):
                return 'missing' if path.name == 'missing.m4b' else None

        books = [{'asin': 'BOOK', 'title': 'Book', 'isDownloadable': True}]
        groups = [[Path('good.m4b'), Path('missing.m4b')]]
        (issue,) = verify_archive(books, {'BOOK': groups}, Tools())
        self.assertEqual(issue.kind, 'incomplete')
        self.assertTrue(issue.can_repair)
        self.assertEqual(verify_archive(books, {'BOOK': [*groups, [Path('whole.aax')]]}, Tools()), [])

    def test_protected_option_values_stay_out_of_command_line(self):
        with tempfile.TemporaryDirectory() as folder:
            workspace = Path(folder)
            source = workspace / 'Protected fixture.aax'
            source.touch()
            tools = MediaTools(Path('ffmpeg'), Path('ffprobe'))
            code = '1234abcd'

            def probe(_path, *, cancel, arguments):
                self.assertNotIn(code, ' '.join(arguments))
                path = Path(arguments[arguments.index('-/activation_bytes') + 1])
                self.assertEqual(path.parent, workspace)
                self.assertEqual(path.read_text(encoding='ascii'), code)
                return AudioProbe({'streams': [{'codec_type': 'audio'}]})

            with patch.object(tools, 'probe', side_effect=probe), patch('downaudible_windows.media._run', return_value=(0, b'', b'')):
                tools._prepare_input(MediaInput(source, activation_bytes=code), 0, workspace, None)

    def test_aax_refresh_is_limited_to_activation_errors(self):
        with tempfile.TemporaryDirectory() as folder:
            workspace = Path(folder)
            path = workspace / 'Synthetic AAX.aax'
            path.touch()
            source = MediaInput(path, '00000000')
            tools = MediaTools(Path('ffmpeg'), Path('ffprobe'))
            refresh = Mock(return_value='11223344')
            probe = AudioProbe({'streams': [{'codec_type': 'audio'}]})
            with patch.object(tools, 'probe', return_value=probe), patch('downaudible_windows.media._run') as process:
                process.side_effect = [(1, b'', b'[aax] mismatch in checksums!'), (0, b'', b'')]
                (prepared,) = tools._prepare([source], workspace, '', refresh, None)
                self.assertEqual(prepared.source.activation_bytes, '11223344')
                refresh.assert_called_once_with()
                self.assertEqual(process.call_count, 2)

                refresh.reset_mock()
                process.side_effect = None
                process.return_value = (1, b'', b'AAC sample is missing; private synthetic input')
                with self.assertRaises(MediaError) as caught:
                    tools._prepare([source], workspace, '', refresh, None)
                self.assertNotIsInstance(caught.exception, ActivationRequired)
                self.assertNotIn('private synthetic input', str(caught.exception))
                refresh.assert_not_called()

    def test_legacy_audible_cli_voucher_beside_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            audio = Path(folder) / 'Book.aaxc'
            voucher = audio.with_suffix('.voucher')
            self.assertIsNone(read_voucher(audio))
            key, iv = '01' * 16, 'ab' * 16
            voucher.write_text(json.dumps({'content_license': {'license_response': {'key': key, 'iv': iv}}}),
                               encoding='utf-8-sig')
            self.assertEqual(read_voucher(audio), (key, iv))
            voucher.write_text(json.dumps({'contentKey': key, 'contentIV': 'wrong length'}), encoding='utf-8')
            self.assertIsNone(read_voucher(audio))

    def test_recycle_leaves_changed_source_in_place(self):
        with tempfile.TemporaryDirectory() as folder:
            original = Path(folder) / 'synthetic-source.txt'
            original.write_bytes(b'original')
            revision = original.stat()
            original.write_bytes(b'someone replaced the source')
            with patch('downaudible_windows.media_recycle._recycle') as operation:
                self.assertFalse(recycle_source(original, revision))
            operation.assert_not_called()
            self.assertEqual(original.read_bytes(), b'someone replaced the source')


@unittest.skipUnless(FFMPEG and FFPROBE, 'FFmpeg and ffprobe are required for synthetic media checks')
class MediaTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.tools = MediaTools(FFMPEG, FFPROBE)
        self.source = self.root / 'Sample Müsic.m4b'
        wav = self.root / 'fixture.wav'
        with wave.open(str(wav), 'wb') as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(22050)
            stream.writeframes(b'\0\0' * 22050 * 4)
        metadata = self.root / 'fixture.metadata'
        metadata.write_text(';FFMETADATA1\ntitle=Demo Book\nartist=Demo Author\n'
                            '[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Opening Credits\n'
                            '[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=4000\ntitle=The Garden\n', encoding='utf-8')
        subprocess.run([FIXTURE_FFMPEG, '-v', 'error', '-nostdin', '-i', str(wav), '-f', 'ffmetadata', '-i', str(metadata),
                        '-map', '0:a', '-map_metadata', '1', '-map_chapters', '1', '-c:a', 'aac', '-f', 'ipod',
                        str(self.source)], check=True, capture_output=True)

    def test_convert_audio_tags_chapters_and_mp3_settings(self):
        progress = []
        output, = self.tools.convert(self.source, self.root / 'Output', progress=progress.append,
                                    metadata={'title': 'Edited Title', 'authors': ['Another Author']})
        probe = self.tools.probe(output)
        self.assertEqual(output.name, 'Edited Title.m4b')
        self.assertEqual(probe.tags['title'], 'Edited Title')
        self.assertEqual(probe.tags['artist'], 'Another Author')
        self.assertEqual([chapter.title for chapter in probe.chapters(1)], ['Opening Credits', 'The Garden'])
        self.assertEqual(progress[-1], 1)
        self.assertIsNone(self.tools.audio_issue(output))
        self.assertEqual(self.tools.audio_issue(output, output.stat().st_size + 1), 'incomplete')
        output, = self.tools.convert(self.source, self.root / 'Output',
                                    {'format': 'mp3', 'channels': 2, 'sample_rate': 44100, 'mp3_bitrate_mode': 'variable'})
        self.assertEqual(self.tools.probe(output).audio['codec_name'], 'mp3')
        self.assertEqual(self.tools.probe(output).audio['sample_rate'], '44100')

    def test_split_and_edit_sections_without_modifying_source(self):
        original = self.source.stat()
        outputs = self.tools.convert(self.source, self.root / 'Split', {'chapter_mode': 'separate', 'copy_chapter_audio': True})
        self.assertEqual(len(outputs), 2)
        first, second = [self.tools.probe(path) for path in outputs]
        self.assertEqual(first.tags['track'], '1/2')
        self.assertEqual(second.tags['title'], 'Chapter 2 - The Garden')
        self.assertLess(abs(second.duration_ms - 3000), 75)
        sections = self.tools.sections(self.source)
        self.assertEqual([section.title for section in sections], ['Opening Credits', 'The Garden'])
        edited, = self.tools.convert(self.source, self.root / 'Edited', excluded_sections=[0], expected_sections=sections)
        self.assertIn(' - Edited', edited.stem)
        output = self.tools.probe(edited)
        self.assertEqual([chapter.title for chapter in output.chapters(1)], ['The Garden'])
        self.assertLess(abs(output.duration_ms - 3000), 75)
        self.assertEqual(self.source.stat().st_mtime_ns, original.st_mtime_ns)

    def test_chapter_repair_overrides_named_markers_and_preserves_complete_audio(self):
        original = self.source.read_bytes()
        markers = [
            dict(startMilliseconds=0, durationMilliseconds=250, title='Audible Intro'),
            dict(startMilliseconds=250, durationMilliseconds=3250, title='Rebuilt Chapter'),
            dict(startMilliseconds=3500, durationMilliseconds=475, title='Audible Outro'),
        ]
        repair = {"runtimeMilliseconds": 3975, "chapters": markers}
        sections = self.tools.sections(self.source, chapter_repair=repair)
        self.assertEqual([section.title for section in sections], ['Audible Intro', 'Rebuilt Chapter', 'Audible Outro'])
        repaired, = self.tools.convert(
            self.source, self.root / 'Repaired', {'embed_chapters': False}, chapter_repair=repair, expected_sections=sections
        )
        self.assertEqual(repaired.stem, 'Demo Book - Chapters Repaired')
        probe = self.tools.probe(repaired)
        self.assertAlmostEqual(probe.duration_ms, self.tools.probe(self.source).duration_ms, delta=25)
        self.assertEqual([(chapter.start_ms, chapter.title) for chapter in probe.chapters(1)],
                         [(0, 'Audible Intro'), (250, 'Rebuilt Chapter'), (3500, 'Audible Outro')])
        self.assertEqual(self.source.read_bytes(), original)
        with self.assertRaisesRegex(MediaError, 'runtime does not match'):
            self.tools.sections(self.source, chapter_repair={**repair, 'runtimeMilliseconds': 5000})
        altered = [{**markers[0], 'title': 'Different Chapter'}, *markers[1:]]
        with self.assertRaisesRegex(MediaError, 'chapters have changed'):
            self.tools.convert(self.source, self.root / 'Bad', chapter_repair={**repair, 'chapters': altered},
                               expected_sections=sections)

    @unittest.skipUnless(os.environ.get('DOWNAUDIBLE_FFMPEG') and os.environ.get('DOWNAUDIBLE_FFPROBE'),
                         'The pinned, patched DownAudible tools are required for legacy AA clock checks')
    def test_legacy_aa_sipr_clock_for_whole_split_and_edited_outputs(self):
        source = self.root / 'Synthetic SIPR Book.aa'
        fixture = synthetic_sipr_book()
        source.write_bytes(fixture)
        probe = self.tools.probe(source)
        self.assertEqual((probe.audio['codec_name'], probe.audio['sample_rate'], probe.duration_ms),
                         ('sipr', '8000', 1980))
        chapters = [Chapter(0, 990, 'Chapter 1'), Chapter(990, 1980, 'Chapter 2')]
        self.assertEqual(probe.chapters(1), chapters)

        whole, = self.tools.convert(source, self.root / 'Whole')
        probe = self.tools.probe(whole)
        self.assertEqual((probe.audio['codec_name'], probe.audio['sample_rate'], probe.duration_ms),
                         ('aac', '8000', 1980))
        self.assertEqual(probe.chapters(1), chapters)

        split = self.tools.convert(source, self.root / 'Split', {'chapter_mode': 'separate'})
        self.assertEqual([self.tools.probe(path).duration_ms for path in split], [990, 990])

        layout = self.tools.sections(source)
        edited, = self.tools.convert(source, self.root / 'Edited', excluded_sections=[0], expected_sections=layout)
        probe = self.tools.probe(edited)
        self.assertEqual(probe.duration_ms, 990)
        self.assertEqual(probe.chapters(1), [Chapter(0, 990, 'Chapter 2')])
        self.assertEqual(source.read_bytes(), fixture)

    def test_legacy_aa_mp3_splits_and_edits_later_chapters(self):
        source = self.root / 'Synthetic MP3 Book.aa'
        source.write_bytes(synthetic_mp3_aa_book())
        self.assertEqual(self.tools.probe(source).audio['codec_name'], 'mp3')

        with patch.object(self.tools, '_encode', wraps=self.tools._encode) as encode:
            whole, = self.tools.convert(source, self.root / 'Whole', {'format': 'mp3'})
        self.assertIn('libmp3lame', encode.call_args.args[0])
        self.assertAlmostEqual(self.tools.probe(whole).duration_ms, 6084, delta=90)

        split = self.tools.convert(source, self.root / 'Split', {'chapter_mode': 'separate'})
        self.assertEqual(len(split), 2)
        for path in split:
            self.assertAlmostEqual(self.tools.probe(path).duration_ms, 3042, delta=50)

        layout = self.tools.sections(source)
        edited, = self.tools.convert(source, self.root / 'Edited', excluded_sections=[0], expected_sections=layout)
        probe = self.tools.probe(edited)
        self.assertAlmostEqual(probe.duration_ms, 3042, delta=50)
        self.assertEqual(probe.chapters(1), [Chapter(0, 3042, 'Chapter 2')])

    def test_multipart_concat_creates_continuous_chapters(self):
        paths = [self.source, self.source]
        combined, = self.tools.convert(paths, self.root / 'Combined')
        probe = self.tools.probe(combined)
        self.assertLess(abs(probe.duration_ms - 8000), 150)
        self.assertEqual([chapter.start_ms for chapter in probe.chapters(1)], [0, 1000, 4000, 5000])

    def test_whole_book_cover_attachment(self):
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

        cover = self.root / 'Cover art.png'
        cover.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
                          + chunk(b'IDAT', zlib.compress(b'\x00\x00\x80\xff')) + chunk(b'IEND', b''))
        output, = self.tools.convert(self.source, self.root / 'Artwork', artwork=cover)
        self.assertIsNotNone(self.tools.probe(output).artwork)

    def test_book_metadata_supplies_extra_chapters(self):
        chapters = [Chapter(0, 1000, 'Audible 1'), Chapter(1000, 2000, 'Audible 2'), Chapter(2000, 4000, 'Audible 3')]
        output, = self.tools.convert(self.source, self.root / 'Chapters', chapters=chapters)
        self.assertEqual([chapter.title for chapter in self.tools.probe(output).chapters(1)],
                         ['Audible 1', 'Audible 2', 'Audible 3'])

    def test_m4a_book_preserves_audio_and_original_title(self):
        output, = self.tools.convert(self.source, self.root / 'M4A', {'format': 'm4a'})
        self.assertEqual(output.name, 'Demo Book.m4a')
        self.assertEqual(self.tools.probe(output).concat_parameters, self.tools.probe(self.source).concat_parameters)

    def test_preview_renders_only_the_selected_duration(self):
        tools = self.tools
        formats = subprocess.run([str(tools.ffmpeg), '-muxers'], check=True, capture_output=True, text=True).stdout
        if not any(line.split()[1:2] == ['wav'] for line in formats.splitlines()):
            self.skipTest('This FFmpeg build omits the preview WAV muxer')
        sections = tools.sections(self.source)
        missing = self.root / 'Moved away.m4b'
        selected = self.source
        shutil.copy2(selected, missing)
        multipart = tools.sections([missing, selected])
        missing.unlink()
        selected_part = next(section for section in multipart if section.source_index == 1)
        self.assertEqual(selected_part.end_ms - selected_part.start_ms,
                         sections[0].end_ms - sections[0].start_ms)
        output = tools.preview([missing, selected], selected_part, self.root / 'Preview.wav')
        with wave.open(str(output), 'rb') as stream:
            self.assertEqual(stream.getnchannels(), 2)
            self.assertEqual(stream.getframerate(), 44100)
            self.assertAlmostEqual(stream.getnframes() / stream.getframerate(), 1.0, delta=0.05)

    def test_cancellation_leaves_no_conversion(self):
        event = Event()
        event.set()
        with self.assertRaises(MediaCancelled):
            self.tools.convert(self.source, self.root / 'Cancelled', cancel=event)
        self.assertFalse((self.root / 'Cancelled').exists())

    def test_destination_existing_file_remains_intact(self):
        same = self.root / 'Existing.m4b'
        same.write_bytes(b'existing file')
        with self.assertRaises(MediaError):
            self.tools.convert(self.source, self.root, destinations=lambda _specs: [same])
        self.assertEqual(same.read_bytes(), b'existing file')

    def test_destination_must_stay_inside_selected_folder(self):
        outside = self.root / 'Other' / 'Unexpected.m4b'
        with self.assertRaisesRegex(MediaError, 'inside the destination'):
            self.tools.convert(self.source, self.root / 'Destination', destinations=lambda _specs: [outside])
        self.assertFalse(outside.parent.exists())

    def test_replaced_output_directory_is_not_used(self):
        target = self.root / 'Destination' / 'New.m4b'
        relocated = self.root / 'Relocated'
        render = self.tools._render

        def replace_after_render(*args, **kwargs):
            render(*args, **kwargs)
            target.parent.rename(relocated)
            target.parent.mkdir()

        with (patch.object(self.tools, '_render', side_effect=replace_after_render),
              self.assertRaisesRegex(MediaError, 'moved or replaced')):
            self.tools.convert(self.source, target.parent, destinations=lambda _specs: [target])
        self.assertEqual(list(target.parent.iterdir()), [])
        self.assertFalse((relocated / target.name).exists())

    def test_audio_changed_during_render_is_not_published(self):
        output = self.root / 'Output'
        render = self.tools._render

        def modify_after_render(*args, **kwargs):
            render(*args, **kwargs)
            with self.source.open('ab') as stream:
                stream.write(b'change to source file')

        with (patch.object(self.tools, '_render', side_effect=modify_after_render),
              self.assertRaisesRegex(MediaError, 'source audio changed')):
            self.tools.convert(self.source, output)
        self.assertEqual(list(output.iterdir()), [])

    def test_expected_source_identity_rejects_same_size_replacement(self):
        expected = source_revision(self.source)
        replacement = self.source.with_name('Replacement.m4b')
        shutil.copy2(self.source, replacement)
        replacement.replace(self.source)
        self.assertEqual(source_revision(self.source)[2:], expected[2:])
        with self.assertRaisesRegex(MediaError, 'source audio changed'):
            self.tools.convert(MediaInput(self.source, expected_revision=expected), self.root / 'Replacement Output')

    @unittest.skipUnless(os.name == 'nt', 'Windows limits unprefixed paths to MAX_PATH')
    def test_long_archive_names_leave_room_for_temporary_files(self):
        layout = ArchiveLayout(self.root / 'Archive')
        book = {'title': 'Long title ' * 15, 'authors': ['Demo author ' * 5]}
        companion = layout.destination(book, 'pdf', folder_format='m4b', name_suffix=' - Companion')
        companion.parent.mkdir(parents=True)
        temporary = companion.with_name('.' + '1' * 32 + '.partial')
        temporary.write_bytes(b'synthetic companion')
        temporary.rename(companion)

        def destinations(specs):
            return [layout.destination(book, spec.format) for spec in specs]

        output, = self.tools.convert(self.source, layout.root, metadata=book, destinations=destinations)
        self.assertEqual(output.parent, companion.parent)
        self.assertIsNone(self.tools.audio_issue(output))


if __name__ == '__main__':
    unittest.main()
