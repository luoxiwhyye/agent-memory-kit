<#
.SYNOPSIS
    只读校验「AI 记忆体系」（AGENTS.md + .agents/memory/）的结构、新鲜度与忽略规则。

.DESCRIPTION
    把 memory-hygiene 的判据变成**可执行判据** —— 建议在「会话开始时」或「改动记忆后」跑一次。
    三个脚本的分工：

        init-memory.ps1    建骨架（每个项目一次）
        install.ps1        部署 Skill（改 Skill 后重跑；`-Check` 只比哈希）
        check-memory.ps1   **日常回归**：骨架有没有烂（本脚本）

    ⚠️ 默认**只读** —— 不修改任何被检查的文件。
    唯一会写盘的是 `-Backup`（快照写进记忆目录下的 `.backup/`，天然被忽略规则覆盖）。

    退出码：0 = 无错误（可能有警告）；1 = 有错误；2 = 没找到记忆骨架。

.PARAMETER Path
    目标项目根目录。默认当前目录。

.PARAMETER MaxAgentsLines
    AGENTS.md 行数上限。默认 100 —— kit 的建议值（它每次对话都会被加载）。

.PARAMETER StaleDays
    status/ 的过期阈值（天）。默认 7，与 session-resume 的过期提示保持一致。

.PARAMETER Backup
    检查前先把 AGENTS.md 与 .agents/memory/ 快照到 `.agents/memory/.backup/<yyyyMMdd-HHmmss>/`。
    快照放在 memory/ 内部是为了**天然被忽略**（`.agents/memory/` 规则覆盖它）；脚本仍会验证一次。

.PARAMETER KeepBackups
    保留最近几份快照（默认 5），更旧的删掉。只在 `-Backup` 时生效。

.PARAMETER Strict
    把「警告」也当作失败（退出码 1）。默认警告不改变退出码。

.EXAMPLE
    pwsh -File check-memory.ps1 -Path D:\code\MyApp

.EXAMPLE
    pwsh -File check-memory.ps1 -Backup        # 整理记忆前先快照（-Backup 是唯一的写操作）

.EXAMPLE
    pwsh -File check-memory.ps1 -Strict        # 收尾 / CI 用：有警告也算失败

.NOTES
    只检查「机械可判定」的项。**内容对不对仍要靠人** —— 那部分归 memory-hygiene。
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [int]$MaxAgentsLines = 100,
    [int]$StaleDays = 7,
    [switch]$Backup,
    [int]$KeepBackups = 5,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$Script:Fail = 0
$Script:Warn = 0
$Script:Ok = 0

function Write-Head($n, $title) { Write-Host ''; Write-Host ("[{0}/9] {1}" -f $n, $title) -ForegroundColor Cyan }
function Write-Ok($msg) { $Script:Ok++; Write-Host ("   OK    " + $msg) -ForegroundColor Green }
function Write-Warn2($msg) { $Script:Warn++; Write-Host ("   WARN  " + $msg) -ForegroundColor Yellow }
function Write-Fail($msg) { $Script:Fail++; Write-Host ("   FAIL  " + $msg) -ForegroundColor Red }
function Write-Note($msg) { Write-Host ("         " + $msg) -ForegroundColor DarkGray }

$TargetRoot = (Resolve-Path -LiteralPath $Path).Path
$AgentsPath = Join-Path $TargetRoot 'AGENTS.md'
$MemoryRoot = Join-Path $TargetRoot '.agents\memory'
$KnowledgeDir = Join-Path $MemoryRoot 'knowledge'
$StatusDir = Join-Path $MemoryRoot 'status'
$BackupRoot = Join-Path $MemoryRoot '.backup'

