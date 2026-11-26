<#
.SYNOPSIS
  Deterministic validator of a feature analysis (analysis.json, written by wi-feature-analyst)
  against the candidate clusters (candidates.json, written by cluster-feature.ps1) and the family
  proposals (step 3 of the feature-level check).

.DESCRIPTION
  Checks (each violation is listed in the report with its check id):
  - A1 schema: analysis.json parses; top-level sections present with the right types; ids unique
    and well-formed (CQ-NN, FF-NN); enums valid (decision, status, kind, evidence section);
    required texts non-empty; featureId equals the one in candidates.json; schemaVersion 1.
  - A2 references: every cited family, item, entry, cluster and consolidated question exists
    (family/item/entry/cluster in candidates.json; an item must belong to the cited family).
    Evidence with section question/supuesto must name an existing entry of that item; evidence
    with section criterion must name a criterion that exists in the item's proposal file
    (<ReviewsRoot>/<family>/proposal-WI-<item>.md or WI-<item>*.md; family folder missing is a
    warning, not verifiable).
  - A3 cluster reviews: every cross-family cluster of candidates.json is reviewed exactly once
    (decision confirmed | discarded, with a reason); a confirmed cluster is used by at least one
    finding or consolidated question; a discarded cluster is used by none.
  - A4 findings: dependency, overlap and contradiction cite evidence from 2 or more distinct
    families (so every family involved has its own evidence); repeated-question has 2 or more
    evidence rows and links at least one consolidated question.
  - A5 consolidated questions: affectedItems include every item that produced any entry the
    question covers (no item lost); extra items are allowed if they exist.
  - A6 coverage: every candidate entry of kind "pregunta" appears exactly once across
    consolidatedQuestions[].entries and notConsolidated[].entry. Supuesto entries may be covered
    (at most once) but are not required.
  - A7 characters: no U+2013, U+2014, U+2026, U+2018, U+2019, U+201C, U+201D, U+2190-U+21FF in
    analysis.json or feature-report.md.
  A missing feature-report.md is a warning (the analyst writes both files).

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File src/review/check-feature-analysis.ps1 -AnalysisDir reviews/<project>/_feature-<id> [-ReviewsRoot reviews/<project>] [-Out <report path>]

.OUTPUTS
  Markdown report (default <AnalysisDir>/analysis-check.md). Never writes anything else; a report
  path inside a family folder is refused.
  Exit code: 0 no violations, 1 violations (including unparseable analysis.json), 2 usage error
  (folder, analysis.json or candidates.json missing, candidates.json unparseable).

.NOTES
  Pure ASCII on purpose: Windows PowerShell 5.1 parses BOM-less .ps1 files as Windows-1252.
  Inputs are read as UTF-8; the report is written as UTF-8 without BOM.
#>

