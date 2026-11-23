"""Build an installable KernelSU module ZIP using Python's standard library."""

import argparse
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def main():
    base = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=base / "AutoDeck.zip")
    output = parser.parse_args().output

    names = ("module.prop", "customize.sh", "device.sh", "uninstall.sh")
    files = {name: (base / "module" / name).read_bytes() for name in names}
    for name, content in files.items():
        if b"\r" in content:
            parser.error(f"{name} must use LF line endings")
    with ZipFile(output, "w", ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    print(output.resolve())


if __name__ == "__main__":
    main()
