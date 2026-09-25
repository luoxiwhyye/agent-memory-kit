<#
.SYNOPSIS
    在目标项目里初始化「AI 记忆体系」骨架（AGENTS.md + .agents/memory/）。

.DESCRIPTION
    骨架源：  <本仓库>\memory-template\
    目标位置：<目标项目>\AGENTS.md 与 <目标项目>\.agents\memory\

    与 install.ps1 的关键差异：**记忆文件一旦被填写就是用户内容，绝不覆盖**。
    默认只补「目标里缺的文件」，已存在的一律跳过（幂等）。
    若目标已有同名文件且内容与模板不同，会单独列出来提示你手工合并
    （确实需要重置时用 -Force，脚本会先把原文件备份下来）。
    内容与模板相同的不算差异，不会被当作「冲突」报出来。

    本脚本只写目标项目内部，不碰全局的 ~/.agents/skills/ ——
    所以对多个项目分别执行，彼此不会冲突。

    同时会把以下三个模式补进目标项目的 .gitignore（已存在则不动）：
        /AGENTS.md              ← 入口文件
        .agents/memory/         ← 记忆目录（**不含 .agents/skills/**）
        .clineignore            ← Cline 的本机忽略规则文件（由 Cline 使用，本脚本不创建它）

    为什么默认不入库：这些是**本机 AI 约定**，通常不应出现在给别人 clone 的公共仓库里；
    而两个 agent 都读得到（它们是文件读取，不受 gitignore 影响）。
    想让它们入库，把这几个模式从 .gitignore 删掉即可。

.PARAMETER Path
    目标项目根目录。默认当前目录。

.PARAMETER Project
    项目名，用于替换模板里的 {{PROJECT}}。默认取目标目录名。

.PARAMETER List
    只预览将要发生的变更，不写任何文件。

.PARAMETER Force
    覆盖「已存在且内容与模板不同」的文件，覆盖前把原文件备份为 <文件名>.bak-<时间戳>。
    （与模板相同的不动、不备份。）
    ⚠️ 只在确知那些文件仍是模板原样时才用 —— 记忆填过内容就是你的资产。

.EXAMPLE
    pwsh -File init-memory.ps1 -Path D:\code\MyApp -Project MyApp
    pwsh -File init-memory.ps1 -List
    pwsh -File init-memory.ps1 -Force

.NOTES
    ⚠️ 本脚本**不会** git add / commit。是否把 .gitignore 的改动提交由你自己决定。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path = '.',
    [string]$Project,
    [switch]$List,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$TemplateRoot = Join-Path $PSScriptRoot 'memory-template'

# 当前推荐的忽略规则（精确到 memory/，不动 .agents/skills/）
$IgnoreLines = @('/AGENTS.md', '.agents/memory/', '.clineignore')
# 早期版本写过、或用户手写的「过宽」规则：会把 .agents/skills/ 一起忽略掉
$OverBroadIgnore = @('.agents', '.agents/', '/.agents', '/.agents/')

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Step($msg) { Write-Host $msg }
function Write-Item($tag, $rel) {
    $color = switch ($tag) { '+' { 'Green' } '=' { 'DarkGray' } '~' { 'Yellow' } '!' { 'Red' } default { 'Gray' } }
    Write-Host ("  {0} {1}" -f $tag, $rel) -ForegroundColor $color
}

if (-not (Test-Path -LiteralPath $TemplateRoot)) {
    Write-Host "找不到模板目录：$TemplateRoot" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "目标目录不存在：$Path" -ForegroundColor Red
    exit 1
}
$TargetRoot = (Resolve-Path -LiteralPath $Path).Path

if (-not $Project) { $Project = Split-Path -Leaf $TargetRoot }
Write-Step ("项目：{0}" -f $Project)
Write-Step ("目标：{0}" -f $TargetRoot)
if ($Force) { Write-Host '模式：-Force（内容与模板不同的文件会被备份后覆盖）' -ForegroundColor Yellow }

Write-Host ''

$files = Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File
$added = 0
$skipped = 0
$conflicts = @()
$overwritten = @()

foreach ($f in $files) {
    $rel = $f.FullName.Substring($TemplateRoot.Length).TrimStart('\', '/')
    $dst = Join-Path $TargetRoot $rel
    $text = ([IO.File]::ReadAllText($f.FullName)).Replace('{{PROJECT}}', $Project)

    if (Test-Path -LiteralPath $dst) {
        # 与模板逐字相同 = 还是原样，标 '='（无需备份，也无需改写）；
        # 不同 = 你填过内容 → 标 '!' 并单独提示（-Force 下改为备份后覆盖）
        if (([IO.File]::ReadAllText($dst)) -eq $text) {
            Write-Item '=' $rel
            $skipped++
            continue
        }

        if (-not $Force) {
            Write-Item '!' $rel
            $conflicts += $rel
            $skipped++
            continue
        }

        Write-Item '~' $rel
        $overwritten += $rel
        if ($List) { continue }
        if (-not $PSCmdlet.ShouldProcess($dst, '备份后覆盖')) { continue }
        Copy-Item -LiteralPath $dst -Destination ("{0}.bak-{1}" -f $dst, $Stamp) -Force
    } else {
        Write-Item '+' $rel
        $added++
        if ($List) { continue }
        if (-not $PSCmdlet.ShouldProcess($dst, '写入模板')) { continue }
    }

    $parent = Split-Path -Parent $dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # 无 BOM（避免某些工具把 BOM 当正文）
    [IO.File]::WriteAllText($dst, $text, [Text.UTF8Encoding]::new($false))
}

# ---------- .gitignore ----------
$gitignorePath = Join-Path $TargetRoot '.gitignore'
$missing = @()
$overBroad = @()
if (Test-Path -LiteralPath $gitignorePath) {
    $existing = [IO.File]::ReadAllText($gitignorePath)
    foreach ($line in $IgnoreLines) {
        $escaped = [regex]::Escape($line)
        if ($existing -notmatch "(?m)^\s*$escaped\s*$") { $missing += $line }
    }
    foreach ($line in ($existing -split "`r?`n")) {
        $t = $line.Trim()
        if ($OverBroadIgnore -contains $t) { $overBroad += $t }
    }
} else {
    $missing = $IgnoreLines
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Step ("  .gitignore 将补入 {0} 行：" -f $missing.Count)
    foreach ($line in $missing) { Write-Item '+' $line }
    if (-not $List -and $PSCmdlet.ShouldProcess($gitignorePath, '追加忽略规则')) {
        $block = "`n# ── 本机 AI 约定（不入库；两个 agent 仍可读到） ──`n" + ($missing -join "`n") + "`n"
        [IO.File]::AppendAllText($gitignorePath, $block, [Text.UTF8Encoding]::new($false))
    }
} else {
    Write-Step '  .gitignore 已含全部忽略规则（未改动）'
}

if ($overBroad.Count -gt 0) {
    Write-Host ''
    Write-Host ("  ⚠️ .gitignore 里有过宽的规则：{0}" -f (($overBroad | Select-Object -Unique) -join '  ')) -ForegroundColor Yellow
    Write-Host '     它会把整个 .agents/ 忽略掉，仓库级 Skill（.agents/skills/）就进不了库。' -ForegroundColor Yellow
    Write-Host '     建议把该行手工替换为：.agents/memory/' -ForegroundColor Yellow
    Write-Host '     （本脚本不自动改 .gitignore —— 那是你的文件。）' -ForegroundColor DarkGray
}

# ---------- 汇总 ----------
Write-Host ''
if ($List) {
    $extra = ''
    if ($Force -and $overwritten.Count -gt 0) { $extra = "；-Force 将覆盖 $($overwritten.Count) 个（先备份）" }
    elseif ($conflicts.Count -gt 0) { $extra = "；其中 $($conflicts.Count) 个已存在且与模板不同（不会覆盖）" }
    Write-Host "（-List 模式，未写入任何文件）待新增：$added 个文件（跳过已存在 $skipped 个$extra）。" -ForegroundColor Yellow
    return
}

if ($Force) {
    Write-Host ("完成：新增 {0} 个，覆盖 {1} 个（原文件已备份为 *.bak-{2}），{3} 个与模板相同（未动）。" -f $added, $overwritten.Count, $Stamp, $skipped) -ForegroundColor Green
} elseif ($added -eq 0) {
    Write-Host "无新增（$skipped 个文件已存在，未覆盖）。幂等：重复执行无副作用。" -ForegroundColor Green
} else {
    Write-Host "完成：新增 $added 个文件，跳过已存在 $skipped 个（未覆盖）。" -ForegroundColor Green
}

if ($conflicts.Count -gt 0) {
    Write-Host ''
    Write-Host ("⚠️ {0} 个文件已存在且与模板不同 —— 已跳过，未覆盖：" -f $conflicts.Count) -ForegroundColor Yellow
    foreach ($c in $conflicts) { Write-Host ("     {0}" -f $c) -ForegroundColor Yellow }
    Write-Host '   它们填过内容就是你的资产，本脚本不碰。模板原文在：' -ForegroundColor DarkGray
    Write-Host ("     {0}" -f $TemplateRoot) -ForegroundColor DarkGray
    Write-Host '   → 手工对照合并用编辑器的 diff 视图；' -ForegroundColor DarkGray
    Write-Host '   → 确知可以安全重置时：pwsh -File init-memory.ps1 -Force（会先备份为 *.bak-<时间戳>）' -ForegroundColor DarkGray
    Write-Host '   注意：若你的 AGENTS.md 是项目原有的（不是本骨架生成的），' -ForegroundColor DarkGray
    Write-Host '         更推荐把骨架的「记忆分两层」与「三问」两节手工并入它，而不是整体替换。' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '下一步：' -ForegroundColor Cyan
Write-Host '  1. 填 AGENTS.md 的「结构与启动」「高频铁律」两节（其余留给使用时逐步补）。'
Write-Host '  2. 重载 VS Code 窗口（Developer: Reload Window），让两个 agent 发现 AGENTS.md。'
Write-Host '  3. 确认 Cline 能读到：新开会话问「你加载到了哪些规则文件」。'
Write-Host '     若读不到，检查 Cline 的本机忽略规则文件 .clineignore 是否排除了 AGENTS.md（本脚本不创建它）。'
