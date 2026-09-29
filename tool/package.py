#!/usr/bin/env python3
"""Build desktop app + pure-Dart adapter, then assemble a portable artifact."""
import argparse
import pathlib
import platform
import shutil
import subprocess
import json
from package_support import install_executable

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--debug', action='store_true')
parser.add_argument('--no-build', action='store_true')
args = parser.parse_args()
system = {'Darwin': 'macos', 'Windows': 'windows', 'Linux': 'linux'}[platform.system()]
mode = 'debug' if args.debug else 'release'

def run(command):
    subprocess.run(command, cwd=ROOT, check=True)

if not args.no_build:
    run([shutil.which('flutter'), 'pub', 'get'])
    run([shutil.which('dart'), 'run', 'tool/build_adapter.dart'])
    run([shutil.which('flutter'), 'build', system, f'--{mode}', '--no-pub'])

adapter = ROOT / 'build' / 'adapters' / ('im_adapter.exe' if system == 'windows' else 'im_adapter')
if not adapter.is_file():
    raise SystemExit('Missing adapter. Run dart run tool/build_adapter.dart first.')
if system == 'macos':
    app = ROOT / 'build/macos/Build/Products' / mode.capitalize() / 'imbroglio.app'
    destination = app / 'Contents/Resources/adapters'
elif system == 'windows':
    app = ROOT / 'build/windows/x64/runner' / mode.capitalize()
    destination = app / 'adapters'
else:
    arch = 'arm64' if platform.machine() in ('aarch64', 'arm64') else 'x64'
    app = ROOT / f'build/linux/{arch}/{mode}/bundle'
    destination = app / 'adapters'
if not app.exists():
    raise SystemExit(f'Application build not found: {app}')
destination.mkdir(parents=True, exist_ok=True)
def sign_adapter(path):
    run(['codesign', '--force', '--sign', '-', '--identifier', 'com.sinri.imbroglio.adapter', str(path)])
    run(['codesign', '--verify', '--strict', str(path)])

installed_adapter = destination / adapter.name
install_executable(adapter, installed_adapter, sign_adapter if system == 'macos' else None)
if system == 'macos':
    # Local unsigned distribution. Release signing/notarization needs publisher credentials.
    run(['codesign', '--force', '--sign', '-', str(app)])
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
# Exercise the packaged executable, not only its on-disk signature. No account
# initialization or business API is involved in the shutdown handshake.
probe = subprocess.run(
    [str(installed_adapter)],
    input=json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'shutdown', 'params': {}}) + '\n',
    text=True, capture_output=True, timeout=15, check=True,
)
response = json.loads(probe.stdout.strip())
# A fresh adapter rejects shutdown until initialize, then its main loop exits.
# This proves both executable launch and JSON-RPC dispatch without using a CLI.
if response.get('id') != 1 or response.get('error', {}).get('code') != 'state':
    raise SystemExit('Packaged adapter failed the protocol startup check.')
output = ROOT / 'dist'
output.mkdir(exist_ok=True)
name = f'imbroglio-{system}-{platform.machine()}-{mode}'
if system == 'macos':
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(output / f'{name}.zip')])
else:
    shutil.make_archive(str(output / name), 'zip' if system == 'windows' else 'gztar', root_dir=app)
print(f'Packaged: {output / name}')
