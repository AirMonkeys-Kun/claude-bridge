# Fix all skia_gui imports after directory promotion
$base = "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui"
$files = Get-ChildItem $base -Filter "*.py" | Where-Object { $_.Name -ne "main.py" -and $_.Name -ne "__init__.py" }

$fixDocstring = @{
    "dashboard.py" = "applications/skia_gui/dashboard.py"
    "services.py" = "applications/skia_gui/services.py"
    "monitor.py" = "applications/skia_gui/monitor.py"
    "log_viewer.py" = "applications/skia_gui/log_viewer.py"
    "env.py" = "applications/skia_gui/env.py"
    "config.py" = "applications/skia_gui/config.py"
    "settings.py" = "applications/skia_gui/settings.py"
    "cluster.py" = "applications/skia_gui/cluster.py"
    "ai_model_manager.py" = "applications/skia_gui/ai_model_manager.py"
    "ai_agent_chat.py" = "applications/skia_gui/ai_agent_chat.py"
    "service_store.py" = "applications/skia_gui/service_store.py"
}

$oldPathHack = @'
sys.path.insert(0, str(Path(__file__).parent.parent.parent))
sys.path.insert(0, str(Path(__file__).parent.parent))
'@

$newPathHack = "sys.path.insert(0, str(Path(__file__).parent.parent))  # adds applications/"

foreach ($f in $files) {
    $content = Get-Content $f.FullName -Raw

    # 1. Fix docstring run path
    $oldRun = "python experiments/skia_gui/"
    $newRun = "python applications/skia_gui/"
    $content = $content -replace [regex]::Escape($oldRun), $newRun

    # 2. Fix sys.path lines
    $content = $content -replace [regex]::Escape($oldPathHack), $newPathHack

    # Write back (UTF8 without BOM)
    [System.IO.File]::WriteAllText($f.FullName, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Fixed: $($f.Name)"
}

Write-Output "=== Done ==="
