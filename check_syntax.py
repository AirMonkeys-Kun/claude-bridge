"""Syntax check all refactored skia_gui files"""
import sys, py_compile, os
base = r'C:\Users\wsx\Documents\SmartAgent\applications'
sys.path.insert(0, base)
files = ['main.py', 'dashboard.py', 'services.py', 'monitor.py', 'settings.py',
         'log_viewer.py', 'env.py', 'config.py', 'cluster.py', 'ai_model_manager.py', 'ai_agent_chat.py']
errors = []
for f in files:
    path = os.path.join(base, 'skia_gui', f)
    try:
        py_compile.compile(path, doraise=True)
        print(f'  [OK] {f}')
    except py_compile.PyCompileError as e:
        errors.append(f'  [ERR] {f}: {e}')
        print(f'  [ERR] {f}: {e}')
print()
if errors:
    print(f'FAIL: {len(errors)} errors')
else:
    print('PASS: All files compile')