param(
    [Parameter(Mandatory)][string]$AnalysisDir,
    [string]$ReviewsRoot,
    [string]$Out
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail-Usage([string]$Message) {
    [Console]::Error.WriteLine("check-feature-analysis: $Message")
    exit 2
}

# ---- Arguments ----
if (-not (Test-Path -LiteralPath $AnalysisDir -PathType Container)) { Fail-Usage "AnalysisDir not found: $AnalysisDir" }
$AnalysisDir = (Resolve-Path -LiteralPath $AnalysisDir).Path
$analysisPath = Join-Path $AnalysisDir 'analysis.json'
$candidatesPath = Join-Path $AnalysisDir 'candidates.json'
$reportMdPath = Join-Path $AnalysisDir 'feature-report.md'
if (-not (Test-Path -LiteralPath $analysisPath -PathType Leaf)) { Fail-Usage "analysis.json not found in $AnalysisDir" }
if (-not (Test-Path -LiteralPath $candidatesPath -PathType Leaf)) { Fail-Usage "candidates.json not found in $AnalysisDir" }
if (-not $ReviewsRoot) { $ReviewsRoot = Split-Path -Parent $AnalysisDir }
if (-not (Test-Path -LiteralPath $ReviewsRoot -PathType Container)) { Fail-Usage "ReviewsRoot not found: $ReviewsRoot" }
$ReviewsRoot = (Resolve-Path -LiteralPath $ReviewsRoot).Path
if (-not $Out) { $Out = Join-Path $AnalysisDir 'analysis-check.md' }
$Out = [System.IO.Path]::GetFullPath($Out)
foreach ($d in @(Get-ChildItem -LiteralPath $ReviewsRoot -Directory | Where-Object { $_.Name -match '^\d+$' })) {
    $fd = $d.FullName.TrimEnd('\', '/')
    if ($Out.StartsWith($fd + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $Out.StartsWith($fd + '/', [StringComparison]::OrdinalIgnoreCase)) {
        Fail-Usage "Out is inside family folder $($d.Name); family files must never be written: $Out"
    }
}

function Read-Utf8([string]$Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }

try { $cand = Read-Utf8 $candidatesPath | ConvertFrom-Json } catch { Fail-Usage "candidates.json is not valid JSON: $($_.Exception.Message)" }

# ---- Helpers (StrictMode-safe access to parsed JSON) ----
function Test-Prop($Obj, [string]$Name) {
    return ($null -ne $Obj) -and ($Obj -is [System.Management.Automation.PSCustomObject]) -and
        ($null -ne $Obj.PSObject.Properties[$Name])
}
function Get-Prop($Obj, [string]$Name) {
    if (Test-Prop $Obj $Name) { return $Obj.PSObject.Properties[$Name].Value }
    return $null
}
function Test-Text($Value) { return ($Value -is [string]) -and ($Value.Trim() -ne '') }
# Ids may be written as strings or integers; both normalize to the string form.
function Get-IdText($Value) {
    if ($Value -is [string]) { return $Value.Trim() }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    return $null
}
function Get-Array($Value) {
    if ($null -eq $Value) { return , @() }
    return , @($Value)
}

$violations = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
function Add-Violation([string]$Check, [string]$Where, [string]$Problem) {
    $violations.Add([pscustomobject]@{ Check = $Check; Where = $Where; Problem = $Problem })
}

# ---- Candidates index ----
$candFeature = [string](Get-Prop $cand 'featureId')
$famItems = @{}          # family -> HashSet of items
$itemFamily = @{}        # item -> family
foreach ($f in (Get-Array (Get-Prop $cand 'families'))) {
    $fid = [string]$f.id
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in (Get-Array $f.items)) { [void]$set.Add([string]$i); $itemFamily[[string]$i] = $fid }
    $famItems[$fid] = $set
}
$entries = @{}
$entryOrder = New-Object System.Collections.Generic.List[string]
foreach ($e in (Get-Array (Get-Prop $cand 'entries'))) { $entries[[string]$e.id] = $e; $entryOrder.Add([string]$e.id) }
$clusters = @{}
$crossClusters = New-Object System.Collections.Generic.List[string]
foreach ($c in (Get-Array (Get-Prop $cand 'clusters'))) {
    $clusters[[string]$c.id] = $c
    if ($c.scope -eq 'cross-family') { $crossClusters.Add([string]$c.id) }
}
if ((Get-Prop $cand 'coverageOk') -ne $true) { $warnings.Add('candidates.json reports coverageOk = false: rerun cluster-feature.ps1 before trusting this check.') }

# ---- A7: characters (raw text, before parsing) ----
$analysisRaw = Read-Utf8 $analysisPath
# Built from code points so this file stays pure ASCII.
$forbidden = '[' + (-join [char[]]@(0x2013, 0x2014, 0x2026, 0x2018, 0x2019, 0x201C, 0x201D)) + [char]0x2190 + '-' + [char]0x21FF + ']'
function Test-Characters([string]$Text, [string]$Name) {
    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], $forbidden)) {
            Add-Violation 'A7' "${Name}:$($i + 1)" ('forbidden character U+' + ([int][char]$m.Value).ToString('X4'))
        }
    }
}
Test-Characters $analysisRaw 'analysis.json'
if (Test-Path -LiteralPath $reportMdPath -PathType Leaf) {
    Test-Characters (Read-Utf8 $reportMdPath) 'feature-report.md'
} else {
    $warnings.Add('feature-report.md is missing: the analyst writes analysis.json and feature-report.md together.')
}

