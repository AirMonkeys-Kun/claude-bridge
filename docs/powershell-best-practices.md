# PowerShell 5 桥接项目最佳实践

> 基于 Bridge 项目实战中踩过的坑 + 官方文档 + 社区经验整理。
> 后续修 bug、重构、写新模块之前，先过一遍这份文档。

---

## 目录

1. [文件编码：UTF-8 BOM](#1-文件编码utf-8-bom)
2. [模块写作（.psm1）](#2-模块写作psm1)
3. [Hashtable vs PSCustomObject](#3-hashtable-vs-pscustomobject)
4. [函数定义与作用域](#4-函数定义与作用域)
5. [${function:Name} 编译期绑定陷阱](#5-functionname-编译期绑定陷阱)
6. [Try/Catch 行为](#6-trycatch-行为)
7. [文件 I/O 编码](#7-文件-io-编码)
8. [变量作用域：$script: / $global: / 模块作用域](#8-变量作用域script--global--模块作用域)
9. [比较运算符与类型混用](#9-比较运算符与类型混用)
10. [数组与 += 操作](#10-数组与--操作)
11. [HashTable 枚举中修改](#11-hashtable-枚举中修改)
12. [错误处理模式](#12-错误处理模式)

---

## 1. 文件编码：UTF-8 BOM

### 规则
**PowerShell 5 读取 .psm1 / .ps1 文件时，如果没有 BOM，默认按 ANSI（Windows-1252）解码。** 包含中文的文件必须保存为 **UTF-8 with BOM**。

### 为什么会炸
```powershell
# 文件保存为 UTF-8 WITHOUT BOM
# 包含中文字符：不是内部或外部命令
```
PowerShell 5 按 ANSI 读取 → 多字节中文字符被错误拆分为两个 ANSI 字符 → 字符串长度变化 → 正则匹配、字符串比较全部错位 → 解析器报错。

### 正确的保存方式

**方案 A：用 .NET 写入（推荐）**
```powershell
$content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
$bom = [System.Text.Encoding]::UTF8.GetPreamble()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
$output = New-Object byte[] ($bom.Length + $bytes.Length)
[Array]::Copy($bom, 0, $output, 0, $bom.Length)
[Array]::Copy($bytes, 0, $output, $bom.Length, $bytes.Length)
[System.IO.File]::WriteAllBytes($path, $output)
```

**方案 B：PowerShell 5 用 `-Encoding UTF8`**
```powershell
# Out-File 默认是 UTF16 LE，必须要显式指定
$content | Out-File -Encoding UTF8 $path

# Set-Content -Encoding UTF8 也会加 BOM
$content | Set-Content -Encoding UTF8 $path
```

**方案 C：不需要 BOM 时用 `[System.Text.UTF8Encoding]::new($false)`**
```powershell
$utf8NoBom = [System.Text.Encoding]::UTF8.GetEncoding(65001)  # 等价无 BOM
# 或
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
```

### 检查文件是否有 BOM
```powershell
$bytes = [System.IO.File]::ReadAllBytes($path)
$hasBom = $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
```

---

## 2. 模块写作（.psm1）

### 规则
- 用 `function` 关键字定义导出函数
- 用 `Export-ModuleMember` 显式导出
- 不要在 .psm1 中使用 `${function:Name}` 引用函数（见第5节）

### 正确的模块结构
```powershell
# MyModule.psm1
function Init-MyModule {
    param([string]$Path)
    $script:moduleBaseDir = $Path
    return $true
}

function Do-Something {
    param([string]$Input)
    # 不能直接用 $script:xxx 访问主脚本变量
    # 必须通过 Init-MyModule 传入
    return "processed: $Input"
}

# 显式导出
Export-ModuleMember -Function @(
    'Init-MyModule',
    'Do-Something'
)
```

### 模块内辅助函数（不被导出）
```powershell
# 不放在 Export-ModuleMember 里就是私有的
function Internal-Helper {
    param([string]$Msg)
    # 只有模块内函数可以调用
}
```

### Import-Module -Force
```powershell
# 每次导入时强制重新加载，开发调试时使用
Import-Module (Join-Path $modulesDir "MyModule.psm1") -Force
```

---

## 3. Hashtable vs PSCustomObject

### 核心区别

| 特性 | HashTable `@{}` | PSCustomObject `[PSCustomObject]@{}` |
|------|----------------|--------------------------------------|
| 底层类型 | `System.Collections.Hashtable` | `System.Management.Automation.PSCustomObject` |
| 属性访问 | `$h["key"]` 或 `$h.key` | `$o.PropertyName` |
| ConvertFrom-Json 结果 | ❌ 不是 | ✅ 就是此类型 |
| 管道输出表格 | ❌ 显示为 Name/Value 对 | ✅ 正确显示列 |
| Export-Csv | ❌ 输出不可用 | ✅ 正确导出 |
| + 操作 | 添加键值对 | 添加属性 |

### 关键陷阱：混合类型数组

```powershell
# ConvertFrom-Json 返回 PSObject[]
$fromJson = '{"errors":[{"id":1}]}' | ConvertFrom-Json
$entry = @{id=2}  # 这是 HashTable

# 危险！混合类型数组
$fromJson.errors += $entry
# PowerShell 在某些操作（-eq, -match, ConvertTo-Json 对比）下会抛：
# "无法比较 System.Collections.Hashtable，因为其不是 IComparable"
```

**解决方案：统一使用 PSCustomObject**
```powershell
# ✅ 正确：用 PSCustomObject 创建
$entry = [PSCustomObject]@{
    id = 2
    name = "test"
}

# ✅ 这样加入 PSObject[] 数组就没问题
$fromJson.errors += $entry
```

### 判断当前类型
```powershell
$obj.GetType().Name
# Hashtable → 是 @{}
# PSCustomObject → 是 [PSCustomObject]@{}
```

### 何时用哪个

| 场景 | 用哪个 |
|------|--------|
| 快速键值查找（字典） | HashTable |
| 管道输出到 Format-Table / Export-Csv | PSCustomObject |
| 与 ConvertFrom-Json 结果混合操作 | PSCustomObject |
| 内部临时数据结构 | HashTable |
| JSON 序列化 | 两者都可，PSCustomObject 更稳定 |
| 需要保持属性顺序 | `[ordered]@{}` + `[PSCustomObject]` |

---

## 4. 函数定义与作用域

### 规则
- 始终使用 `function Name { param(...) ... }` 语法
- 不要使用 lambda/匿名函数方式定义顶级函数

### 函数定义位置影响
```powershell
# 在脚本顶部定义 → 全局可见
function Global-Func { param([string]$x) "hello $x" }

# 在 if 块内定义 → 只在 if 的作用域可见
if ($true) {
    function Inside-If { "I'm inside if" }
}
Inside-If  # 在 PowerShell 5 中，if 中的函数定义会泄漏到外层！
# 但其他块（foreach, while）可能不会
```

### param() 的注意事项
```powershell
# ✅ 正确
function Test {
    param([string]$Name, [int]$Count)
}

# ❌ 错误：反引号不能用于转义括号内的类型名
function Test {
    param(`[string`]`$Name)  # 解析错误！
}
```

---

## 5. ${function:Name} 编译期绑定陷阱

### 为什么会炸
`${function:Name}` 是 PowerShell 的**变量命名空间**语法。在**模块作用域**中，它在**编译期**（解析阶段）就绑定了函数引用，而不是在运行时查找。

```powershell
# ❌ 危险写法（在 .psm1 中）
function Invoke-Example {
    # 编译期绑定：可能绑定到错误的作用域
    & ${function:Helper-Func} "arg"
}

# ✅ 正确写法
function Invoke-Example {
    Helper-Func "arg"  # 运行时查找，按作用域链解析
}
```

### 什么时候会出问题
- 在 `.psm1` 文件（模块）中
- 在嵌套函数（函数内调用函数）中
- 当函数定义在被调用函数**之后**时

### 安全的跨上下文函数调用
```powershell
# ✅ 推荐：直接用函数名
function A { B "hello" }
function B { param($x) $x }

# ✅ 或通过变量传递
$fn = ${function:B}  # 只在定义时绑定，不是引用
function A { & $fn "hello" }

# ✅ 或通过 Get-Command
function A {
    $cmd = Get-Command "B" -ErrorAction SilentlyContinue
    if ($cmd) { & $cmd "hello" }
}
```

---

## 6. Try/Catch 行为

### 嵌套 try/catch 的可靠性
```powershell
try {
    try {
        Some-Function  # 可能抛出异常
    } catch {
        # 这个 catch 能捕获大多数异常
        Log "Inner error: $($_.Exception.Message)"
    }
    # 这里的代码只在没有异常时执行
} catch {
    Log "Outer error: $($_.Exception.Message)"
}
```

### 边界情况
- **`$ErrorActionPreference = "Stop"`**：将非终止错误转为终止错误，可能导致内层 try/catch 失效
- **`CheckActionPreference`**：PowerShell 在某些运行时错误中会调用 `ExceptionHandlingOps.CheckActionPreference`，这可能导致异常穿透内层 try/catch

### safe 模式
```powershell
# 最安全：内层 catch 即使自己失败也不影响外层
try {
    try {
        Risky-Operation
    } catch {
        # catch 块本身也要安全
        try { Log "Error: $($_.Exception.Message)" } catch {}
    }
} catch {
    # 万一内层 catch 还有漏网之鱼
    Log "UNEXPECTED: $($_.Exception.Message)"
}
```

### 每条 inflight 记录独立处理
```powershell
# ✅ 正确：每个 item 独立 try/catch
foreach ($item in $items) {
    try {
        Process-Item $item
    } catch {
        Log "Item $item failed: $($_.Exception.Message)"
        # 即使失败也继续处理下一条
    }
}

# ❌ 错误：一个失败会导致全部中断
foreach ($item in $items) {
    Process-Item $item  # 抛出异常 → foreach 中断
}
```

---

## 7. 文件 I/O 编码

### 读文件
```powershell
# .NET 方法：默认 UTF-8（无 BOM）
[System.IO.File]::ReadAllText($path)                    # UTF-8
[System.IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)  # 显式指定

# PowerShell cmdlet：默认 ANSI！
Get-Content $path                       # ❌ ANSI (PS5)
Get-Content $path -Encoding UTF8        # ✅ UTF-8
Get-Content $path -Raw -Encoding UTF8   # ✅ 整文件读取
```

### 写文件
```powershell
# .NET 方法
[System.IO.File]::WriteAllText($path, $content)                    # UTF-8 NoBOM
[System.IO.File]::WriteAllText($path, $content, [Text.Encoding]::UTF8)  # UTF-8 NoBOM
[System.IO.File]::AppendAllText($path, $content, [Text.Encoding]::UTF8) # 追加

# PowerShell cmdlet
$content | Out-File $path                # ❌ UTF-16 LE！
$content | Out-File $path -Encoding UTF8 # ✅ UTF-8 with BOM
$content | Set-Content $path -Encoding UTF8  # ✅ UTF-8 with BOM
```

### Bridge 项目推荐
```powershell
# 模块级别统一编码变量
$script:utf8 = [System.Text.UTF8Encoding]::new($false)  # UTF-8 No BOM

# 读
[System.IO.File]::ReadAllText($path, $script:utf8)

# 写
[System.IO.File]::WriteAllText($path, $content, $script:utf8)

# 追加
[System.IO.File]::AppendAllText($path, $content, $script:utf8)
```

---

## 8. 变量作用域：$script: / $global: / 模块作用域

### 作用域层级
```powershell
$global:var      # 全局，所有作用域可见
$script:var      # 脚本/模块级别，当前脚本/模块内所有函数可见
$local:var       # 当前作用域（默认）
$private:var     # 当前作用域，不向外泄露
```

### 模块中的 $script:
```powershell
# .psm1 文件中的 $script: 指的是模块作用域
$script:moduleDir = $null  # 模块内所有函数共享

function Init {
    param($Path)
    $script:moduleDir = $Path  # 初始化共享变量
}

function Do-Work {
    # 可以访问 $script:moduleDir
    Join-Path $script:moduleDir "data.json"
}
```

### 主脚本中的 $script:
```powershell
# watcher.ps1 中的 $script: 指的是脚本作用域
$script:baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:inflight = @{}
```

### 导入模块后的变量访问
```powershell
# 模块不能直接访问主脚本的 $script: 变量
# 必须通过函数参数传入
Import-Module MyModule.psm1 -Force
Init-MyModule -Path $script:baseDir  # 传入主脚本路径
```

---

## 9. 比较运算符与类型混用

### PowerShell -eq / -match / -in 行为

```powershell
# 字符串 -match 返回布尔值
"hello" -match "ell"      # → $true

# 数组 -match 返回匹配的元素
"a","b","c" -match "b"    # → @("b")  # 不是布尔值！

# 不同类型比较
42 -eq "42"               # → $true（自动类型转换）
$null -eq ""              # → $false
"" -eq $null              # → $false
```

### 典型陷阱：混合类型比较
```powershell
# 如果 $obj 是 HashTable，"not IComparable"
if ($hashTable -eq $another) { }  # 可能崩溃！

# 如果 $obj 是 PSObject，属性比较
if ($psObj.property -eq $value) { }  # ✅ 安全
```

### 安全模式
```powershell
# 对于不确定类型的变量，先检查
if ($obj -is [hashtable]) {
    # 用哈希表的方式访问
    $obj["key"]
} elseif ($obj -is [PSCustomObject]) {
    # 用属性的方式访问
    $obj.property
}
```

### $null 判断
```powershell
# 推荐：把 $null 放在左边
if ($null -eq $var) { }  # ✅
if ($var -eq $null) { }  # 也可以但可能触发类型转换

# 特别注意：数组为空不是 $null
$arr = @()
$null -eq $arr       # → $false
$arr.Count -eq 0     # → $true

# 安全的存在性检查
if ($var) { }         # 非 $null、非空、非 0、非 $false → true
if (-not $var) { }    # 取反
```

---

## 10. 数组与 += 操作

### 性能问题
```powershell
# ❌ 低效：每次 += 创建新数组
$result = @()
foreach ($item in $collection) {
    $result += $item  # 每次复制整个数组！
}

# ✅ 高效：用 ArrayList 或 List
[System.Collections.ArrayList]$list = @()
foreach ($item in $collection) {
    [void]$list.Add($item)
}

# ✅ 或直接用 PowerShell 集合
$list = [System.Collections.Generic.List[object]]::new()
foreach ($item in $collection) {
    $list.Add($item)
}
```

### 类型混杂的数组
```powershell
$arr = @()
$arr += "string"           # [string[]] → ok
$arr += @{key="value"}     # 混入 HashTable → ok
$arr += [PSCustomObject]@{p="v"}  # 混入 PSObject → ok

# 但如果 arr 被强类型约束
[string[]]$typed = @()
$typed += "string"         # ✅
$typed += 42               # 自动转 "42"
$typed += @{key="value"}   # ❌ 无法转换
```

---

## 11. HashTable 枚举中修改

### 禁止模式
```powershell
$ht = @{a=1; b=2; c=3}

# ❌ 错误：枚举过程中修改
foreach ($key in $ht.Keys) {
    if ($condition) { $ht.Remove($key) }  # 运行时异常！
}
```

### 正确模式
```powershell
# ✅ 先把要移除的收集起来，完了再移除
$toRemove = @()
foreach ($key in $ht.Keys) {
    if ($condition) { $toRemove += $key }
}
foreach ($key in $toRemove) {
    $ht.Remove($key)
}

# ✅ 或者复制 Keys
foreach ($key in @($ht.Keys)) {
    if ($condition) { $ht.Remove($key) }
}
```

---

## 12. 错误处理模式

### 推荐的日志安全模式
```powershell
# 任何可能出错的代码都包 try/catch
try {
    Some-Operation
} catch {
    # catch 块内部也要安全
    try {
        Log "Error: $($_.Exception.Message)"
    } catch {
        # 日志失败也不能抛异常
    }
}
```

### 命令执行结果处理的推荐模式
```powershell
$toRemove = @()
foreach ($item in $items) {
    try {
        $result = Process-Item $item
        try {
            Log-Result $result  # 次要用 try/catch
        } catch {
            Log "Logging failed: $($_.Exception.Message)"
        }
        $toRemove += $item.Id
    } catch {
        Log "Item $item failed: $($_.Exception.Message)"
        # 即使失败也标记为已处理（避免阻塞队列）
        $toRemove += $item.Id
    }
}
# 清理
foreach ($id in $toRemove) { Remove-Item $id }
```

### New-CommandResult 模式（Bridge 项目）
```powershell
# 统一的结果对象
$result = New-CommandResult -CmdId $cid -ExitCode 0 -Stdout "OK"
Write-CommandResult -Result $result -Directory $script:baseDir
```

---

## 附录：Bridge 项目经验对照表

| 问题 | 文件 | 修复 PR/提交 |
|------|------|-------------|
| UTF-8 BOM 导致模块加载失败 | `BridgeRules.psm1` | 转为 UTF-8 with BOM |
| Hashtable 混入 PSObject 数组 | `BridgeRules.psm1` | `@{}` → `[PSCustomObject]@{}` |
| `param()` 内反引号转义 | `watcher.ps1` | 移除 ` 转义 |
| `${function:Name}` 作用域 | `BridgeRules.psm1` | 改为 `function` 关键字 + Export |
| 单条 inflight 崩溃阻塞清理 | `watcher.ps1` | 每条 item 独立 try/catch |
| `$script:lastCmdId` 预处理前赋值 | `watcher.ps1` | 移到预处理成功后 |
| 9P 缓存导致文件不同步 | VM 挂载 | 用 Read 工具而非 bash 读取 |
| Housekeeping 崩溃导致主循环停摆 | `watcher.ps1` | 每条 housekeeping 独立 try/catch |

---

> **最后更新**: 2026-06-06  
> **适用范围**: PowerShell 5.0 (Windows)  
> **参考**: [Microsoft PowerShell 5.0 文档](https://docs.microsoft.com/en-us/powershell/scripting/powershell-scripting?view=powershell-5.1)
