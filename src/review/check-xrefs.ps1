<#
.SYNOPSIS
  Deterministic cross-reference check for a family review folder.

.DESCRIPTION
  Parses every proposal file (proposal-WI-<id>.md, or WI-<id>*.md in the fixture) and checks:
  - every "criterio(s) N de #X", "pregunta(s) N de #X", "supuesto(s) N" reference points to an
    existing criterion / question / supuesto (ranges "3 a 5" and lists "3, 6 y 7" expanded;
    references without "de #X" point to the same file);
  - every supuesto listed in "Supuestos propuestos" is used by a [PROPUESTO: ver supuesto N]
    marker;
  - the same scope element annotated "(implementado en criterio(s) ... de #X)" in different
    files points to the same criteria (warning);
  and lists every cross-item reference with the title of the target criterion, so a reviewer can
  check meaning (which this script cannot judge).
  Sections titled "Correcciones tras validacion" are skipped (they quote old numbers on purpose).

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File src/review/check-xrefs.ps1 -Folder <family folder> [-Out <report path>]

.OUTPUTS
  Markdown report (default <Folder>/xref-report.md). Exit code: 0 no errors, 1 errors, 2 usage error.

.NOTES
  Pure ASCII on purpose: Windows PowerShell 5.1 parses BOM-less .ps1 files as Windows-1252.
  Proposal files are read as UTF-8.
#>

param(
    [Parameter(Mandatory)][string]$Folder,
    [string]$Out
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
    Write-Error "Folder not found: $Folder"
    exit 2
}
$Folder = (Resolve-Path -LiteralPath $Folder).Path
if (-not $Out) { $Out = Join-Path $Folder 'xref-report.md' }

$files = @(Get-ChildItem -LiteralPath $Folder -File -Filter '*.md' |
    Where-Object { $_.Name -match '^(proposal-)?WI-\d+' } | Sort-Object Name)
if ($files.Count -eq 0) {
    Write-Error "No proposal files (proposal-WI-*.md or WI-*.md) in $Folder"
    exit 2
}

function Read-Utf8Lines([string]$Path) {
    return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -split "`r?`n"
}

function Get-SectionKind([string]$Heading) {
    if ($Heading -match '^Criterios de aceptaci') { return 'crit' }
    if ($Heading -match '^Preguntas abiertas') { return 'preg' }
    if ($Heading -match '^Supuestos propuestos') { return 'sup' }
    if ($Heading -match '^Correcciones tras validaci') { return 'skip' }
    return 'other'
}

function Expand-Numbers([string]$Text) {
    $nums = New-Object System.Collections.Generic.List[int]
    foreach ($m in [regex]::Matches($Text, '(\d+)\s+a\s+(\d+)')) {
        $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
        if ($b -lt $a) { $t = $a; $a = $b; $b = $t }
        for ($n = $a; $n -le $b; $n++) { $nums.Add($n) }
    }
    $rest = [regex]::Replace($Text, '(\d+)\s+a\s+(\d+)', ' ')
    foreach ($m in [regex]::Matches($rest, '\d+')) { $nums.Add([int]$m.Value) }
    return @($nums | Sort-Object -Unique)
}

# Words that describe references, not what they refer to (accent-free, as normalized).
$script:StopWords = @(
    'criterio','criterios','pregunta','preguntas','supuesto','supuestos','implementado',
    'implementada','implementados','implementadas','implementa','implementan','implemente',
    'define','definen','definido','definidos','definir','incluye','incluyen','propuesta',
    'propone','queda','quedan','esta','este','estos','estas','para','como','cada','sobre',
    'desde','entre','tambien','mismo','misma','mismos','mismas','texto','ver','segun','donde',
    'identico','identicos','identica','identicas','igual','iguales','tiene','tienen','repite',
    'repiten','detalle','corresponde','corresponden','cubre','cubren','solo','referencia',
    'redaccion','copia','copian','copiado','copiados'
)

function Get-NormalizedTokens([string]$Text) {
    $d = $Text.ToLowerInvariant().Normalize([System.Text.NormalizationForm]::FormD)
    $d = [regex]::Replace($d, '\p{Mn}', '')
    $d = [regex]::Replace($d, '[^a-z0-9 ]', ' ')
    return @($d -split '\s+' | Where-Object { $_.Length -ge 4 -and $script:StopWords -notcontains $_ } | Sort-Object -Unique)
}

