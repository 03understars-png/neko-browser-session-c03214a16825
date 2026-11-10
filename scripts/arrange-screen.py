
from __future__ import annotations

import ctypes
import sys
from ctypes import POINTER, byref, c_bool, c_char_p, c_double, c_int32, c_long, c_size_t, c_uint32, c_void_p

CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
try:
    SYNC = ctypes.CDLL("/System/Library/Frameworks/ColorSync.framework/ColorSync")
    SYNC.CGDisplayCreateUUIDFromDisplayID
except (OSError, AttributeError):
    SYNC = CG

PERMANENTLY, FOR_SESSION = 2, 1
UTF8 = 0x08000100


def _types() -> None:
    CG.CGGetOnlineDisplayList.argtypes = [c_uint32, POINTER(c_uint32), POINTER(c_uint32)]
    CG.CGGetOnlineDisplayList.restype = c_int32
    SYNC.CGDisplayCreateUUIDFromDisplayID.argtypes = [c_uint32]
    SYNC.CGDisplayCreateUUIDFromDisplayID.restype = c_void_p
    CF.CFUUIDCreateString.argtypes = [c_void_p, c_void_p]
    CF.CFUUIDCreateString.restype = c_void_p
    CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_long, c_uint32]
    CF.CFStringGetCString.restype = c_bool
    CF.CFDictionaryCreate.argtypes = [c_void_p, POINTER(c_void_p), POINTER(c_void_p), c_long, c_void_p, c_void_p]
    CF.CFDictionaryCreate.restype = c_void_p
    CF.CFArrayGetCount.argtypes = [c_void_p]
    CF.CFArrayGetCount.restype = c_long
    CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_long]
    CF.CFArrayGetValueAtIndex.restype = c_void_p
    CG.CGDisplayCopyAllDisplayModes.argtypes = [c_uint32, c_void_p]
    CG.CGDisplayCopyAllDisplayModes.restype = c_void_p
    for name in ("Width", "Height", "PixelWidth", "PixelHeight"):
        getattr(CG, f"CGDisplayModeGet{name}").argtypes = [c_void_p]
        getattr(CG, f"CGDisplayModeGet{name}").restype = c_size_t
    CG.CGDisplayModeGetRefreshRate.argtypes = [c_void_p]
    CG.CGDisplayModeGetRefreshRate.restype = c_double
    CG.CGBeginDisplayConfiguration.argtypes = [POINTER(c_void_p)]
    CG.CGBeginDisplayConfiguration.restype = c_int32
    CG.CGConfigureDisplayMirrorOfDisplay.argtypes = [c_void_p, c_uint32, c_uint32]
    CG.CGConfigureDisplayMirrorOfDisplay.restype = c_int32
    CG.CGConfigureDisplayWithDisplayMode.argtypes = [c_void_p, c_uint32, c_void_p, c_void_p]
    CG.CGConfigureDisplayWithDisplayMode.restype = c_int32
    CG.CGConfigureDisplayOrigin.argtypes = [c_void_p, c_uint32, c_int32, c_int32]
    CG.CGConfigureDisplayOrigin.restype = c_int32
    CG.CGCompleteDisplayConfiguration.argtypes = [c_void_p, c_uint32]
    CG.CGCompleteDisplayConfiguration.restype = c_int32
    CG.CGCancelDisplayConfiguration.argtypes = [c_void_p]
    CG.CGCancelDisplayConfiguration.restype = c_int32
    CG.CGMainDisplayID.restype = c_uint32


def screens() -> dict[str, int]:
    ids = (c_uint32 * 16)()
    count = c_uint32()
    if CG.CGGetOnlineDisplayList(16, ids, byref(count)):
        return {}
    found = {}
    for number in ids[: count.value]:
        uuid = SYNC.CGDisplayCreateUUIDFromDisplayID(number)
        if not uuid:
            continue
        text = CF.CFUUIDCreateString(None, uuid)
        buffer = ctypes.create_string_buffer(64)
        if text and CF.CFStringGetCString(text, buffer, 64, UTF8):
            found[buffer.value.decode().upper()] = number
    return found


def retina_mode(display: int, width: int, height: int):
    key = c_void_p.in_dll(CG, "kCGDisplayShowDuplicateLowResolutionModes")
    true = c_void_p.in_dll(CF, "kCFBooleanTrue")
    keys, values = (c_void_p * 1)(key.value), (c_void_p * 1)(true.value)
    options = CF.CFDictionaryCreate(
        None, keys, values, 1,
        ctypes.addressof(ctypes.c_char.in_dll(CF, "kCFTypeDictionaryKeyCallBacks")),
        ctypes.addressof(ctypes.c_char.in_dll(CF, "kCFTypeDictionaryValueCallBacks")))
    modes = CG.CGDisplayCopyAllDisplayModes(display, options)
    if not modes:
        return None
    best, best_rank = None, None
    for index in range(CF.CFArrayGetCount(modes)):
        mode = CF.CFArrayGetValueAtIndex(modes, index)
        if (CG.CGDisplayModeGetWidth(mode), CG.CGDisplayModeGetHeight(mode)) != (width, height):
            continue
        rank = (CG.CGDisplayModeGetPixelWidth(mode) == 2 * width, round(CG.CGDisplayModeGetRefreshRate(mode)) == 60)
        if best_rank is None or rank > best_rank:
            best, best_rank = mode, rank
    return best


