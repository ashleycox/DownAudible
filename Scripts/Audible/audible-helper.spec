from pathlib import Path
from platform import machine

analysis = Analysis([str(Path(SPECPATH) / "audible_helper.py")])
modules = PYZ(analysis.pure)
launcher = EXE(
    modules,
    analysis.scripts,
    exclude_binaries=True,
    name="audible-helper",
    append_pkg=False,
    upx=False,
    console=True,
    target_arch=machine(),
)
bundle = COLLECT(
    launcher,
    analysis.binaries,
    analysis.datas,
    upx=False,
    name="audible-helper",
)
