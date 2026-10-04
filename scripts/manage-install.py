#!/usr/bin/env python3
"""Install the LinkAll shell and LinkInput input method as one reversible distribution.
Runtime identifiers and user data are deliberately not renamed.
"""
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
USER = Path.home()
SCRATCH = ROOT / 'scratch'
REGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
DESTINATIONS = {
    'input': (USER / 'Library/Input Methods/Yiliu.app', 'work.yiliu.inputmethod.Yiliu'),
    'shell': (USER / 'Applications/LinkAll.app', 'work.yiliu.companion'),
    'legacy': (USER / 'Applications/LinkInputCompanion.app', 'work.yiliu.companion'),
}
BACKUP = SCRATCH / 'LinkAll-previous.zip'
SOURCE_ID = 'work.yiliu.inputmethod.Yiliu.Hans'

def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                          stdout=subprocess.PIPE if capture else None, text=capture)

def validate(path, identifier):
    if not path.exists(): return
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != identifier:
        raise RuntimeError(f'目标位置属于其他应用，已停止：{path}')

def running(name):
    return subprocess.run(['pgrep', '-x', name], stdout=subprocess.DEVNULL).returncode == 0

def stop():
    current = run('swift', 'scripts/input-source.swift', 'current', capture=True).stdout.strip()
    if current == SOURCE_ID:
        run('swift', 'scripts/input-source.swift', 'select', 'com.apple.keylayout.ABC', capture=True)
    # Stop the input process first, so it cannot bring the shell back during replacement.
    for label, binary in [('input', 'Yiliu'), ('shell', 'LinkInputCompanion'), ('legacy', 'LinkInputCompanion')]:
        path = DESTINATIONS[label][0] / 'Contents/MacOS' / binary
        if path.is_file(): run(path, '--quit', capture=True)
    # Old installations may have only a nested helper. The stable CLI notification reaches it too.
    helper = ROOT / 'build/LinkAll.app/Contents/MacOS/LinkInputCompanion'
    if running('LinkInputCompanion') and helper.exists(): run(helper, '--quit', capture=True)
    for _ in range(40):
        if not running('Yiliu') and not running('LinkInputCompanion'): return
        time.sleep(.2)
    raise RuntimeError('LinkAll 或 LinkInput 尚未退出。请关闭它们的对话框后重试，安装文件未替换。')

def backup():
    with tempfile.TemporaryDirectory(dir=SCRATCH, prefix='linkall-backup-') as temp:
        state = Path(temp) / 'state'; state.mkdir()
        manifest = []
        for label, (path, identifier) in DESTINATIONS.items():
            if path.exists():
                run('ditto', path, state / path.name)
                manifest.append({'destination': label, 'name': path.name})
        (state / 'manifest.json').write_text(json.dumps(manifest))
        pending = SCRATCH / 'LinkAll-backup-pending.zip'
        run('ditto', '-c', '-k', '--keepParent', state, pending)
        pending.replace(BACKUP)

def remove_owned(label):
    path, identifier = DESTINATIONS[label]
    if path.exists():
        validate(path, identifier)
        subprocess.run([REGISTER, '-u', str(path)], stdout=subprocess.DEVNULL)
        shutil.rmtree(path)

def register_and_start(previous):
    shell = DESTINATIONS['shell'][0]
    if not shell.exists(): shell = DESTINATIONS['legacy'][0]
    if shell.exists(): run(REGISTER, '-f', shell)
    input_app = DESTINATIONS['input'][0]
    run(REGISTER, '-f', input_app)
    run('swift', 'scripts/input-source.swift', 'register', input_app)
    run('swift', 'scripts/input-source.swift', 'enable', SOURCE_ID)
    # LinkAll owns startup in the new layout; the legacy input method owns it on old rollbacks.
    run('open', shell if DESTINATIONS['shell'][0].exists() else input_app)
    if previous:
        time.sleep(1)
        run('swift', 'scripts/input-source.swift', 'select', previous, capture=True)

def install():
    sources = {'input': ROOT / 'build/Yiliu.app', 'shell': ROOT / 'build/LinkAll.app'}
    for label, path in sources.items():
        if not path.exists(): raise RuntimeError('请先运行 scripts/build.sh。')
        validate(path, DESTINATIONS[label][1]); run('codesign', '--verify', '--deep', '--strict', path)
    previous = run('swift', 'scripts/input-source.swift', 'current', capture=True).stdout.strip()
    stop(); backup()
    for label, source in sources.items():
        remove_owned(label); destination = DESTINATIONS[label][0]; destination.parent.mkdir(parents=True, exist_ok=True)
        run('ditto', source, destination)
    remove_owned('legacy')
    register_and_start(previous)
    print('已安装 LinkAll 和 LinkInput。原有授权标识、词库、凭据、配置和历史目录保持兼容。')
    print('更新时正在使用输入法的应用若仍输出字母，切到其他应用再切回；仍未恢复时重新打开原应用。')

def rollback():
    if not BACKUP.is_file(): raise RuntimeError('没有 LinkAll 安装脚本生成的上一版备份。')
    previous = run('swift', 'scripts/input-source.swift', 'current', capture=True).stdout.strip()
    with tempfile.TemporaryDirectory(dir=SCRATCH, prefix='linkall-rollback-') as temp:
        with zipfile.ZipFile(BACKUP) as archive:
            if any(Path(info.filename).is_absolute() or '..' in Path(info.filename).parts for info in archive.infolist()):
                raise RuntimeError('备份路径不合法，已停止回滚。')
        run('ditto', '-x', '-k', BACKUP, temp)
        state = Path(temp) / 'state'; manifest = json.loads((state / 'manifest.json').read_text())
        for entry in manifest:
            if entry['destination'] not in DESTINATIONS or entry['name'] != DESTINATIONS[entry['destination']][0].name:
                raise RuntimeError('备份清单不合法，已停止回滚。')
            validate(state / entry['name'], DESTINATIONS[entry['destination']][1])
        if not any(e['destination'] == 'input' for e in manifest): raise RuntimeError('备份不包含输入法，未回滚。')
        stop()
        for label in DESTINATIONS: remove_owned(label)
        for entry in manifest: run('ditto', state / entry['name'], DESTINATIONS[entry['destination']][0])
    register_and_start(previous)
    print('已恢复上一版应用组合；用户记录、设置、词库与凭据未回退。')

def uninstall():
    stop(); backup()
    for source in [SOURCE_ID, 'work.yiliu.inputmethod.Yiliu']:
        run('swift', 'scripts/input-source.swift', 'disable', source)
    for label in DESTINATIONS: remove_owned(label)
    print('LinkAll 和 LinkInput 已卸载；历史、词库、配置与凭据保留。应用备份在 scratch/LinkAll-previous.zip。')

if __name__ == '__main__':
    try:
        SCRATCH.mkdir(exist_ok=True)
        for path, identifier in DESTINATIONS.values(): validate(path, identifier)
        action = sys.argv[1] if len(sys.argv) == 2 else ''
        if action not in ['install', 'rollback', 'uninstall']: raise RuntimeError('Usage: manage-install.py install|rollback|uninstall')
        globals()[action]()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr); sys.exit(1)