function Test-SubsetOf($A, $B) {
    foreach ($x in $A) { if ($B -notcontains $x) { return $false } }
    return $true
}

# ---- Pass 1: parse criteria, questions and supuestos per item ----
$items = @{}
foreach ($f in $files) {
    $id = [regex]::Match($f.Name, 'WI-(\d+)').Groups[1].Value
    $lines = Read-Utf8Lines $f.FullName
    $kind = 'other'
    $criteria = @{}; $questions = @{}; $supuestos = @{}
    foreach ($l in $lines) {
        if ($l -match '^#{2,3}\s+(.+?)\s*$') { $kind = Get-SectionKind $Matches[1]; continue }
        if ($kind -eq 'crit' -and $l -match '^\s*(\d+)\.\s+\*\*(.+?)\*\*') {
            $criteria[[int]$Matches[1]] = $Matches[2].Trim().TrimEnd('.')
        } elseif ($kind -eq 'preg' -and $l -match '^\s*(\d+)\.\s+') {
            $questions[[int]$Matches[1]] = $true
        } elseif ($kind -eq 'sup' -and $l -match '^\|\s*(\d+)\s*\|') {
            $supuestos[[int]$Matches[1]] = $true
        }
    }
    $items[$id] = [pscustomobject]@{
        Id = $id; File = $f.Name; Lines = $lines
        Criteria = $criteria; Questions = $questions; Supuestos = $supuestos
    }
}

# ---- Pass 2: scan references ----
$errors = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[object]
$crossRefs = New-Object System.Collections.Generic.List[object]
$scopeAnnotations = New-Object System.Collections.Generic.List[object]

$numList = '(\d+(?:\s*(?:,|\by\b|\ba\b)\s*\d+)*)'
# "criterio(s) N de #X" (or no "de #X": same file)
$fwdPattern = '(?i)\b(criterios?|preguntas?|supuestos?)\s+' + $numList + '(?:\s+de\s+(?:la\s+propuesta\s+de\s+)?#(\d{4,}))?'
# Reversed order: "#X (criterio N)", "#X, criterio N", "propuesta de #X ... (criterio N)"
$revPattern = '(?i)#(\d{4,})\)?\s*,?\s*\(\s*(criterios?|preguntas?)\s+' + $numList + '|(?i)#(\d{4,})\s*,\s*(criterios?|preguntas?)\s+' + $numList

function Get-References([string]$Text) {
    $refs = New-Object System.Collections.Generic.List[object]
    $spans = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($Text, $revPattern)) {
        $g = if ($m.Groups[1].Success) { 1 } else { 4 }
        $refs.Add([pscustomobject]@{ Index = $m.Index; Length = $m.Length; Value = $m.Value
            Word = $m.Groups[$g + 1].Value.ToLowerInvariant(); NumsText = $m.Groups[$g + 2].Value; TargetId = $m.Groups[$g].Value })
        $spans.Add(@($m.Index, ($m.Index + $m.Length)))
    }
    foreach ($m in [regex]::Matches($Text, $fwdPattern)) {
        $overlap = $false
        foreach ($s in $spans) { if ($m.Index -lt $s[1] -and ($m.Index + $m.Length) -gt $s[0]) { $overlap = $true } }
        if ($overlap) { continue }
        $tid = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { $null }
        $refs.Add([pscustomobject]@{ Index = $m.Index; Length = $m.Length; Value = $m.Value
            Word = $m.Groups[1].Value.ToLowerInvariant(); NumsText = $m.Groups[2].Value; TargetId = $tid })
    }
    return @($refs | Sort-Object Index)
}