function Read-Text($p) { return [IO.File]::ReadAllText($p) }
function Get-RelPath($p) { return $p.Substring($TargetRoot.Length).TrimStart('\', '/') }
function Get-NonBmpCount($text) { return [regex]::Matches($text, '[\uD800-\uDBFF]').Count }
# 记忆文件清单（排除 .backup/：它是快照，不是记忆本体）
function Get-MemoryFiles {
    $out = @()
    foreach ($d in @($KnowledgeDir, $StatusDir)) {
        if (Test-Path -LiteralPath $d) {
            $out += Get-ChildItem -LiteralPath $d -File -Filter *.md -Recurse |
                Where-Object { $_.FullName -notmatch '\\\.backup\\' }
        }
    }
    return $out
}

# 仓库内「文件名 -> 相对路径」索引（解析不带目录的引用用；跳过重目录，上限 2 万文件）
# 注意：记忆文件通常**不入库**，所以不能只看 git ls-files，必须走文件系统。
$Script:RepoIndex = $null
function Get-RepoIndex {
    if ($null -ne $Script:RepoIndex) { return $Script:RepoIndex }
    $skip = @('node_modules', '.git', 'dist', 'build', '.next', '.nuxt', 'target', '.venv', 'venv', '__pycache__', '.cache', 'coverage', 'out')
    $idx = @{}
    $stack = New-Object System.Collections.Stack
    $stack.Push($TargetRoot)
    $count = 0
    while ($stack.Count -gt 0 -and $count -lt 20000) {
        $d = $stack.Pop()
        $items = @()
        try { $items = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction Stop) } catch { continue }
        foreach ($it in $items) {
            if ($it.PSIsContainer) {
                if ($skip -notcontains $it.Name) { $stack.Push($it.FullName) }
            }
            else {
                $count++
                $k = $it.Name.ToLower()
                if (-not $idx.ContainsKey($k)) { $idx[$k] = @() }
                $idx[$k] = $idx[$k] + (Get-RelPath $it.FullName)
            }
        }
    }
    $Script:RepoIndex = $idx
    return $idx
}

# 取某字符位置所在的行（判断引用是否处在「不存在 / 已删」这类否定语境里）
function Get-LineAt($text, $pos) {
    $start = $text.LastIndexOf("`n", [Math]::Max(0, $pos - 1))
    $end = $text.IndexOf("`n", $pos)
    if ($end -lt 0) { $end = $text.Length }
    if ($start -lt 0) { $start = 0 } else { $start++ }
    return $text.Substring($start, $end - $start)
}

# 判断文件里是否有「实质内容」（去掉标题 / 引用 / 注释 / 空行后还剩东西）
# 用途：新骨架的 status 文件仍是模板原样时，不必拿「没写日期」去告警。
function Test-HasSubstantive($text) {
    $inComment = $false
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $inComment -and $l.Contains('<!--')) {
            if (-not $l.Contains('-->')) { $inComment = $true }
            continue
        }
        if ($inComment) {
            if ($l.Contains('-->')) { $inComment = $false }
            continue
        }
        if ($l -eq '' -or $l.StartsWith('#') -or $l.StartsWith('>')) { continue }
        return $true
    }
    return $false
}

$hasAgents = Test-Path -LiteralPath $AgentsPath
$hasMemory = Test-Path -LiteralPath $MemoryRoot

$gitOk = $false
if (Get-Command git -ErrorAction SilentlyContinue) {
    $null = & git -C $TargetRoot rev-parse --is-inside-work-tree 2>$null
    $gitOk = ($LASTEXITCODE -eq 0)
}

# 项目级门槛覆盖：AGENTS.md 里写 <!-- memory-check: max-agents-lines=130 -->（可选，也可写 stale-days=N）
$effMaxLines = $MaxAgentsLines
$effStaleDays = $StaleDays
$overrideNote = ''
if ($hasAgents) {
    $agentsHead = Read-Text $AgentsPath
    $mo = [regex]::Match($agentsHead, 'memory-check:\s*max-agents-lines\s*=\s*(\d+)')
    if ($mo.Success) {
        $effMaxLines = [int]$mo.Groups[1].Value
        $overrideNote = ("（项目自定 max-agents-lines={0}）" -f $effMaxLines)
    }
    $mo2 = [regex]::Match($agentsHead, 'memory-check:\s*stale-days\s*=\s*(\d+)')
    if ($mo2.Success) { $effStaleDays = [int]$mo2.Groups[1].Value }
}

Write-Host ("check-memory（只读）   目标：{0}" -f $TargetRoot) -ForegroundColor White
Write-Host ("  阈值：AGENTS.md <= {0} 行{3}；status 过期 > {1} 天；git = {2}" -f $effMaxLines, $effStaleDays, $(if ($gitOk) { '可用' } else { '不可用（跳过入库类检查）' }), $overrideNote) -ForegroundColor DarkGray

