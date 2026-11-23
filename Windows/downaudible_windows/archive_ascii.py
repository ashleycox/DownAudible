"""Transliterate archive names with the Windows system ICU library."""

import ctypes
import os
import unicodedata
from functools import cache


@cache
def _windows_icu():
    if os.name != 'nt':
        return None
    try:
        library = ctypes.CDLL('icu.dll', winmode=0x800)  # LOAD_LIBRARY_SEARCH_SYSTEM32
        number = ctypes.c_int32
        address = ctypes.c_void_p
        count = ctypes.POINTER(number)
        library.utrans_openU.argtypes = [address, number, number, address, number, address, count]
        library.utrans_openU.restype = address
        library.utrans_transUChars.argtypes = [address, address, count, number, number, count, count]
        library.utrans_transUChars.restype = None
        library.utrans_close.argtypes = [address]
        library.utrans_close.restype = None
        return library
    except (OSError, AttributeError):
        return None


def _latin(value: str) -> str:
    library = _windows_icu()
    if library is None:
        return value
    name = 'Any-Latin'
    identifier = ctypes.create_string_buffer(name.encode('utf-16-le'))
    error = ctypes.c_int32()
    translator = library.utrans_openU(identifier, len(name), 0, None, 0, None, ctypes.byref(error))
    if not translator:
        return value
    try:
        if error.value > 0:
            return value
        original = value.encode('utf-16-le', 'surrogatepass')
        length = len(original) // 2
        capacity = length * 2 + 1
        for _ in range(2):
            buffer = ctypes.create_string_buffer(original, capacity * 2)
            text_length = ctypes.c_int32(length)
            limit = ctypes.c_int32(length)
            error.value = 0
            library.utrans_transUChars(translator, buffer, ctypes.byref(text_length), capacity, 0,
                                       ctypes.byref(limit), ctypes.byref(error))
            if error.value <= 0 and 0 <= text_length.value <= capacity:
                return ctypes.string_at(buffer, text_length.value * 2).decode('utf-16-le', 'replace')
            if error.value != 15 or text_length.value <= capacity:  # U_BUFFER_OVERFLOW_ERROR
                break
            capacity = text_length.value + 1
        return value
    finally:
        library.utrans_close(translator)


def ascii_name(value: str) -> str:
    if value.isascii():
        return value
    return unicodedata.normalize('NFKD', _latin(value)).encode('ascii', 'ignore').decode('ascii')
