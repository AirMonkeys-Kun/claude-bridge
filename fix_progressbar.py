#!/usr/bin/env python3
"""Replace inline ProgressBar with framework import in dashboard.py & cluster.py"""
import re

files = {
    r"C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\dashboard.py": {
        "import_line": "from skia_framework.components.layout import Row, Column, Spacer",
        "new_import": "from skia_framework.components.layout import Row, Column, Spacer\nfrom skia_framework.components.progressbar import ProgressBar",
    },
    r"C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\cluster.py": {
        "import_line": "from skia_framework.components.layout import Row, Column, Spacer",
        "new_import": "from skia_framework.components.layout import Row, Column, Spacer\nfrom skia_framework.components.progressbar import ProgressBar",
    },
}

for path, cfg in files.items():
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    # 1. Fix imports: add ProgressBar import after layout import
    import_line = cfg["import_line"]
    if "ProgressBar" not in content:
        content = content.replace(import_line, cfg["new_import"])
        print(f"[{path}] Added ProgressBar import")
    else:
        print(f"[{path}] ProgressBar already imported")

    # 2. Remove inline ProgressBar class
    # Match from 'class ProgressBar(Widget):' to the next class or a blank line followed by non-indented code
    pattern = re.compile(
        r'class ProgressBar\(Widget\):.*?(?=\n\n(?:class |def |\Z))',
        re.DOTALL
    )
    new_content, count = pattern.sub('', content)
    if count > 0:
        # Clean up extra blank lines
        new_content = re.sub(r'\n{3,}', '\n\n', new_content)
        print(f"[{path}] Removed {count} inline ProgressBar definition(s)")
    else:
        # Try alternative - maybe the class uses a different base
        pattern2 = re.compile(r'class ProgressBar\b.*?(?=\n\n(?:class |def |\Z|\nfrom |\nimport ))', re.DOTALL)
        new_content, count2 = pattern2.sub('', content)
        if count2 > 0:
            new_content = re.sub(r'\n{3,}', '\n\n', new_content)
            print(f"[{path}] Removed {count2} inline ProgressBar (alt pattern)")
        else:
            print(f"[{path}] WARNING: Could not find ProgressBar class to remove")

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)

print("=== Done ===")
