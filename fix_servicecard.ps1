# Unify ServiceCard: remove inline definitions, use shared module
$utf8 = [System.Text.UTF8Encoding]::new($false)

# ── 1. Fix dashboard.py ──
$dash = "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\dashboard.py"
$content = [System.IO.File]::ReadAllText($dash, $utf8)

# 1a. Add import for ServiceCard from shared module
$oldImport = "from skia_framework.components.layout import Row, Column, Spacer"
$newImport = "from skia_framework.components.layout import Row, Column, Spacer`r`nfrom skia_gui.service_card import ServiceCard"

if ($content -notmatch "from skia_gui.service_card import") {
    $content = $content -replace [regex]::Escape($oldImport), $newImport
    Write-Output "dashboard: Added shared ServiceCard import"
}

# 1b. Remove inline ServiceCard class using multiline anchor
#     Matches from '^class ServiceCard(Container):' to next '^class ' or '^#  ' (section header)
$pattern = '(?sm)^class ServiceCard\(Container\):.*?^(?=class |# )'
$newContent = $content -replace $pattern, ''
if ($newContent -ne $content) {
    # Trim extra blank lines
    $newContent = $newContent -replace '(?m)^(\s*)$\r?\n(?:\r?\n)+', "`$1`r`n`r`n"
    $content = $newContent
    Write-Output "dashboard: Removed inline ServiceCard class"
} else {
    Write-Output "dashboard: WARNING - inline ServiceCard not found"
}

# 1c. Update service iteration to use config dicts
#     Replace: for svc in ["vllm","adapter","openclaw"]:
#              card = ServiceCard(svc) self._service_cards[svc]=card status_section.add(card)
$oldSvcLoop = 'for svc in ["vllm", "adapter", "openclaw"]:' + "`r`n" +
              '            card = ServiceCard(svc)' + "`r`n" +
              '            self._service_cards[svc] = card' + "`r`n" +
              '            status_section.add(card)'
$newSvcLoop = @'
        svc_configs = [
            {"name": "vllm", "desc": "vLLM 推理服务", "port": 8000},
            {"name": "adapter", "desc": "适配器服务", "port": 9000},
            {"name": "openclaw", "desc": "OpenClaw 工具服务", "port": 8765},
        ]
        for cfg in svc_configs:
            card = ServiceCard(cfg)
            name = cfg["name"]
            self._service_cards[name] = card
            status_section.add(card)
'@
$content = $content -replace [regex]::Escape($oldSvcLoop), $newSvcLoop
Write-Output "dashboard: Updated service iteration to use config dicts"

# 1d. Update _start_all to avoid self._service_cards dict change during iteration
$oldStart = @'
        for name in self._service_cards:
            ServiceStore.write_command("start", name)
            self._service_cards[name].update_status("starting")
'@
$newStart = @'
        for name in list(self._service_cards.keys()):
            ServiceStore.write_command("start", name)
            self._service_cards[name].update_status("starting")
'@
$content = $content -replace [regex]::Escape($oldStart), $newStart
Write-Output "dashboard: Updated _start_all iteration"

[System.IO.File]::WriteAllText($dash, $content, $utf8)
Write-Output "dashboard: Done"

# ── 2. Fix services.py ──
$svc = "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\services.py"
$content = [System.IO.File]::ReadAllText($svc, $utf8)

# 2a. Add import for ServiceCard from shared module
$oldImport = "from skia_gui.service_store import ServiceStore"
$newImport = "from skia_gui.service_card import ServiceCard`r`nfrom skia_gui.service_store import ServiceStore"
$content = $content -replace [regex]::Escape($oldImport), $newImport
Write-Output "services: Added shared ServiceCard import"

# 2b. Remove inline STATUS_MAP (match from ^STATUS_MAP to closing })
$pattern = '(?sm)^STATUS_MAP = \{.*?^\s*\}'
$newContent = $content -replace $pattern, ''
if ($newContent -ne $content) {
    $content = $newContent -replace '(?m)^(\s*)$\r?\n(?:\r?\n)+', "`$1`r`n`r`n"
    Write-Output "services: Removed inline STATUS_MAP"
} else {
    Write-Output "services: WARNING - STATUS_MAP not found"
}

# 2c. Remove inline ServiceCard class
$pattern = '(?sm)^class ServiceCard\(Container\):.*?^(?=class )'
$newContent = $content -replace $pattern, ''
if ($newContent -ne $content) {
    $content = $newContent -replace '(?m)^(\s*)$\r?\n(?:\r?\n)+', "`$1`r`n`r`n"
    Write-Output "services: Removed inline ServiceCard class"
} else {
    Write-Output "services: WARNING - inline ServiceCard not found"
}

[System.IO.File]::WriteAllText($svc, $content, $utf8)
Write-Output "services: Done"

Write-Output "=== Done ==="
