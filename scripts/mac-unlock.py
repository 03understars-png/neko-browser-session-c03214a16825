
from __future__ import annotations

import ctypes
import os
import sys
import time
from ctypes import c_bool, c_char_p, c_uint16, c_uint32, c_void_p

CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
UTF8 = 0x08000100
HID_TAP = 0
RETURN, SHIFT = 36, 56

CG.CGSessionCopyCurrentDictionary.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint32]
CF.CFStringCreateWithCString.restype = c_void_p
CF.CFDictionaryGetValue.argtypes = [c_void_p, c_void_p]
CF.CFDictionaryGetValue.restype = c_void_p
CF.CFBooleanGetValue.argtypes = [c_void_p]
CF.CFBooleanGetValue.restype = c_bool
CG.CGEventCreateKeyboardEvent.argtypes = [c_void_p, c_uint16, c_bool]
CG.CGEventCreateKeyboardEvent.restype = c_void_p
CG.CGEventKeyboardSetUnicodeString.argtypes = [c_void_p, ctypes.c_ulong, ctypes.POINTER(c_uint16)]
CG.CGEventPost.argtypes = [c_uint32, c_void_p]
CF.CFRelease.argtypes = [c_void_p]


def locked() -> bool:
    session = CG.CGSessionCopyCurrentDictionary()
    if not session:
        return True
    key = CF.CFStringCreateWithCString(None, b"CGSSessionScreenIsLocked", UTF8)
    value = CF.CFDictionaryGetValue(session, key)
    return bool(value) and CF.CFBooleanGetValue(value)


def key(code: int, text: str = "") -> None:
    for down in (True, False):
        event = CG.CGEventCreateKeyboardEvent(None, code, down)
        if text:
            units = text.encode("utf-16-le")
            buffer = (c_uint16 * (len(units) // 2)).from_buffer_copy(units)
            CG.CGEventKeyboardSetUnicodeString(event, len(buffer), buffer)
        CG.CGEventPost(HID_TAP, event)
        CF.CFRelease(event)
        time.sleep(0.03)


def unlock(password: str) -> bool:
    key(SHIFT)
    time.sleep(1.5)
    for character in password:
        key(0, character)
    key(RETURN)
    for _ in range(20):
        time.sleep(0.5)
        if not locked():
            return True
    return False


def main() -> int:
    if sys.argv[1:] == ["--locked"]:
        return 0 if locked() else 1
    if sys.argv[1:] == ["--unlock"]:
        password = os.environ.get("CB_UNLOCK", "")
        if not password:
            return 2
        return 0 if unlock(password) else 1
    print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