# Logical blocks: wrapped Markdown lines are joined so a reference split across a line break is
# still found. A block starts at a heading, a blank line, a list item or a table row.
function Get-Blocks($Lines) {
    $blocks = New-Object System.Collections.Generic.List[object]
    $cur = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        $isHeading = $l -match '^#{2,3}\s+'
        $starts = $isHeading -or ($l -match '^\s*$') -or ($l -match '^\s*([-*]|\d+\.)\s') -or ($l -match '^\s*\|')
        if ($starts -or $null -eq $cur) {
            if ($null -ne $cur) { $blocks.Add($cur) }
            $cur = [pscustomobject]@{ LineNo = $i + 1; Text = $l; Heading = $isHeading }
            if ($isHeading -or ($l -match '^\s*\|')) { $blocks.Add($cur); $cur = $null }
        } else {
            $cur.Text = $cur.Text + ' ' + $l.Trim()
        }
    }
    if ($null -ne $cur) { $blocks.Add($cur) }
    return $blocks
}

foreach ($item in $items.Values) {
    $kind = 'other'
    $usedSupuestos = @{}
    foreach ($block in (Get-Blocks $item.Lines)) {
        $l = $block.Text
        $lineNo = $block.LineNo
        if ($block.Heading) { if ($l -match '^#{2,3}\s+(.+?)\s*$') { $kind = Get-SectionKind $Matches[1] }; continue }
        if ($kind -eq 'skip') { continue }

        # A supuesto counts as used only by a marker inside "Criterios de aceptacion" (the
        # contract: a proposed default is a behavior a criterion states). A marker elsewhere is
        # reported: Alcance should say "(supuesto N)", and Notes are not pasted into ADO.
        foreach ($m in [regex]::Matches($l, '\[PROPUESTO: ver supuesto (\d+)\]')) {
            if ($kind -eq 'crit') {
                $usedSupuestos[[int]$m.Groups[1].Value] = $true
            } else {
                $warnings.Add([pscustomobject]@{
                    Where = "$($item.File):$lineNo"
                    Detail = "[PROPUESTO: ver supuesto $($m.Groups[1].Value)] outside 'Criterios de aceptacion': use '(supuesto N)' in Alcance, and only criteria may carry the marker"
                })
            }
        }

        $prevEnd = 0
        foreach ($m in (Get-References $l)) {
            if ($m.Index -lt $prevEnd) { continue }
            # Subject of this reference: text since the previous reference on the line, without
            # bracket markers, cut at the last sentence boundary. If what follows the boundary has
            # no content words (e.g. "; detalle en"), fall back to the segment before it, which is
            # where the scope element is named.
            $raw = [regex]::Replace($l.Substring($prevEnd, $m.Index - $prevEnd), '\[[^\]]*\]', ' ')
            $cut = $raw.LastIndexOfAny([char[]]'.;:')
            $window = if ($cut -ge 0) { $raw.Substring($cut + 1) } else { $raw }
            # Fall back across ';' or ':' only: a '.' ends the sentence, and the previous sentence
            # talks about something else.
            if ($cut -ge 0 -and $raw[$cut] -ne '.' -and @(Get-NormalizedTokens $window).Count -eq 0) {
                $before = $raw.Substring(0, $cut)
                $cut2 = $before.LastIndexOfAny([char[]]'.;:')
                $window = if ($cut2 -ge 0) { $before.Substring($cut2 + 1) } else { $before }
            }
            $prevEnd = $m.Index + $m.Length
            $word = $m.Word
            $nums = Expand-Numbers $m.NumsText
            $targetId = if ($m.TargetId) { $m.TargetId } else { $item.Id }
            $where = "$($item.File):$lineNo"
            if (-not $items.ContainsKey($targetId)) {
                $errors.Add([pscustomobject]@{ Where = $where; Ref = $m.Value; Target = "#$targetId"; Problem = 'target item has no proposal in this family' })
                continue
            }
            $target = $items[$targetId]
            $table = if ($word -like 'criterio*') { $target.Criteria } elseif ($word -like 'pregunta*') { $target.Questions } else { $target.Supuestos }
            $missing = @($nums | Where-Object { -not $table.ContainsKey($_) })
            if ($missing.Count -gt 0) {
                $errors.Add([pscustomobject]@{ Where = $where; Ref = $m.Value; Target = "#$targetId"; Problem = "does not exist: $($missing -join ', ')" })
            }
            if ($word -like 'criterio*' -and $targetId -ne $item.Id) {
                $titles = @($nums | ForEach-Object { if ($target.Criteria.ContainsKey($_)) { "$_ = $($target.Criteria[$_])" } else { "$_ = (missing)" } })
                $crossRefs.Add([pscustomobject]@{ Where = $where; Ref = $m.Value; Target = "#$targetId"; Titles = ($titles -join '; ') })
                $tokens = @(Get-NormalizedTokens $window)
                if ($tokens.Count -gt 0) {
                    $scopeAnnotations.Add([pscustomobject]@{
                        Where = $where; TargetId = $targetId; Nums = $nums; Tokens = $tokens
                        Label = ($window -replace '[()*`]', '').Trim(' ', '-', ',')
                    })
                }
            }
        }
    }
    foreach ($n in $item.Supuestos.Keys) {
        if (-not $usedSupuestos.ContainsKey($n)) {
            $errors.Add([pscustomobject]@{ Where = $item.File; Ref = "supuesto $n"; Target = "#$($item.Id)"; Problem = 'listed in Supuestos propuestos but no criterion carries [PROPUESTO: ver supuesto N]' })
        }
    }
}