# ---- Proposal criteria (lazy, per item) ----
$criteriaCache = @{}
function Get-Criteria([string]$Family, [string]$Item) {
    $key = "$Family/$Item"
    if ($criteriaCache.ContainsKey($key)) { return , $criteriaCache[$key] }
    $dir = Join-Path $ReviewsRoot $Family
    $result = $null
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $result = 'no-family'
    } else {
        $file = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.md' |
            Where-Object { $_.Name -match '^(proposal-)?WI-(\d+)' -and $Matches[2] -eq $Item } | Sort-Object Name)
        if ($file.Count -eq 0) {
            $result = 'no-file'
        } else {
            $set = New-Object 'System.Collections.Generic.HashSet[int]'
            $inCrit = $false
            foreach ($l in ((Read-Utf8 $file[0].FullName) -split "`r?`n")) {
                if ($l -match '^#{1,6}\s+(.+?)\s*$') { $inCrit = ($Matches[1] -match '^Criterios de aceptaci'); continue }
                if ($inCrit -and $l -match '^\s*(\d+)\.\s+\*\*') { [void]$set.Add([int]$Matches[1]) }
            }
            $result = $set
        }
    }
    $criteriaCache[$key] = $result
    return , $result   # comma: a HashSet would be unrolled into its elements
}

# ---- Parse analysis.json ----
$analysis = $null
try { $analysis = $analysisRaw | ConvertFrom-Json } catch {
    Add-Violation 'A1' 'analysis.json' "not valid JSON: $($_.Exception.Message -replace '\r?\n', ' ')"
}

$coverage = @{}   # entry id -> list of holders (CQ-NN or notConsolidated/<status>)
function Add-Coverage([string]$EntryId, [string]$Holder) {
    if (-not $coverage.ContainsKey($EntryId)) { $coverage[$EntryId] = New-Object System.Collections.Generic.List[string] }
    $coverage[$EntryId].Add($Holder)
}

$cqIds = @{}
$clusterUse = @{}   # cluster id -> list of users (CQ-NN / FF-NN)
function Add-ClusterUse([string]$ClusterId, [string]$User, [string]$Where) {
    if (-not $clusters.ContainsKey($ClusterId)) { Add-Violation 'A2' $Where "unknown cluster $ClusterId"; return }
    if (-not $clusterUse.ContainsKey($ClusterId)) { $clusterUse[$ClusterId] = New-Object System.Collections.Generic.List[string] }
    $clusterUse[$ClusterId].Add($User)
}
function Get-IdList($Obj, [string]$Name, [string]$Where) {
    if (-not (Test-Prop $Obj $Name)) { Add-Violation 'A1' $Where "missing field '$Name'"; return , @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in (Get-Array (Get-Prop $Obj $Name))) {
        $t = Get-IdText $v
        if ($null -eq $t -or $t -eq '') { Add-Violation 'A1' $Where "'$Name' holds a value that is not an id" } else { $out.Add($t) }
    }
    return , @($out)
}

$kinds = @('dependency', 'overlap', 'contradiction', 'repeated-question')
$crossKinds = @('dependency', 'overlap', 'contradiction')
$sections = @('criterion', 'question', 'supuesto', 'story', 'objective', 'scope', 'dossier', 'evaluation', 'other')
$numbered = @('criterion', 'question', 'supuesto')

if ($null -ne $analysis) {
    if (-not ($analysis -is [System.Management.Automation.PSCustomObject])) {
        Add-Violation 'A1' 'analysis.json' 'top level is not an object'
        $analysis = $null
    }
}

