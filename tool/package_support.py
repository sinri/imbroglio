"""Install executables without modifying an inode that macOS may have cached."""
import os
import pathlib
import shutil
import tempfile


def install_executable(source, destination, prepare=None):
    destination = pathlib.Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.adapter-', dir=destination.parent)
    os.close(fd)
    staged = pathlib.Path(name)
    try:
        shutil.copy2(source, staged)
        if prepare is not None:
            prepare(staged)
        # Never overwrite executable bytes in place: the kernel caches signatures
        # by inode, even after codesign --verify reports the new bytes as valid.
        os.replace(staged, destination)
    finally:
        staged.unlink(missing_ok=True)