def apply(scope: int, virtual: int, physical: int | None, mode, mirror: bool) -> bool:
    ref = c_void_p()
    if CG.CGBeginDisplayConfiguration(byref(ref)):
        return False
    steps = []
    if physical is not None:
        steps.append(CG.CGConfigureDisplayMirrorOfDisplay(ref, physical, virtual if mirror else 0))
    if mode:
        steps.append(CG.CGConfigureDisplayWithDisplayMode(ref, virtual, mode, None))
    steps.append(CG.CGConfigureDisplayOrigin(ref, virtual, 0, 0))
    if physical is not None and not mirror:
        steps.append(CG.CGConfigureDisplayOrigin(ref, physical, CG.CGDisplayModeGetWidth(mode) if mode else 4096, 0))
    if any(steps):
        CG.CGCancelDisplayConfiguration(ref)
        return False
    return CG.CGCompleteDisplayConfiguration(ref, scope) == 0


ATTEMPTS = {
    "mirror": (FOR_SESSION, True, True, True),
    "beside": (FOR_SESSION, False, True, True),
    "first": (FOR_SESSION, False, False, False),
}
DESCRIBED = {
    "mirror": "the Mac's screen mirrors it",
    "beside": "the Mac's screen is beside it",
    "first": "it was only made the first screen",
}


def attempt(name: str, virtual_id: str, physical_id: str, width: int, height: int) -> int:
    scope, mirror, with_mode, with_physical = ATTEMPTS[name]
    _types()
    online = screens()
    virtual, physical = online.get(virtual_id.upper()), online.get(physical_id.upper())
    if virtual is None:
        return 3
    mode = retina_mode(virtual, width, height) if with_mode else None
    applied = apply(scope, virtual, physical if with_physical else None, mode, mirror)
    return 0 if applied and CG.CGMainDisplayID() == virtual else 1


def answers() -> int:
    _types()
    ref = c_void_p()
    if CG.CGBeginDisplayConfiguration(byref(ref)):
        return 1
    return 0 if CG.CGCompleteDisplayConfiguration(ref, FOR_SESSION) == 0 else 1


def status() -> str:
    _types()
    CG.CGDisplayIsActive.argtypes = CG.CGDisplayIsAsleep.argtypes = [c_uint32]
    CG.CGDisplayIsActive.restype = CG.CGDisplayIsAsleep.restype = c_bool
    main = CG.CGMainDisplayID()
    parts = []
    for uuid, number in screens().items():
        flags = [name for name, on in (("active", CG.CGDisplayIsActive(number)), ("asleep", CG.CGDisplayIsAsleep(number)),
                                       ("main", number == main)) if on]
        parts.append(f"{number} {uuid[:8]} {'/'.join(flags) or 'inactive'}")
    return "; ".join(parts) or "none online"


def main() -> int:
    if sys.argv[1:] == ["--status"]:
        print(status())
        return 0
    if sys.argv[1:] == ["--active"]:
        return 0 if " active" in " " + status().replace("/", " ") else 1
    if len(sys.argv) == 3 and sys.argv[1] == "--id":
        _types()
        number = screens().get(sys.argv[2].upper())
        if number is None:
            return 1
        print(number)
        return 0
    if sys.argv[1:] == ["--check"]:
        return answers()
    if len(sys.argv) == 7 and sys.argv[1] == "--attempt":
        return attempt(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6]))
    if len(sys.argv) != 5:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    import subprocess

    _types()
    online = screens()
    if sys.argv[1].upper() not in online:
        print("The Retina screen is not online.", file=sys.stderr)
        return 1
    try:
        vm = subprocess.run(["sysctl", "-n", "kern.hv_vmm_present"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        vm = "?"
    print(f"Screens online: {len(online)}; main {CG.CGMainDisplayID()}; virtual machine: {vm == '1'}", file=sys.stderr)
    results = []
    for name in ATTEMPTS:
        try:
            code = subprocess.run([sys.executable, __file__, "--attempt", name, *sys.argv[1:]],
                                  timeout=8, capture_output=True).returncode
            result = {0: "applied", 1: "refused", 3: "screen gone"}.get(code, f"failed ({code})")
        except subprocess.TimeoutExpired:
            result = "no answer in 8 s"
        results.append(f"{name}: {result}")
        if result == "applied":
            print(f"Retina screen is the main one; {DESCRIBED[name]}.")
            print("Tried: " + "; ".join(results), file=sys.stderr)
            return 0
    print("CoreGraphics refused every arrangement: " + "; ".join(results), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