if ($null -ne $analysis) {
    # -- top level --
    if ((Get-Prop $analysis 'schemaVersion') -ne 1) { Add-Violation 'A1' 'schemaVersion' 'must be 1' }
    $aFeature = Get-IdText (Get-Prop $analysis 'featureId')
    if ($aFeature -ne $candFeature) { Add-Violation 'A1' 'featureId' "is '$aFeature', candidates.json has '$candFeature'" }
    foreach ($sec in @('clusterReviews', 'consolidatedQuestions', 'notConsolidated', 'findings')) {
        if (-not (Test-Prop $analysis $sec)) { Add-Violation 'A1' $sec "missing top-level section '$sec'" }
        elseif ($null -ne (Get-Prop $analysis $sec) -and -not ((Get-Prop $analysis $sec) -is [array])) {
            Add-Violation 'A1' $sec "'$sec' must be an array"
        }
    }

    # -- consolidated questions --
    $n = 0
    foreach ($q in (Get-Array (Get-Prop $analysis 'consolidatedQuestions'))) {
        $n++
        $qid = Get-IdText (Get-Prop $q 'id')
        $where = if ($qid) { $qid } else { "consolidatedQuestions[$n]" }
        if (-not $qid -or $qid -notmatch '^CQ-\d{2,}$') { Add-Violation 'A1' $where "id must match CQ-NN" }
        elseif ($cqIds.ContainsKey($qid)) { Add-Violation 'A1' $where 'duplicate id' }
        if ($qid) { $cqIds[$qid] = $true }
        if (-not (Test-Text (Get-Prop $q 'question'))) { Add-Violation 'A1' $where "missing or empty 'question'" }
        $qEntries = Get-IdList $q 'entries' $where
        if ($qEntries.Count -eq 0) { Add-Violation 'A1' $where "'entries' is empty" }
        $affected = Get-IdList $q 'affectedItems' $where
        foreach ($it in $affected) { if (-not $itemFamily.ContainsKey($it)) { Add-Violation 'A2' $where "unknown affected item $it" } }
        $needed = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($eid in $qEntries) {
            if (-not $entries.ContainsKey($eid)) { Add-Violation 'A2' $where "unknown entry $eid"; continue }
            Add-Coverage $eid $where
            [void]$needed.Add([string]$entries[$eid].item)
        }
        foreach ($it in @($needed | Sort-Object)) {
            if ($affected -notcontains $it) { Add-Violation 'A5' $where "affectedItems lacks item $it, which produced a covered entry" }
        }
        if (Test-Prop $q 'clusters') { foreach ($c in (Get-IdList $q 'clusters' $where)) { Add-ClusterUse $c $where "$where clusters" } }
    }

    # -- not consolidated --
    $n = 0
    foreach ($x in (Get-Array (Get-Prop $analysis 'notConsolidated'))) {
        $n++
        $eid = Get-IdText (Get-Prop $x 'entry')
        $where = if ($eid) { "notConsolidated $eid" } else { "notConsolidated[$n]" }
        $status = Get-Prop $x 'status'
        if ($status -notin @('family-local', 'discarded')) { Add-Violation 'A1' $where "status must be family-local or discarded, found '$status'" }
        if (-not (Test-Text (Get-Prop $x 'reason'))) { Add-Violation 'A1' $where "missing or empty 'reason'" }
        if (-not $eid) { Add-Violation 'A1' $where "missing 'entry'"; continue }
        if (-not $entries.ContainsKey($eid)) { Add-Violation 'A2' $where "unknown entry $eid"; continue }
        Add-Coverage $eid "$status"
    }

    # -- findings --
    $ffIds = @{}
    $n = 0
    foreach ($f in (Get-Array (Get-Prop $analysis 'findings'))) {
        $n++
        $fid = Get-IdText (Get-Prop $f 'id')
        $where = if ($fid) { $fid } else { "findings[$n]" }
        if (-not $fid -or $fid -notmatch '^FF-\d{2,}$') { Add-Violation 'A1' $where 'id must match FF-NN' }
        elseif ($ffIds.ContainsKey($fid)) { Add-Violation 'A1' $where 'duplicate id' }
        if ($fid) { $ffIds[$fid] = $true }
        $kind = Get-Prop $f 'kind'
        if ($kind -notin $kinds) { Add-Violation 'A1' $where "kind must be one of $($kinds -join ', '), found '$kind'" }
        foreach ($t in @('title', 'description')) { if (-not (Test-Text (Get-Prop $f $t))) { Add-Violation 'A1' $where "missing or empty '$t'" } }
        if ($kind -eq 'contradiction' -and (Test-Prop $f 'term') -and -not (Test-Text (Get-Prop $f 'term'))) {
            Add-Violation 'A1' $where "'term' is present but empty"
        }
        if (Test-Prop $f 'clusters') { foreach ($c in (Get-IdList $f 'clusters' $where)) { Add-ClusterUse $c $where "$where clusters" } }
        $links = @()
        if (Test-Prop $f 'consolidatedQuestions') { $links = Get-IdList $f 'consolidatedQuestions' $where }
        # CQ existence is checked after all CQs are known (below).
        $f | Add-Member -NotePropertyName '__links' -NotePropertyValue $links -Force

        $ev = Get-Array (Get-Prop $f 'evidence')
        if (-not (Test-Prop $f 'evidence')) { Add-Violation 'A1' $where "missing field 'evidence'" }
        $evFamilies = New-Object 'System.Collections.Generic.HashSet[string]'
        $k = 0
        foreach ($e in $ev) {
            $k++
            $ew = "$where evidence[$k]"
            $fam = Get-IdText (Get-Prop $e 'family')
            $item = Get-IdText (Get-Prop $e 'item')
            $sec = Get-Prop $e 'section'
            $num = Get-Prop $e 'number'
            if (-not $fam) { Add-Violation 'A1' $ew "missing 'family'"; continue }
            if (-not $item) { Add-Violation 'A1' $ew "missing 'item'"; continue }
            if (-not $famItems.ContainsKey($fam)) { Add-Violation 'A2' $ew "unknown family $fam"; continue }
            if (-not $famItems[$fam].Contains($item)) { Add-Violation 'A2' $ew "item $item does not belong to family $fam"; continue }
            [void]$evFamilies.Add($fam)
            if ($sec -notin $sections) { Add-Violation 'A1' $ew "section must be one of $($sections -join ', '), found '$sec'"; continue }
            if ($sec -in $numbered) {
                if (-not ($num -is [int] -or $num -is [long]) -or $num -lt 1) { Add-Violation 'A1' $ew "section $sec needs a positive integer 'number'"; continue }
                if ($sec -eq 'criterion') {
                    $crit = Get-Criteria $fam $item
                    # $crit is a HashSet[int] or a status string; never compare a set with -eq.
                    if ($crit -is [string] -and $crit -eq 'no-family') { $warnings.Add("${ew}: family folder $fam not found under $ReviewsRoot; criterion $num of #$item not verifiable.") }
                    elseif ($crit -is [string]) { Add-Violation 'A2' $ew "no proposal file for item $item in family folder $fam" }
                    elseif (-not $crit.Contains([int]$num)) { Add-Violation 'A2' $ew "criterion $num does not exist in the proposal of #$item" }
                } else {
                    $letter = if ($sec -eq 'question') { 'P' } else { 'S' }
                    $eid = "F$fam-WI$item-$letter$num"
                    if (-not $entries.ContainsKey($eid)) { Add-Violation 'A2' $ew "$sec $num of #$item does not exist (no entry $eid)" }
                }
            } elseif (-not (Test-Text (Get-Prop $e 'detail'))) {
                Add-Violation 'A1' $ew "section $sec needs a non-empty 'detail' (where in the $sec)"
            }
        }
        if ($kind -in $crossKinds -and $evFamilies.Count -lt 2) {
            Add-Violation 'A4' $where "$kind must cite evidence from 2 or more families, found $($evFamilies.Count)"
        }
        if ($kind -eq 'repeated-question') {
            if ($ev.Count -lt 2) { Add-Violation 'A4' $where 'repeated-question needs 2 or more evidence rows' }
            if ($links.Count -eq 0) { Add-Violation 'A4' $where 'repeated-question must link the consolidated question(s) that resolve it' }
        }
    }
    foreach ($f in (Get-Array (Get-Prop $analysis 'findings'))) {
        $fid = Get-IdText (Get-Prop $f 'id')
        foreach ($l in @($f.__links)) { if (-not $cqIds.ContainsKey($l)) { Add-Violation 'A2' "$fid" "unknown consolidated question $l" } }
    }

    # -- cluster reviews --
    $reviewed = @{}
    $n = 0
    foreach ($r in (Get-Array (Get-Prop $analysis 'clusterReviews'))) {
        $n++
        $cid = Get-IdText (Get-Prop $r 'cluster')
        $where = if ($cid) { "clusterReviews $cid" } else { "clusterReviews[$n]" }
        if (-not $cid) { Add-Violation 'A1' $where "missing 'cluster'"; continue }
        if (-not $clusters.ContainsKey($cid)) { Add-Violation 'A2' $where "unknown cluster $cid"; continue }
        if ($reviewed.ContainsKey($cid)) { Add-Violation 'A3' $where 'cluster reviewed more than once'; continue }
        $dec = Get-Prop $r 'decision'
        $reviewed[$cid] = $dec
        if ($dec -notin @('confirmed', 'discarded')) { Add-Violation 'A1' $where "decision must be confirmed or discarded, found '$dec'" }
        if (-not (Test-Text (Get-Prop $r 'reason'))) { Add-Violation 'A3' $where "missing or empty 'reason'" }
        $users = @(if ($clusterUse.ContainsKey($cid)) { $clusterUse[$cid] })
        if ($dec -eq 'confirmed' -and $users.Count -eq 0) { Add-Violation 'A3' $where 'confirmed but no finding or consolidated question cites it' }
        if ($dec -eq 'discarded' -and $users.Count -gt 0) { Add-Violation 'A3' $where "discarded but cited by $($users -join ', ')" }
    }
    foreach ($cid in $crossClusters) {
        if (-not $reviewed.ContainsKey($cid)) { Add-Violation 'A3' "cluster $cid" 'cross-family cluster without a review (confirm or discard it)' }
    }

    # -- coverage --
    foreach ($eid in $entryOrder) {
        $e = $entries[$eid]
        $holders = @(if ($coverage.ContainsKey($eid)) { $coverage[$eid] })
        if ($e.kind -eq 'pregunta' -and $holders.Count -eq 0) {
            Add-Violation 'A6' $eid 'question entry neither covered by a consolidated question nor listed in notConsolidated'
        }
        if ($holders.Count -gt 1) { Add-Violation 'A6' $eid "accounted for more than once: $($holders -join ', ')" }
    }
}

