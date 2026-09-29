import pathlib
import tempfile
import unittest

from package_support import install_executable


class InstallExecutableTest(unittest.TestCase):
    def test_replacement_preserves_old_open_inode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source, target = root / 'new', root / 'installed'
            source.write_bytes(b'new executable')
            source.chmod(0o755)
            target.write_bytes(b'old executable')
            with target.open('rb') as old:
                old_inode = target.stat().st_ino
                install_executable(source, target)
                self.assertNotEqual(target.stat().st_ino, old_inode)
                self.assertEqual(old.read(), b'old executable')
            self.assertEqual(target.read_bytes(), b'new executable')
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_signing_failure_leaves_previous_executable_intact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source, target = root / 'new', root / 'installed'
            source.write_bytes(b'new')
            target.write_bytes(b'old')

            def reject(staged):
                staged.write_bytes(b'failed signing')
                raise RuntimeError('signing failed')

            with self.assertRaises(RuntimeError):
                install_executable(source, target, reject)
            self.assertEqual(target.read_bytes(), b'old')
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['installed', 'new'])


if __name__ == '__main__':
    unittest.main()