if (-not $hasAgents -and -not $hasMemory) {
    Write-Host ''
    Write-Host '本项目没有记忆骨架（既没有 AGENTS.md，也没有 .agents/memory/）—— 无需检查。' -ForegroundColor Yellow
    Write-Host ("  需要的话：pwsh -File <kit路径>\init-memory.ps1 -Path `"{0}`"" -f $TargetRoot) -ForegroundColor DarkGray
    exit 2
}

# 骨架版本（P2-11）：目标 vs kit 模板（模板版本只有脚本，没有网络请求）
$tplAgents = Join-Path $PSScriptRoot 'memory-template\AGENTS.md'
$tplVer = ''
if (Test-Path -LiteralPath $tplAgents) {
    $mv = [regex]::Match((Read-Text $tplAgents), 'memory-skeleton:\s*(v[\w.]+)')
    if ($mv.Success) { $tplVer = $mv.Groups[1].Value }
}
$dstVer = ''
if ($hasAgents) {
    $mv2 = [regex]::Match((Read-Text $AgentsPath), 'memory-skeleton:\s*(v[\w.]+)')
    if ($mv2.Success) { $dstVer = $mv2.Groups[1].Value }
}
if ($tplVer -ne '' -or $dstVer -ne '') {
    $showTpl = if ($tplVer -eq '') { '（模板无标记）' } else { $tplVer }
    $showDst = if ($dstVer -eq '') { '（无标记：早期版本或手工写的）' } else { $dstVer }
    if ($dstVer -ne '' -and $tplVer -ne '' -and $dstVer -ne $tplVer) {
        Write-Host ("  骨架版本：目标 {0}，kit 模板 {1} —— 模板已更新，建议对照 diff 手工合并。" -f $showDst, $showTpl) -ForegroundColor Yellow
    }
    else {
        Write-Host ("  骨架版本：目标 {0}，kit 模板 {1}" -f $showDst, $showTpl) -ForegroundColor DarkGray
    }
}

# ---------- -Backup：唯一的写操作，放在检查之前（快照 = 检查前的状态） ----------
$backupResult = ''
if ($Backup) {
    if (-not $hasMemory) {
        $backupResult = '跳过：没有 .agents/memory/，无可备份'
    }
    else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dest = Join-Path $BackupRoot $stamp
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $n = 0
        if ($hasAgents) {
            Copy-Item -LiteralPath $AgentsPath -Destination (Join-Path $dest 'AGENTS.md') -Force
            $n++
        }
        foreach ($f in Get-MemoryFiles) {
            $rel = $f.FullName.Substring($MemoryRoot.Length).TrimStart('\', '/')
            $out = Join-Path $dest $rel
            $parent = Split-Path -Parent $out
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $out -Force
            $n++
        }
        # 只保留最近 KeepBackups 份（只删 .backup/ 下由本脚本建立的目录）
        $pruned = 0
        if ($KeepBackups -gt 0) {
            $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending)
            foreach ($d in @($dirs | Select-Object -Skip $KeepBackups)) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force
                $pruned++
            }
        }
        $ignoredNote = ''
        if ($gitOk) {
            $null = & git -C $TargetRoot check-ignore -q -- ('.agents/memory/.backup/' + $stamp) 2>$null
            if ($LASTEXITCODE -ne 0) { $ignoredNote = '  ⚠ 快照目录没有被忽略，请写进 .gitignore 或 .git/info/exclude' }
        }
        $backupResult = ("快照 .agents/memory/.backup/{0}（{1} 个文件；清理旧快照 {2} 份；保留 {3} 份）{4}" -f $stamp, $n, $pruned, $KeepBackups, $ignoredNote)
    }
}

# ---------- ① 索引表 ↔ knowledge/ · status/ 一对一 ----------
Write-Head 1 '索引表 ↔ knowledge/ · status/ 一对一（指向不存在的文件 = 下次读到空）'
$agentsText = ''
if ($hasAgents) { $agentsText = Read-Text $AgentsPath }
if (-not $hasAgents) { Write-Fail 'AGENTS.md 不存在 —— 入口缺失，agent 读不到任何规则' }
if (-not $hasMemory) { Write-Fail '.agents/memory/ 不存在 —— 记忆目录缺失' }
if ($hasAgents -and $hasMemory) {
    # AGENTS.md 里被反引号包起来的「裸文件名」视为索引声明（带路径的引用交给检查 ⑤）
    $declared = @{}
    foreach ($m in [regex]::Matches($agentsText, '`([A-Za-z0-9._\-]+\.md)`')) { $declared[$m.Groups[1].Value.ToLower()] = $m.Groups[1].Value }
    $onDisk = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $KnowledgeDir -File -Filter *.md -ErrorAction SilentlyContinue)) { $onDisk[$f.Name.ToLower()] = (Get-RelPath $f.FullName) }
    foreach ($f in @(Get-ChildItem -LiteralPath $StatusDir -File -Filter *.md -ErrorAction SilentlyContinue)) { $onDisk[$f.Name.ToLower()] = (Get-RelPath $f.FullName) }

    $notIndexed = @()
    foreach ($k in @($onDisk.Keys)) { if (-not $declared.ContainsKey($k)) { $notIndexed += $onDisk[$k] } }
    $dangling = @()
    $repoIdx = Get-RepoIndex
    foreach ($k in @($declared.Keys)) {
        if ($onDisk.ContainsKey($k)) { continue }
        if ($repoIdx.ContainsKey($k) -and $repoIdx[$k].Count -gt 0) { continue }  # 仓库里的普通文档，不是记忆条目
        $dangling += $declared[$k]
    }
    if ($notIndexed.Count -gt 0) {
        Write-Fail ("{0} 个记忆文件没有被 AGENTS.md 索引：{1}" -f $notIndexed.Count, ($notIndexed -join '、'))
        Write-Note '索引表与 knowledge/ 必须一对一 —— 否则 agent 不知道「什么时候去读它」'
    }
    if ($dangling.Count -gt 0) {
        Write-Fail ("AGENTS.md 引用了 {0} 个不存在的文件：{1}" -f $dangling.Count, ($dangling -join '、'))
        Write-Note '索引指向不存在的文件 = 下次读到空'
    }
    if ($notIndexed.Count -eq 0 -and $dangling.Count -eq 0) {
        Write-Ok ("索引表与磁盘一致（记忆文件 {0} 个：{1}）" -f $onDisk.Count, (($onDisk.Values | Sort-Object) -join '、'))
    }
}

# ---------- ② AGENTS.md 行数上限 ----------
Write-Head 2 ("AGENTS.md 行数上限（<= {0} 行：它每次对话都会被加载）" -f $effMaxLines)
if (-not $hasAgents) { Write-Warn2 'AGENTS.md 不存在，跳过' }
else {
    $lineCount = (Get-Content -LiteralPath $AgentsPath).Count
    if ($lineCount -gt $effMaxLines) {
        Write-Warn2 ("AGENTS.md {0} 行 > 建议的 {1} 行 —— 细则推到 knowledge/ 子文件，入口只留一行摘要；若项目有意放宽，用 -MaxAgentsLines 或文件里的 <!-- memory-check: max-agents-lines=N --> 上调门槛" -f $lineCount, $effMaxLines)
    }
    else { Write-Ok ("AGENTS.md {0} 行（上限 {1}）" -f $lineCount, $effMaxLines) }
}

# ---------- ③ 非 BMP 字符 ----------
Write-Head 3 '非 BMP 字符（长会话被截断会留下孤立代理 -> 请求 400）'
$scanFiles = @()
if ($hasAgents) { $scanFiles += Get-Item -LiteralPath $AgentsPath }
$scanFiles += Get-MemoryFiles
$badFiles = 0
foreach ($f in $scanFiles) {
    $c = Get-NonBmpCount (Read-Text $f.FullName)
    if ($c -gt 0) {
        $badFiles++
        Write-Fail ("{0} 有 {1} 个非 BMP 字符（代理对）—— 换成 ● ○ ■ ★ ▲ -> 这类单码元符号" -f (Get-RelPath $f.FullName), $c)
    }
}
if ($scanFiles.Count -eq 0) { Write-Warn2 '没有可扫描的记忆文件' }
elseif ($badFiles -eq 0) { Write-Ok ("{0} 个记忆文件全部在 BMP 内（无代理对）" -f $scanFiles.Count) }

# ---------- ④ status/ 新鲜度 ----------
Write-Head 4 ("status/ 新鲜度（>{0} 天未更新 / 已闭环未清理）" -f $effStaleDays)
$statusFiles = @()
if (Test-Path -LiteralPath $StatusDir) {
    $statusFiles = @(Get-ChildItem -LiteralPath $StatusDir -File -Filter *.md -Recurse | Where-Object { $_.FullName -notmatch '\\\.backup\\' })
}
if ($statusFiles.Count -eq 0) {
    Write-Warn2 'status/ 为空或不存在 —— 手头没有在手任务时这是正常状态（闭环后当天删）'
}
else {
    foreach ($f in $statusFiles) {
        $t = Read-Text $f.FullName
        $rel = Get-RelPath $f.FullName
        if ($t -match '(?m)^\s*[-*]?\s*状态\s*[:：]\s*已闭环') {
            Write-Warn2 ("{0} 的「状态」字段是「已闭环」—— status 只写「此刻」，闭环后当天删（拿不准就压成一行指针）" -f $rel)
        }
        $ds = @([regex]::Matches($t, '(20\d{2})-(\d{2})-(\d{2})'))
        if ($ds.Count -eq 0) {
            if (-not (Test-HasSubstantive $t)) {
                Write-Note ("{0} 还是模板原样（未填写）—— 开始写内容时记得补一行「更新时间: yyyy-MM-dd」" -f $rel)
            }
            else {
                Write-Warn2 ("{0} 里找不到日期 —— 建议写一行「更新时间: yyyy-MM-dd」" -f $rel)
            }
            continue
        }
        $newest = $null
        foreach ($d in $ds) {
            $v = [datetime]::ParseExact($d.Value, 'yyyy-MM-dd', $null)
            if ($null -eq $newest -or $v -gt $newest) { $newest = $v }
        }
        $days = [int](((Get-Date).Date - $newest.Date).TotalDays)
        if ($days -gt $effStaleDays) {
            Write-Warn2 ("{0} 最后更新 {1}（{2} 天前 > {3} 天）—— 恢复 / 接手前先核对是否已过时" -f $rel, $newest.ToString('yyyy-MM-dd'), $days, $effStaleDays)
        }
        else { Write-Ok ("{0} 更新于 {1}（{2} 天前）" -f $rel, $newest.ToString('yyyy-MM-dd'), $days) }
    }
}

# ---------- ⑤ 悬空引用：文件 + 小节锚点（不看行号） ----------
Write-Head 5 '悬空引用（文件 + 小节锚点；行号引用不算锚点）'

# 归一化标题：去掉列表/引用/标题前缀、空白、零宽字符与常见前缀符号，便于「标题 vs 引用」比较
function Get-NormalizedTitle($s) {
    if ($null -eq $s) { return '' }
    $x = $s -replace '^\s*#{1,6}\s*', ''
    $x = $x -replace '^\s*>+\s*', ''
    $x = $x -replace '^\s*[-*+]\s+', ''
    $x = $x -replace '[\u200b-\u200f\uFE0E\uFE0F]', ''
    $x = $x -replace '\s', ''
    $x = $x.Trim('*', '#', '>', '-', '、', ':', '：', '(', ')', '（', '）', '「', '」')
    $x = $x.TrimStart('⚠', '●', '○', '■', '★', '▲', '→', '!', '！', ' ')
    return $x
}

# 返回 heading / body / ''（找不到）；纯数字锚点（§4）按「编号标题」匹配
function Test-Anchor($targetText, $anchor) {
    $mNum = [regex]::Match($anchor, '^(\d+)')
    if ($mNum.Success) {
        # §4「说明」这种写法里，数字后面常是描述而不是标题原文 —— 只看编号是否存在
        $num = $mNum.Groups[1].Value
        foreach ($line in ($targetText -split "`r?`n")) {
            if ($line -match ('^\s{0,3}#{1,6}\s*' + $num + '[\.、\s]')) { return 'heading' }
        }
        return ''
    }
    $a = Get-NormalizedTitle $anchor
    if ($a -eq '') { return '' }
    $bodyHit = $false
    foreach ($line in ($targetText -split "`r?`n")) {
        $n = Get-NormalizedTitle $line
        if ($n -eq '' -or -not $n.Contains($a)) { continue }
        if ($line -match '^\s{0,3}#{1,6}\s') { return 'heading' }
        $bodyHit = $true
    }
    if ($bodyHit) { return 'body' }
    return ''
}

$refFiles = @()
if ($hasAgents) { $refFiles += Get-Item -LiteralPath $AgentsPath }
$refFiles += Get-MemoryFiles
$refTotal = 0
$refBad = 0
$refBody = 0
$refSkip = 0
$refBodyList = @()
# 反引号里的 .md 路径，后面可选跟 §小节 或「小节标题」
$refPattern = '`([^`\s]+\.md)`\s*(?:§([^\s，。；、,;)）】\]]+)|「([^」\r\n]{1,40})」)?'
foreach ($f in $refFiles) {
    $t = Read-Text $f.FullName
    $rel = Get-RelPath $f.FullName
    $dir = Split-Path -Parent $f.FullName
    foreach ($m in [regex]::Matches($t, $refPattern)) {
        $ref = $m.Groups[1].Value
        # 外部路径 / glob / 占位符：不是可校验的具体文件，跳过（不误报）
        if ($ref -match '^[a-z][a-z0-9+.\-]*://' -or $ref -match '^[~%$]' -or $ref -match '^([A-Za-z]:[\\/]|/)') { continue }
        if ($ref -match '[*?<>{}]') { continue }
        $anchor = ''
        if ($m.Groups[2].Success) { $anchor = $m.Groups[2].Value }
        elseif ($m.Groups[3].Success) { $anchor = $m.Groups[3].Value }
        # 只接受「像小节标题」的锚点：去掉嵌套引号残留、拒绝含标点/斜杠/星号的长句
        $anchor = $anchor -replace '[「」]', ''
        if ($anchor -match '^(\d+)\s*$') { $anchor = $Matches[1] }
        if ($anchor.Length -gt 24) { $anchor = '' }
        if ($anchor -match '[/*()（）:：，。；、\[\]{}]') { $anchor = '' }
        $refTotal++
        $found = ''
        foreach ($b in @($dir, $KnowledgeDir, $StatusDir, $MemoryRoot, $TargetRoot)) {
            if (-not $b) { continue }
            $cand = Join-Path $b $ref
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $found = $cand; break }
        }
        if (-not $found -and ($ref -notmatch '[\\/]')) {
            # 裸文件名：用全仓索引解析（记忆文件不入库，所以不能只看 git ls-files）
            $idx = Get-RepoIndex
            $key = $ref.ToLower()
            if ($idx.ContainsKey($key) -and $idx[$key].Count -gt 0) {
                $pick = $idx[$key] | Sort-Object Length | Select-Object -First 1
                $found = Join-Path $TargetRoot $pick
            }
        }
        if (-not $found) {
            $line = Get-LineAt $t $m.Index
            if ($line -match '不存在|已删|删除|删掉|已移除|不再引用|已废弃|已作废|弃用|已不成立') {
                $refSkip++
                Write-Note ("{0} -> {1}：出现在「否定语境」里（已记录的失效，不计失败）" -f $rel, ('`' + $ref + '`'))
            }
            else {
                $refBad++
                $extra = ''
                if ($anchor -ne '') { $extra = "，锚点「$anchor」无从校验" }
                Write-Fail ("{0} -> 引用了不存在的 {1}{2}" -f $rel, ('`' + $ref + '`'), $extra)
            }
            continue
        }
        if ($anchor -eq '') { continue }
        $verdict = Test-Anchor (Read-Text $found) $anchor
        if ($verdict -eq '') {
            $refBad++
            Write-Fail ("{0} -> {1}「{2}」：目标文件里找不到该小节" -f $rel, ('`' + $ref + '`'), $anchor)
        }
        elseif ($verdict -eq 'body') {
            $refBody++
            $refBodyList += ("{0} -> {1}「{2}」" -f $rel, ('`' + $ref + '`'), $anchor)
        }
    }
}
if ($refBody -gt 0) {
    $shown = @($refBodyList | Select-Object -First 3) -join '；'
    $more = if ($refBody -gt 3) { ' 等' } else { '' }
    Write-Note ("{0} 处锚点只命中正文（不是小节标题；能定位，但指向标题更好）：{1}{2}" -f $refBody, $shown, $more)
}
if ($refFiles.Count -eq 0) { Write-Warn2 '没有可扫描的记忆文件' }
elseif ($refTotal -eq 0) { Write-Ok '没有「文件 + 锚点」形式的引用（本项无需校验）' }
elseif ($refBad -eq 0) { Write-Ok ("{0} 处引用全部可定位（另有 {1} 处否定语境、{2} 处锚点只命中正文）" -f $refTotal, $refSkip, $refBody) }
else { Write-Note ("共扫描 {0} 处引用：失败 {1}，否定语境 {2}，锚点降级 {3}" -f $refTotal, $refBad, $refSkip, $refBody) }

# ---------- ⑥ 忽略规则：过宽规则 + 记忆是否真的被忽略 ----------
Write-Head 6 '忽略规则：过宽规则 / 记忆与入口是否真的被忽略'
$OverBroad = @('.agents', '.agents/', '/.agents', '/.agents/')
$ignoreFiles = @()
$giPath = Join-Path $TargetRoot '.gitignore'
if (Test-Path -LiteralPath $giPath) { $ignoreFiles += $giPath }
$exPath = Join-Path $TargetRoot '.git\info\exclude'
if (Test-Path -LiteralPath $exPath) { $ignoreFiles += $exPath }
if ($ignoreFiles.Count -eq 0) {
    Write-Warn2 '既没有 .gitignore 也没有 .git/info/exclude —— 记忆不会被忽略，可能被误提交'
}
else {
    $wide = @()
    $memoryRule = ''
    $agentsRule = ''
    foreach ($file in $ignoreFiles) {
        $ln = 0
        foreach ($line in ([IO.File]::ReadAllText($file) -split "`r?`n")) {
            $ln++
            $v = $line.Trim()
            if ($v -eq '' -or $v.StartsWith('#')) { continue }
            if ($OverBroad -contains $v) { $wide += ("{0}:{1}  {2}" -f (Get-RelPath $file), $ln, $v) }
            if (($v -eq '.agents/memory' -or $v -eq '.agents/memory/') -and -not $memoryRule) { $memoryRule = ("{0}:{1}" -f (Get-RelPath $file), $ln) }
            if (($v -eq 'AGENTS.md' -or $v -eq '/AGENTS.md') -and -not $agentsRule) { $agentsRule = ("{0}:{1}" -f (Get-RelPath $file), $ln) }
        }
    }
    foreach ($w in $wide) {
        Write-Fail ("过宽规则 $w —— 它会连 .agents/skills/ 一起忽略掉，仓库级 Skill 就进不了库")
    }
    if ($wide.Count -gt 0) { Write-Note '改成精确规则：.agents/memory/' }
    if (-not $memoryRule) { Write-Warn2 '没有 .agents/memory/ 忽略规则 —— 记忆可能被误提交（若有意让记忆入库，忽略此条）' }
    if (-not $agentsRule) { Write-Warn2 '没有 AGENTS.md 忽略规则 —— 入口文件可能被误提交' }
    if ($wide.Count -eq 0 -and $memoryRule -and $agentsRule) {
        Write-Ok ("忽略规则精确到位（记忆 {0}；入口 {1}）" -f $memoryRule, $agentsRule)
    }
}

# ---------- ⑦ 仓库级 Skill 的入库状态 ----------
Write-Head 7 '仓库级 Skill（.agents/skills/）的入库状态'
$skillsDir = Join-Path $TargetRoot '.agents\skills'
if (-not (Test-Path -LiteralPath $skillsDir)) {
    Write-Ok '没有 .agents/skills/（本项目不用仓库级 Skill）'
}
elseif (-not $gitOk) {
    Write-Warn2 '不是 git 仓库或找不到 git —— 跳过入库状态检查'
}
else {
    $sFiles = @(Get-ChildItem -LiteralPath $skillsDir -Recurse -File -ErrorAction SilentlyContinue)
    $tracked = @(& git -C $TargetRoot ls-files -- '.agents/skills' 2>$null)
    if ($sFiles.Count -eq 0) { Write-Ok '.agents/skills/ 是空目录' }
    elseif ($tracked.Count -eq 0) {
        $sample = $sFiles[0].FullName.Substring($TargetRoot.Length).TrimStart('\', '/')
        $rule = @(& git -C $TargetRoot check-ignore -v -- $sample 2>$null)
        $ruleText = if ($rule.Count -gt 0 -and $rule[0]) { ($rule -join ' ') } else { '' }
        if ($ruleText -match '\.agents[/\\]skills') {
            # 被「点了名」的规则挡住 → 视为有意（例：第三方 Skill 包不随仓库分发）
            Write-Note ("{0} 个仓库级 Skill 文件被显式规则有意忽略（{1}）—— 若想共享，删掉该规则或加 ! 例外" -f $sFiles.Count, $ruleText)
        }
        else {
            Write-Fail ("{0} 个仓库级 Skill 文件全都没入库（git ls-files .agents/skills 为空）—— 别人 clone 后拿不到它们" -f $sFiles.Count)
            if ($ruleText) { Write-Note ("元凶规则：{0}" -f $ruleText) }
            else { Write-Note '不是被忽略规则挡住 —— 检查是不是漏了 git add' }
        }
    }
    else { Write-Ok ("{0} 个文件在磁盘上，已入库 {1} 个" -f $sFiles.Count, $tracked.Count) }
}

# ---------- ⑧ 备份（唯一写操作，结果来自开头的 -Backup） ----------
Write-Head 8 '备份（-Backup 是本脚本唯一的写操作）'
if (-not $Backup) { Write-Ok '未启用 —— 整理记忆前建议加 -Backup 先落一份快照' }
elseif ($backupResult.StartsWith('跳过')) { Write-Warn2 $backupResult }
else { Write-Ok $backupResult }

# ---------- ⑨ 入库文件不得引用本机文档 ----------
Write-Head 9 '入库文件不得引用本机文档（远程读者看不到本机记忆 / 私有目录）'
if (-not $gitOk) { Write-Warn2 '不是 git 仓库或找不到 git —— 跳过' }
else {
    $docs = @(& git -C $TargetRoot ls-files -- '*.md' 2>$null |
        Where-Object { $_ -and $_ -notmatch '(^|/)(node_modules|dist|build|\.git)/' -and $_ -ne 'AGENTS.md' -and $_ -notmatch '^\.agents/' })
    $hits = 0
    $scanned = 0
    foreach ($rel in $docs) {
        $full = Join-Path $TargetRoot $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        if ((Get-Item -LiteralPath $full).Length -gt 300KB) { continue }
        $scanned++
        $ln = 0
        foreach ($line in ([IO.File]::ReadAllText($full) -split "`r?`n")) {
            $ln++
            if ($line -match '\.agents/memory|\.agents/skills|\.clineignore|docs/_local/') {
                $hits++
                Write-Warn2 ("{0}:{1} -> {2}" -f $rel, $ln, $line.Trim())
            }
        }
    }
    if ($hits -eq 0) { Write-Ok ("扫描 {0} 个入库 markdown：没有引用本机记忆 / 私有目录 / 本机绝对路径" -f $scanned) }
    else { Write-Note '这些引用对远程读者是死链或隐私泄漏 —— 要么写进入库文档，要么去掉本机专属内容' }
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host ('==== 汇总：FAIL {0} / WARN {1} / OK {2} ====' -f $Script:Fail, $Script:Warn, $Script:Ok) -ForegroundColor White
if ($Script:Fail -gt 0) {
    Write-Host '结论：记忆骨架有需要修的问题（见上面的 FAIL）。' -ForegroundColor Red
}
elseif ($Script:Warn -gt 0) {
    Write-Host '结论：没有硬错误；警告项建议看一眼（要严格模式加 -Strict）。' -ForegroundColor Yellow
}
else {
    Write-Host '结论：全部通过。' -ForegroundColor Green
}
Write-Host '说明：本脚本只做「机械可判定」的检查；内容对不对仍归 memory-hygiene。' -ForegroundColor DarkGray

if ($Script:Fail -gt 0) { exit 1 }
if ($Strict -and $Script:Warn -gt 0) { exit 1 }
exit 0
