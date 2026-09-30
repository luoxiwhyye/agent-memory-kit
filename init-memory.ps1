<#
.SYNOPSIS
    在目标项目里初始化「AI 记忆体系」骨架（AGENTS.md + .agents/memory/）。

.DESCRIPTION
    骨架源：  <本仓库>\memory-template\
    目标位置：<目标项目>\AGENTS.md 与 <目标项目>\.agents\memory\

    ⚠️ 模板目录与目标布局**逐层对应**：AGENTS.md 落在项目根，其余全部在 .agents/ 下。
    模板结构本身就是目标结构（所以其它平台直接手工复制 memory-template/ 也是对的）。
    脚本会检查这一点，防止有人把模板改回扁平结构 —— 那会把记忆写到项目根目录，
    并绕过 .gitignore 里的 .agents/memory/ 规则（历史上真的发生过）。

    与 install.ps1 的关键差异：**记忆文件一旦被填写就是用户内容，绝不覆盖**。
    默认只补「目标里缺的文件」，已存在的一律跳过（幂等）。
    若目标已有同名文件且内容与模板不同，会单独列出来提示你手工合并
    （确实需要重置时用 -Force，脚本会先把原文件备份下来）。
    内容与模板相同的不算差异，不会被当作「冲突」报出来。

    本脚本只写目标项目内部，不碰全局的 ~/.agents/skills/ ——
    所以对多个项目分别执行，彼此不会冲突。

    忽略规则写在哪里由 `-IgnoreTarget` 决定（三种模式，规则内容相同）：
        /AGENTS.md              ← 入口文件
        .agents/memory/         ← 记忆目录（**不含 .agents/skills/**，仓库级 Skill 仍可入库）
        .clineignore            ← Cline 的本机忽略规则文件（由 Cline 使用，本脚本不创建它）

        gitignore（默认）：补进项目 `.gitignore`（随仓库走；别人 clone 也能看到这三行）
        exclude          ：补进 `.git/info/exclude`（**本机专用、永不入库**；换机器需重配一次）
        none             ：不写任何规则（自己管；`check-memory.ps1` 会提示「记忆可能被提交」）

    为什么默认不入库：这些是**本机 AI 约定**，通常不应出现在给别人 clone 的公共仓库里；
    而两个 agent 都读得到（它们是文件读取，不受 gitignore 影响）。

.PARAMETER Path
    目标项目根目录。默认当前目录。

.PARAMETER Project
    项目名，用于替换模板里的 {{PROJECT}}。默认取目标目录名。

.PARAMETER IgnoreTarget
    忽略规则写到哪里：`gitignore`（默认）/ `exclude` / `none`。见上文说明。

.PARAMETER IgnoreSkills
    额外把 `/.agents/skills/` 也写进忽略规则，并把理由写成注释（「仓库级 Skill 有意不入库，
    要共享就删这行或加 `!` 例外」）。第三方 Skill 包（带各自 LICENSE）不随仓库分发时用它。
    注意：它会让仓库级 Skill 一直不入库 —— 想共享时删掉那一行即可。

.PARAMETER List
    只预览将要发生的变更，不写任何文件。

.PARAMETER Force
    覆盖「已存在且内容与模板不同」的文件，覆盖前把原文件备份为 <文件名>.bak-<时间戳>。
    （与模板相同的不动、不备份。）
    ⚠️ 只在确知那些文件仍是模板原样时才用 —— 记忆填过内容就是你的资产。

.EXAMPLE
    pwsh -File init-memory.ps1 -Path D:\code\MyApp -Project MyApp
    pwsh -File init-memory.ps1 -IgnoreTarget exclude    # 规则只留本机，不入库
    pwsh -File init-memory.ps1 -List
    pwsh -File init-memory.ps1 -Force

.NOTES
    ⚠️ 本脚本**不会** git add / commit。是否把 .gitignore 的改动提交由你自己决定。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path = '.',
    [string]$Project,
    [ValidateSet('gitignore', 'exclude', 'none')]
    [string]$IgnoreTarget = 'gitignore',
    [switch]$IgnoreSkills,
    [switch]$List,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$TemplateRoot = Join-Path $PSScriptRoot 'memory-template'

# 当前推荐的忽略规则（精确到 memory/，不动 .agents/skills/）
$IgnoreLines = @('/AGENTS.md', '.agents/memory/', '.clineignore')
# -IgnoreSkills：把仓库级 Skill 也写进忽略（第三方 Skill 包不随仓库分发时用）
if ($IgnoreSkills) { $IgnoreLines += '.agents/skills/' }
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

# 模板布局守卫：必须含 .agents/memory/，且除 AGENTS.md 外不能有游离文件。
# 两种翻车方式都会导致「记忆被写到项目根目录」或「静默只创建一个 AGENTS.md」：
#   ① 模板被人改回扁平结构（knowledge/ 直接在模板根）；
#   ② .agents/ 被本仓库的 .gitignore 排除了 → 根本没提交进来，clone 后不自知。
$layoutRoot = Join-Path $TemplateRoot '.agents\memory'
$strayFiles = @()
foreach ($f in (Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($TemplateRoot.Length).TrimStart('\', '/')
    if ($rel -eq 'AGENTS.md') { continue }
    if (($rel -like '.agents\*') -or ($rel -like '.agents/*')) { continue }
    $strayFiles += $rel
}
$layoutBroken = (-not (Test-Path -LiteralPath $layoutRoot -PathType Container)) -or ($strayFiles.Count -gt 0)
if ($layoutBroken) {
    Write-Host '模板布局异常：骨架必须与目标布局逐层对应（AGENTS.md 在根，其余在 .agents/ 下）。' -ForegroundColor Red
    if (-not (Test-Path -LiteralPath $layoutRoot -PathType Container)) {
        Write-Host ("    缺少目录：{0}" -f $layoutRoot) -ForegroundColor Red
        Write-Host '    （常见原因：.agents/ 被 .gitignore 排除了，没提交进仓库）' -ForegroundColor Red
    }
    foreach ($s in $strayFiles) { Write-Host ("    游离文件：{0}" -f $s) -ForegroundColor Red }
    Write-Host '继续执行会把记忆写到**目标项目的根目录**，且不会被 .gitignore 忽略。' -ForegroundColor Red
    Write-Host '期望的结构：' -ForegroundColor Yellow
    Write-Host '    memory-template/AGENTS.md' -ForegroundColor Yellow
    Write-Host '    memory-template/.agents/memory/knowledge/*.md' -ForegroundColor Yellow
    Write-Host '    memory-template/.agents/memory/status/*.md' -ForegroundColor Yellow
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

$files = Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File -Force
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

# ---------- 忽略规则（-IgnoreTarget: gitignore | exclude | none） ----------
$gitignorePath = Join-Path $TargetRoot '.gitignore'
$excludePath = Join-Path $TargetRoot '.git\info\exclude'

# 过宽规则检查：两个文件都看（早期版本 / 手写过裸 .agents，会把 .agents/skills/ 一起忽略）
$overBroad = @()
foreach ($f in @($gitignorePath, $excludePath)) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $ln = 0
    foreach ($line in ([IO.File]::ReadAllText($f) -split "`r?`n")) {
        $ln++
        $t = $line.Trim()
        if ($OverBroadIgnore -contains $t) {
            $rel = $f.Substring($TargetRoot.Length).TrimStart('\', '/')
            $overBroad += ("{0}:{1}  {2}" -f $rel, $ln, $t)
        }
    }
}

function Get-MissingIgnoreLines($file) {
    $existing = ''
    if (Test-Path -LiteralPath $file) { $existing = [IO.File]::ReadAllText($file) }
    $miss = @()
    foreach ($line in $IgnoreLines) {
        $escaped = [regex]::Escape($line)
        if ($existing -notmatch ("(?m)^\s*" + $escaped + "\s*$")) { $miss += $line }
    }
    return $miss
}

if ($IgnoreTarget -eq 'none') {
    Write-Host ''
    Write-Step '  忽略规则：-IgnoreTarget none —— 不写任何规则'
    Write-Host '     记忆 / 入口不会被忽略：提交前自己确认（或跑 check-memory.ps1 看第 ⑥ 项）。' -ForegroundColor DarkGray
}
else {
    $targetFile = if ($IgnoreTarget -eq 'exclude') { $excludePath } else { $gitignorePath }
    $canWrite = $true
    if ($IgnoreTarget -eq 'exclude' -and -not (Test-Path -LiteralPath (Join-Path $TargetRoot '.git'))) {
        $canWrite = $false     # .git/info/exclude 只存在于 git 仓库里
    }
    $missing = Get-MissingIgnoreLines $targetFile
    Write-Host ''
    if (-not $canWrite) {
        Write-Host '  ! -IgnoreTarget exclude 需要先有 git 仓库（找不到 .git\info\）' -ForegroundColor Yellow
        Write-Host '    先 git init，或改用 -IgnoreTarget gitignore / none —— 本次不写任何文件。' -ForegroundColor DarkGray
    }
    elseif ($missing.Count -eq 0) {
        Write-Step ("  {0} 已含全部忽略规则（未改动）" -f (Split-Path $targetFile -Leaf))
    }
    else {
        Write-Step ("  {0} 将补入 {1} 行：" -f (Split-Path $targetFile -Leaf), $missing.Count)
        foreach ($line in $missing) { Write-Item '+' $line }
        if ($IgnoreTarget -eq 'exclude') {
            Write-Host '     注：.git/info/exclude 只对本机这份克隆生效 —— 换机器 / 新克隆要重配一次。' -ForegroundColor DarkGray
        }
        if (-not $List -and $PSCmdlet.ShouldProcess($targetFile, '追加忽略规则')) {
            $dir = Split-Path -Parent $targetFile
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $head = if ($IgnoreTarget -eq 'exclude') {
                '# ── 本机 AI 约定（仅本机生效，永不入库；换机器需各自重配） ──'
            }
            else {
                '# ── 本机 AI 约定（不入库；两个 agent 仍可读到） ──'
            }
            $lines = @($head)
            if ($IgnoreSkills) {
                $lines += '# 仓库级 Skill（.agents/skills/）有意不入库（第三方包 / 各自 LICENSE）；要共享就删这行或加 ! 例外'
            }
            $lines += $missing
            [IO.File]::AppendAllText($targetFile, ("`n" + ($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        }
    }
}

if ($overBroad.Count -gt 0) {
    Write-Host ''
    Write-Host ("  ⚠️ 忽略规则里有「过宽」的：{0}" -f (($overBroad | Select-Object -Unique) -join '  ')) -ForegroundColor Yellow
    Write-Host '     它会把整个 .agents/ 忽略掉，仓库级 Skill（.agents/skills/）就进不了库。' -ForegroundColor Yellow
    Write-Host '     建议把该行手工替换为：.agents/memory/（本脚本不自动改 —— 那是你的文件。）' -ForegroundColor DarkGray
}

# ---------- 骨架版本提示（目标 vs 当前模板；放在汇总之前，-List 也要看到） ----------
$tplAgents = Join-Path $TemplateRoot 'AGENTS.md'
$tplVersion = ''
if (Test-Path -LiteralPath $tplAgents) {
    $mv = [regex]::Match([IO.File]::ReadAllText($tplAgents), 'memory-skeleton:\s*(v[\w.]+)')
    if ($mv.Success) { $tplVersion = $mv.Groups[1].Value }
}
$dstAgents = Join-Path $TargetRoot 'AGENTS.md'
if ($tplVersion -and (Test-Path -LiteralPath $dstAgents)) {
    $mv2 = [regex]::Match([IO.File]::ReadAllText($dstAgents), 'memory-skeleton:\s*(v[\w.]+)')
    $dstVersion = if ($mv2.Success) { $mv2.Groups[1].Value } else { '' }
    Write-Host ''
    if ($dstVersion -eq '') {
        Write-Host ("  ℹ️ 目标 AGENTS.md 没有骨架版本标记（当前模板是 {0}）—— 早期版本或手工写的。" -f $tplVersion) -ForegroundColor DarkGray
        Write-Host ("     对照模板看有没有要补的：{0}" -f $tplAgents) -ForegroundColor DarkGray
        Write-Host '     迁移动作见 CHANGELOG.md 的「骨架」节。' -ForegroundColor DarkGray
    }
    elseif ($dstVersion -ne $tplVersion) {
        Write-Host ("  ℹ️ 骨架版本不同：目标 {0}，当前模板 {1} —— 模板已更新，可对照 diff 手工合并。" -f $dstVersion, $tplVersion) -ForegroundColor Yellow
        Write-Host ("     （本脚本不自动改你的记忆，只提示）模板：{0}" -f $tplAgents) -ForegroundColor DarkGray
        Write-Host '     迁移动作见 CHANGELOG.md 的「骨架」节。' -ForegroundColor DarkGray
    }
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
