
from __future__ import annotations

import ctypes
import json
import os
import platform
import re
import shutil
import subprocess
import sys


def _run(*command: str) -> str:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


_windows: dict[str, str] = {}


def _windows_fact(name: str) -> str:
    if not _windows:
        found = _powershell(
            "$p = @(Get-CimInstance Win32_Processor); $g = @(Get-CimInstance Win32_VideoController); "
            "[pscustomobject]@{cpu = ($p | Select-Object -First 1).Name; "
            "cores = ($p | Measure-Object NumberOfCores -Sum).Sum; "
            "ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory; "
            "gpus = ($g.Name -join [char]10)} | ConvertTo-Json -Compress")
        try:
            _windows.update({k: str(v if v is not None else "") for k, v in json.loads(found).items()})
        except ValueError:
            _windows["failed"] = "1"
    return _windows.get(name, "")


def _powershell(script: str) -> str:
    return _run("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)


def cpu_model() -> str:
    system = platform.system()
    if system == "Linux":
        try:
            for line in open("/proc/cpuinfo", encoding="utf-8", errors="replace"):
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
        except OSError:
            pass
        found = re.search(r"^Model name:\s*(.+)$", _run("lscpu"), re.MULTILINE)
        vendor = re.search(r"^Vendor ID:\s*(.+)$", _run("lscpu"), re.MULTILINE)
        if found:
            return " ".join(x for x in (vendor.group(1).strip() if vendor else "", found.group(1).strip()) if x)
        return arm_core()
    elif system == "Darwin":
        return _run("sysctl", "-n", "machdep.cpu.brand_string")
    elif system == "Windows" or os.name == "nt" or "MSYS" in system or "CYGWIN" in system:
        return _windows_fact("cpu").strip()
    return platform.processor()


ARM_CORES = {("0x41", "0xd0c"): "ARM Neoverse-N1", ("0x41", "0xd40"): "ARM Neoverse-V1",
             ("0x41", "0xd49"): "ARM Neoverse-N2", ("0x41", "0xd4f"): "ARM Neoverse-V2",
             ("0x41", "0xd8e"): "ARM Neoverse-N3", ("0x41", "0xd84"): "ARM Neoverse-V3",
             ("0xc0", "0xac3"): "Ampere AmpereOne", ("0xc0", "0xac4"): "Ampere AmpereOne"}


def arm_core() -> str:
    try:
        text = open("/proc/cpuinfo", encoding="utf-8", errors="replace").read()
    except OSError:
        return ""
    implementer = re.search(r"^CPU implementer\s*:\s*(\S+)", text, re.MULTILINE)
    part = re.search(r"^CPU part\s*:\s*(\S+)", text, re.MULTILINE)
    if not (implementer and part):
        return ""
    return ARM_CORES.get((implementer.group(1).lower(), part.group(1).lower()), "")


def ram_bytes() -> int | None:
    system = platform.system()
    if system == "Linux":
        try:
            for line in open("/proc/meminfo", encoding="utf-8"):
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
        except (OSError, ValueError):
            return None
    if system == "Darwin":
        value = _run("sysctl", "-n", "hw.memsize")
        return int(value) if value.isdigit() else None
    if os.name == "nt":
        class Status(ctypes.Structure):
            _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong), ("total", ctypes.c_ulonglong),
                        ("avail", ctypes.c_ulonglong), ("pagetotal", ctypes.c_ulonglong),
                        ("pageavail", ctypes.c_ulonglong), ("virtualtotal", ctypes.c_ulonglong),
                        ("virtualavail", ctypes.c_ulonglong), ("extended", ctypes.c_ulonglong)]

        status = Status()
        status.length = ctypes.sizeof(Status)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            return int(status.total)
        return None
    value = _windows_fact("ram")
    return int(value) if value.isdigit() else None


def gpu() -> str:
    if shutil.which("nvidia-smi"):
        names = _run("nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader")
        if names:
            return "; ".join(line.strip() for line in names.splitlines() if line.strip())
    system = platform.system()
    if system == "Darwin":
        found = re.findall(r"Chipset Model:\s*(.+)", _run("system_profiler", "SPDisplaysDataType"))
        cores = re.findall(r"Total Number of Cores:\s*(\d+)", _run("system_profiler", "SPDisplaysDataType"))
        names = [n.strip() for n in found if "paravirtual" not in n.lower()]
        if names:
            return names[0] + (f" ({cores[0]} GPU cores)" if cores else "")
        return ""
    if os.name == "nt" or "MSYS" in system:
        names = _windows_fact("gpus").splitlines()
        real = [n.strip() for n in names if n.strip() and not re.search(
            r"(?i)basic display|hyper-v|virtual|remote|indirect|sunshine|parsec|microsoft", n)]
        return "; ".join(real)
    return ""


def physical_cores() -> int | None:
    system = platform.system()
    if system == "Linux":
        found = _run("lscpu")
        per = re.search(r"^Core\(s\) per (?:socket|cluster):\s*(\d+)", found, re.MULTILINE)
        sockets = re.search(r"^(?:Socket|Cluster)\(s\):\s*(\d+)", found, re.MULTILINE)
        if per:
            return int(per.group(1)) * (int(sockets.group(1)) if sockets else 1)
        return None
    if system == "Darwin":
        value = _run("sysctl", "-n", "hw.physicalcpu")
        return int(value) if value.isdigit() else None
    if os.name == "nt" or "MSYS" in system or "CYGWIN" in system:
        value = _windows_fact("cores")
        return int(value) if value.isdigit() else None
    return None


def machine(path: str | None = None) -> dict[str, object]:
    path = path or ("C:\\" if os.name == "nt" else "/")
    machine: dict[str, object] = {"arch": platform.machine()}
    if os.cpu_count():
        machine["cpus"] = os.cpu_count()
    cores = physical_cores()
    if cores:
        machine["cores"] = cores
    model = re.sub(r"\s+", " ", cpu_model() or "").strip()
    if model:
        machine["cpu_model"] = model
    ram = ram_bytes()
    if ram:
        machine["ram_gb"] = round(ram / 1024**3, 1)
    try:
        usage = shutil.disk_usage(path)
        machine["disk_gb"] = round(usage.total / 1024**3)
        machine["disk_free_gb"] = round(usage.free / 1024**3)
    except OSError:
        pass
    machine["gpu"] = gpu()
    return machine


def main() -> None:
    print(json.dumps(machine(sys.argv[1] if len(sys.argv) > 1 else None)))


if __name__ == "__main__":
    main()
