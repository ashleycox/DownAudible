"""Send a verified local source to the Windows Recycle Bin."""

import ctypes
import os
import stat
from ctypes import wintypes
from pathlib import Path
from uuid import UUID

RECYCLE_FLAGS = (
    0x00080000  # FOFX_RECYCLEONDELETE
    | 0x20000000  # FOFX_ADDUNDORECORD
    | 0x00100000  # FOFX_EARLYFAILURE
    | 0x0400  # FOF_NOERRORUI
    | 0x0040  # FOF_ALLOWUNDO
    | 0x0004  # FOF_SILENT
)
FILE_OPERATION = UUID('3ad05575-8857-4850-9277-11b85bdb8e09')
FILE_OPERATION_INTERFACE = UUID('947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8')
SHELL_ITEM_INTERFACE = UUID('43826d1e-e718-42ee-bc55-a1e261c37bfe')


def _guid(value: UUID):
    return (ctypes.c_ubyte * 16).from_buffer_copy(value.bytes_le)


def _method(interface, index, result, *parameters):
    vtable = ctypes.cast(interface, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    return ctypes.WINFUNCTYPE(result, ctypes.c_void_p, *parameters)(vtable[index])


def _release(interface):
    if interface:
        _method(interface, 2, wintypes.ULONG)(interface)


def _same_revision(left, right):
    return (os.path.samestat(left, right) and left.st_size == right.st_size
            and left.st_mtime_ns == right.st_mtime_ns)


def recycle_source(path: Path, revision: os.stat_result) -> bool:
    if os.name != 'nt':
        return False
    try:
        path = Path(path).absolute()
        drive_type = ctypes.windll.kernel32.GetDriveTypeW
        drive_type.argtypes = (wintypes.LPCWSTR,)
        drive_type.restype = wintypes.UINT
        if not path.anchor or drive_type(path.anchor) != 3:  # DRIVE_FIXED
            return False
        resolved = path.resolve(strict=True)
        if path != resolved:
            return False
        current = path.lstat()
        if not stat.S_ISREG(current.st_mode) or current.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            return False
        if not _same_revision(current, revision):
            return False
        return _recycle(path, revision)
    except OSError:
        return False


def _recycle(path, revision):
    shell, ole = ctypes.windll.shell32, ctypes.windll.ole32
    initialize = ole.CoInitializeEx
    initialize.argtypes = (ctypes.c_void_p, wintypes.DWORD)
    initialize.restype = wintypes.LONG
    if initialize(None, 0x2 | 0x4) < 0:
        return False

    operation = ctypes.c_void_p()
    item = ctypes.c_void_p()
    try:
        create = ole.CoCreateInstance
        create.argtypes = (ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
                           ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p))
        create.restype = wintypes.LONG
        if create(_guid(FILE_OPERATION), None, 1, _guid(FILE_OPERATION_INTERFACE), ctypes.byref(operation)) < 0:
            return False
        shell_item = shell.SHCreateItemFromParsingName
        shell_item.argtypes = (wintypes.LPCWSTR, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p))
        shell_item.restype = wintypes.LONG
        if shell_item(str(path), None, _guid(SHELL_ITEM_INTERFACE), ctypes.byref(item)) < 0:
            return False
        set_flags = _method(operation, 5, wintypes.LONG, wintypes.DWORD)
        delete = _method(operation, 18, wintypes.LONG, ctypes.c_void_p, ctypes.c_void_p)
        perform = _method(operation, 21, wintypes.LONG)
        get_aborted = _method(operation, 22, wintypes.LONG, ctypes.POINTER(wintypes.BOOL))
        if set_flags(operation, RECYCLE_FLAGS) < 0 or delete(operation, item, None) < 0:
            return False
        if not _same_revision(path.lstat(), revision) or perform(operation) < 0:
            return False
        aborted = wintypes.BOOL()
        return get_aborted(operation, ctypes.byref(aborted)) >= 0 and not aborted.value and not os.path.lexists(path)
    finally:
        _release(item)
        _release(operation)
        ole.CoUninitialize()
