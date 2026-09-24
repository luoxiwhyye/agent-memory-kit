<#
.SYNOPSIS
    在目标项目里初始化「AI 记忆体系」骨架（AGENTS.md + .agents/memory/）。

.DESCRIPTION
    骨架源：  <本仓库>\memory-template\
    目标位置：<目标项目>\AGENTS.md 与 <目标项目>\.agents\memory\

    与 install.ps1 的关键差异：**记忆文件一旦被填写就是用户内容，绝不覆盖**。
    本脚本只补「目标里缺的文件」，已存在的一律跳过（幂等）。

    同时会把以下三行补进目标项目的 .gitignore（已存在则不动）：
        /AGENTS.md        ← 本文件
        .agents           ← 记忆目录
        .clineignore      ← Cline 的本机忽略规则文件（由 Cline 使用，本脚本不创建它）

    为什么默认不进库：这些是**本机 AI 约定**，通常不应出现在给别人 clone 的公共仓库里；
    而两个 agent 都读得到（它们是文件读取，不受 gitignore 影响）。
    若你希望它们入库，跑完把这几行从 .gitignore 删掉即可。

.PARAMETER Path
    目标项目根目录。默认当前目录。

.PARAMETER Project
    项目名，用于替换模板里的 {{PROJECT}}。默认取目标目录名。

.PARAMETER List
    只预览将要发生的变更，不写任何文件。

.EXAMPLE
    pwsh -File init-memory.ps1 -Path D:\code\MyApp -Project MyApp
    pwsh -File init-memory.ps1 -List

.NOTES
    ⚠️ 本脚本**不会** git add / commit。是否把 .gitignore 的改动提交由你自己决定。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path = '.',
    [string]$Project,
    [switch]$List
)

$ErrorActionPreference = 'Stop'

$TemplateRoot = Join-Path $PSScriptRoot 'memory-template'
$IgnoreLines = @('/AGENTS.md', '.agents', '.clineignore')

function Write-Step($msg) { Write-Host $msg }
function Write-Item($tag, $rel) {
    $color = switch ($tag) { '+' { 'Green' } '=' { 'DarkGray' } '~' { 'Yellow' } default { 'Gray' } }
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
Write-Host ''

$files = Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File
$added = 0
$skipped = 0

foreach ($f in $files) {
    $rel = $f.FullName.Substring($TemplateRoot.Length).TrimStart('\', '/')
    $dst = Join-Path $TargetRoot $rel

    if (Test-Path -LiteralPath $dst) {
        Write-Item '=' $rel
        $skipped++
        continue
    }

    Write-Item '+' $rel
    $added++

    if ($List) { continue }
    if (-not $PSCmdlet.ShouldProcess($dst, '写入模板')) { continue }

    $parent = Split-Path -Parent $dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $text = [IO.File]::ReadAllText($f.FullName)
    $text = $text.Replace('{{PROJECT}}', $Project)
    # 无 BOM（避免某些工具把 BOM 当正文）
    [IO.File]::WriteAllText($dst, $text, [Text.UTF8Encoding]::new($false))
}

# ---------- .gitignore ----------
$gitignorePath = Join-Path $TargetRoot '.gitignore'
$missing = @()
if (Test-Path -LiteralPath $gitignorePath) {
    $existing = [IO.File]::ReadAllText($gitignorePath)
    foreach ($line in $IgnoreLines) {
        $escaped = [regex]::Escape($line)
        if ($existing -notmatch "(?m)^\s*$escaped\s*$") { $missing += $line }
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

# ---------- 汇总 ----------
Write-Host ''
if ($List) {
    Write-Host "（-List 模式，未写入任何文件）待新增：$added 个文件（跳过已存在 $skipped 个）。" -ForegroundColor Yellow
} else {
    if ($added -eq 0) {
        Write-Host "无新增（$skipped 个文件已存在，未覆盖）。幂等：重复执行无副作用。" -ForegroundColor Green
    } else {
        Write-Host "完成：新增 $added 个文件，跳过已存在 $skipped 个（未覆盖）。" -ForegroundColor Green
    }
    Write-Host ''
    Write-Host '下一步：' -ForegroundColor Cyan
    Write-Host '  1. 填 AGENTS.md 的「结构与启动」「高频铁律」两节（其余留给使用时逐步补）。'
    Write-Host '  2. 重载 VS Code 窗口（Developer: Reload Window），让两个 agent 发现 AGENTS.md。'
    Write-Host '  3. 确认 Cline 能读到：新开会话问「你加载到了哪些规则文件」。'
    Write-Host '     若读不到，检查 Cline 的本机忽略规则文件 .clineignore 是否排除了 AGENTS.md（本脚本不创建它）。'
}