# Same subject pointing to inconsistent criteria of the same target. If the subject of reference
# A is contained in the subject of reference B (A is the narrower or equal description), then A's
# criteria must be a subset of B's: a narrower description cannot point to criteria the broader
# one leaves out (e.g. "los filtros" -> 3 a 5 while "Filtros por sucursal, mes..." -> 3).
$ann = $scopeAnnotations.ToArray()
for ($x = 0; $x -lt $ann.Count; $x++) {
    for ($y = 0; $y -lt $ann.Count; $y++) {
        if ($x -eq $y) { continue }
        $a = $ann[$x]; $b = $ann[$y]
        if ($a.TargetId -ne $b.TargetId) { continue }
        if (-not (Test-SubsetOf $a.Tokens $b.Tokens)) { continue }
        if ($a.Tokens.Count -eq $b.Tokens.Count -and $x -gt $y) { continue }  # equal subjects: report once
        if (Test-SubsetOf $a.Nums $b.Nums) { continue }
        $warnings.Add([pscustomobject]@{
            Where = "$($a.Where) / $($b.Where)"
            Detail = "same subject, inconsistent criteria of #$($a.TargetId): '$($a.Label)' -> [$($a.Nums -join ',')] but '$($b.Label)' -> [$($b.Nums -join ',')]"
        })
    }
}

# ---- Report ----
$sb = New-Object System.Text.StringBuilder
$result = if ($errors.Count -eq 0) { 'OK' } else { "ERRORS ($($errors.Count))" }
[void]$sb.AppendLine('# Cross-reference check')
[void]$sb.AppendLine("Folder: $Folder | Date: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC | Result: $result | Warnings: $($warnings.Count)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Items parsed')
[void]$sb.AppendLine('| Item | File | Criteria | Questions | Supuestos |')
[void]$sb.AppendLine('|---|---|---|---|---|')
foreach ($it in ($items.Values | Sort-Object Id)) {
    [void]$sb.AppendLine("| #$($it.Id) | $($it.File) | $($it.Criteria.Count) | $($it.Questions.Count) | $($it.Supuestos.Count) |")
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Errors (references that do not resolve)')
if ($errors.Count -eq 0) { [void]$sb.AppendLine('None.') } else {
    [void]$sb.AppendLine('| Where | Reference | Target | Problem |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($e in $errors) { [void]$sb.AppendLine("| $($e.Where) | $($e.Ref) | $($e.Target) | $($e.Problem) |") }
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Warnings (possible inconsistency, needs a human or the validator)')
if ($warnings.Count -eq 0) { [void]$sb.AppendLine('None.') } else {
    foreach ($w in $warnings) { [void]$sb.AppendLine("- $($w.Where): $($w.Detail)") }
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Cross-item criterion references (check that each reference means what the target title says)')
if ($crossRefs.Count -eq 0) { [void]$sb.AppendLine('None.') } else {
    [void]$sb.AppendLine('| Where | Reference | Target | Target criteria titles |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($c in $crossRefs) { [void]$sb.AppendLine("| $($c.Where) | $($c.Ref) | $($c.Target) | $($c.Titles) |") }
}

[System.IO.File]::WriteAllText($Out, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "Cross-reference check: $result, $($warnings.Count) warning(s). Report: $Out"
if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