# ---- Report ----
$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$S) { [void]$sb.Append($S).Append("`n") }
function Esc([string]$S) { return ($S -replace '\|', '\|') }
$result = if ($violations.Count -eq 0) { 'OK' } else { "VIOLATIONS ($($violations.Count))" }
Add-Line '# Feature analysis check'
Add-Line "Folder: $AnalysisDir | Date: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC | Result: $result | Warnings: $($warnings.Count)"
Add-Line ''
Add-Line 'Checks: A1 schema, A2 references exist, A3 cluster reviews, A4 cross-family evidence, A5 affected items, A6 question coverage, A7 character rule.'
Add-Line ''
Add-Line '## Violations'
if ($violations.Count -eq 0) { Add-Line 'None.' } else {
    Add-Line '| Check | Where | Problem |'
    Add-Line '|---|---|---|'
    foreach ($v in $violations) { Add-Line "| $($v.Check) | $(Esc $v.Where) | $(Esc $v.Problem) |" }
}
Add-Line ''
Add-Line '## Warnings'
if ($warnings.Count -eq 0) { Add-Line 'None.' } else { foreach ($w in $warnings) { Add-Line "- $w" } }
Add-Line ''
Add-Line '## Entry coverage'
Add-Line 'Every candidate entry and where the analysis accounts for it (questions are mandatory, supuestos optional).'
Add-Line ''
Add-Line '| Entry | Accounted in |'
Add-Line '|---|---|'
foreach ($eid in $entryOrder) {
    $holders = if ($coverage.ContainsKey($eid)) { (@($coverage[$eid]) -join ', ') } elseif ($entries[$eid].kind -eq 'pregunta') { 'MISSING' } else { '-' }
    Add-Line "| $eid | $holders |"
}

[System.IO.File]::WriteAllText($Out, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "Feature analysis check: $result, $($warnings.Count) warning(s). Report: $Out"
if ($violations.Count -gt 0) { exit 1 } else { exit 0 }
