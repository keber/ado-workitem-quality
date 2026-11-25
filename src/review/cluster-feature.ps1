<#
.SYNOPSIS
  Deterministic candidate clusters of open questions, supuestos and pending terms across the
  families of one Feature (step 1 of the feature-level check).

.DESCRIPTION
  Reads the family review folders under -ReviewsRoot (<ReviewsRoot>/<usId>/proposal-WI-<id>.md;
  WI-<id>*.md also accepted) and extracts, per item:
  - open questions: numbered items under "Preguntas abiertas" (wrapped lines joined);
  - supuestos: table rows under "Supuestos propuestos" (column "Comportamiento propuesto");
  - terms: double-quoted strings of 1 to -MaxTermWords words inside those questions and supuestos
    (quotes inside [fuente: ...] or any other [...] marker are ignored).
  Folders whose name is not numeric (_archive, _feature-*, cache) are never read.

  Without -Families, a family is included when the "Padre" row of its User Story proposal
  (proposal-WI-<usId>.md) names "Feature #<FeatureId>". With -Families, the listed families are
  included as given and a foreign parent is reported as a warning.

  Similarity: text is lowercased, accents and punctuation removed, [...] markers and #ids
  dropped, Spanish stopwords and pipeline words removed, and a light suffix stem applied. For a
  question only the "?...?" segments
  are compared (the context sentences around them cite sources and add noise); a supuesto is
  compared whole. The stem strips a final "s", then a final a/e/o, on words longer than 3 letters. Similarity is an IDF-weighted Jaccard index: each word weighs ln(N/df), with N
  the number of distinct token sets among the extracted entries and df how many of them contain the
  word (distinct sets, so a User Story repeating its Tasks does not inflate df); similarity = weight
  of the shared words / weight of all words of the pair. Generic domain words (filtro, grilla,
  columna) then weigh little and specific ones (destinatario, permiso) a lot. Clustering is
  agglomerative with AVERAGE linkage: the two clusters with the highest average pairwise
  similarity merge while that average is >= -Threshold. Default 0.15, chosen on the first real
  feature (24 items, 194 entries): plain Jaccard left paraphrased cross-family questions at
  0.20-0.30 while generic words linked unrelated ones; single linkage chained clusters through one
  middle entry; average linkage at 0.20 lost the access-per-role and term-definition candidates,
  at 0.15 it kept them with no cluster above 7 entries except the repeated "usuario validador"
  question. This is a candidate generator: recall matters more than precision, the next stage
  discards. The weights depend on the corpus: adding or removing families changes them. Everything is sorted, there is
  no randomness: two runs on the same input produce byte-identical files.

  A term is "shared" when its stemmed word sequence appears (quoted or not) in the questions or
  supuestos of 2 or more families.

  Every entry ends in exactly one cluster (cross-family, intra-family or single); the script
  checks this invariant, so no question loses an item that produced it.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File src/review/cluster-feature.ps1 -ReviewsRoot reviews/<project> -FeatureId <id> [-Families 1,2,3] [-OutDir <dir>] [-Threshold 0.15] [-MaxTermWords 4]

.OUTPUTS
  <OutDir>/candidates.md and <OutDir>/candidates.json (default OutDir <ReviewsRoot>/_feature-<id>).
  Family files are never written; an OutDir inside a family folder is refused.
  Exit code: 0 ok, 1 coverage invariant broken (an entry lost or duplicated), 2 usage error.

.NOTES
  Pure ASCII on purpose: Windows PowerShell 5.1 parses BOM-less .ps1 files as Windows-1252.
  Proposal files are read as UTF-8; outputs are written as UTF-8 without BOM.
#>

param(
    [Parameter(Mandatory)][string]$ReviewsRoot,
    [Parameter(Mandatory)][string]$FeatureId,
    [string[]]$Families,
    [string]$OutDir,
    [double]$Threshold = 0.15,
    [int]$MaxTermWords = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Fail-Usage([string]$Message) {
    [Console]::Error.WriteLine("cluster-feature: $Message")
    exit 2
}

# ---- Arguments ----
if ($FeatureId -notmatch '^\d+$') { Fail-Usage "FeatureId must be numeric: $FeatureId" }
if (-not (Test-Path -LiteralPath $ReviewsRoot -PathType Container)) { Fail-Usage "ReviewsRoot not found: $ReviewsRoot" }
if ($Threshold -le 0 -or $Threshold -gt 1) { Fail-Usage "Threshold must be in (0, 1]: $Threshold" }
if ($MaxTermWords -lt 1) { Fail-Usage "MaxTermWords must be >= 1: $MaxTermWords" }
$ReviewsRoot = (Resolve-Path -LiteralPath $ReviewsRoot).Path

# "-Families 1,2,3" through -File arrives as ONE string (gotcha 9): split and validate.
$familyList = New-Object System.Collections.Generic.List[string]
if ($Families) {
    foreach ($part in ($Families -join ',') -split ',') {
        $p = $part.Trim()
        if ($p -eq '') { continue }
        if ($p -notmatch '^\d+$') { Fail-Usage "Family id must be numeric: $p" }
        if (-not $familyList.Contains($p)) { $familyList.Add($p) }
    }
}

# Every numeric folder is a family folder (included or not): output must never land in one.
$allFamilyDirs = @(Get-ChildItem -LiteralPath $ReviewsRoot -Directory | Where-Object { $_.Name -match '^\d+$' })
if (-not $OutDir) { $OutDir = Join-Path $ReviewsRoot "_feature-$FeatureId" }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
foreach ($d in $allFamilyDirs) {
    $fd = $d.FullName.TrimEnd('\', '/')
    if ($OutDir -eq $fd -or $OutDir.StartsWith($fd + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $OutDir.StartsWith($fd + '/', [StringComparison]::OrdinalIgnoreCase)) {
        Fail-Usage "OutDir is inside family folder $($d.Name); family files must never be written: $OutDir"
    }
}

# ---- Text helpers ----
function Read-Utf8Lines([string]$Path) {
    return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -split "`r?`n"
}

function Remove-Diacritics([string]$Text) {
    $d = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    return [regex]::Replace($d, '\p{Mn}', '').Normalize([System.Text.NormalizationForm]::FormC)
}

# Accent-free stopwords: Spanish function words, generic question verbs, and words that describe
# the review itself rather than the product.
$script:StopWords = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($w in @(
    'a','al','ante','bajo','con','contra','de','del','desde','durante','en','entre','hacia','hasta',
    'mediante','para','por','segun','sin','sobre','tras','el','la','las','lo','los','un','una','unos',
    'unas','y','e','o','u','ni','pero','sino','que','quien','quienes','cual','cuales','cuando','como',
    'donde','cuanto','cuantos','cuanta','cuantas','se','si','no','ya','su','sus','le','les','me','mi',
    'nos','es','son','ser','sea','sean','fue','esta','este','esto','estos','estas','ese','esa','eso',
    'esos','esas','hay','debe','deben','deberia','puede','pueden','tiene','tienen','hace','hacen',
    'mas','muy','tambien','solo','otro','otra','otros','otras','cada','todo','toda','todos','todas',
    'mismo','misma','mismos','mismas','entonces','porque','ejemplo','caso','hoy','dicho','dicha',
    'significa','quiere','decir','existe','existen','aplica','aplican','corresponde','corresponden',
    'pregunta','preguntas','criterio','criterios','supuesto','supuestos','task','tasks','user',
    'story','item','items','propone','propuesta','confirmar','confirma','fuente','contexto','rev',
    'alcance','definir','define','definido','definida','considerando','funcionalidad','actual',
    'actualmente','forma','parte','incluye','incluir'
)) { [void]$script:StopWords.Add($w) }

# Raw normalized words: markers [...] and #ids removed, lowercase, accent-free, no punctuation.
function Get-Words([string]$Text) {
    $t = [regex]::Replace($Text, '\[[^\]]*\]', ' ')
    $t = [regex]::Replace($t, '#\d+', ' ')
    $t = Remove-Diacritics $t.ToLowerInvariant()
    $t = [regex]::Replace($t, '[^a-z0-9]+', ' ')
    return @($t.Trim() -split ' ' | Where-Object { $_ -ne '' })
}

# Light Spanish suffix stem: plural "s", then final a/e/o, each only on words longer than 3 letters
# (roles -> role -> rol, cargadas -> cargada -> cargad).
function Get-Stem([string]$Word) {
    $w = $Word
    if ($w.Length -gt 3 -and $w.EndsWith('s')) { $w = $w.Substring(0, $w.Length - 1) }
    if ($w.Length -gt 3 -and 'aeo'.Contains($w.Substring($w.Length - 1))) { $w = $w.Substring(0, $w.Length - 1) }
    return $w
}

function Get-StemSequence([string]$Text) {
    return @(Get-Words $Text | ForEach-Object { Get-Stem $_ })
}

function Get-ContentSet([string]$Text) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($w in (Get-Words $Text)) {
        if ($w.Length -lt 3 -or $w -match '^\d+$' -or $script:StopWords.Contains($w)) { continue }
        [void]$set.Add((Get-Stem $w))
    }
    return , $set
}

$script:InvQ = [string][char]0x00BF
function Get-QuestionCore([string]$Text) {
    $clean = [regex]::Replace($Text, '\[[^\]]*\]', ' ')
    $segs = @([regex]::Matches($clean, [regex]::Escape($script:InvQ) + '([^?]*)\?') | ForEach-Object { $_.Groups[1].Value })
    if ($segs.Count -eq 0) { return $clean }
    return ($segs -join ' ')
}

# IDF-weighted Jaccard: weight of shared words / weight of the union. $script:Idf is set below.
function Get-Similarity($A, $B) {
    if ($A.Count -eq 0 -or $B.Count -eq 0) { return 0.0 }
    $inter = 0.0; $union = 0.0
    foreach ($x in $A) {
        $w = $script:Idf[$x]
        $union += $w
        if ($B.Contains($x)) { $inter += $w }
    }
    foreach ($x in $B) { if (-not $A.Contains($x)) { $union += $script:Idf[$x] } }
    if ($union -le 0) { return 0.0 }
    return $inter / $union
}

function Get-SectionKind([string]$Heading) {
    $h = Remove-Diacritics $Heading
    if ($h -match '^Preguntas abiertas') { return 'preg' }
    if ($h -match '^Supuestos propuestos') { return 'sup' }
    return 'other'
}

function Format-Num([double]$X) { return $X.ToString('0.00', $script:inv) }
$script:inv = $inv

function Sort-Ordinal([string[]]$Values) {
    $arr = [string[]]@($Values)
    [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return , $arr
}

# ---- Family selection ----
$warnings = New-Object System.Collections.Generic.List[string]

function Get-ParentFeature([string]$UsFile) {
    if (-not (Test-Path -LiteralPath $UsFile -PathType Leaf)) { return '' }
    foreach ($l in (Read-Utf8Lines $UsFile)) {
        if ($l -match '^\|\s*Padre\s*\|(.*)\|') {
            $m = [regex]::Match($Matches[1], 'Feature\s+#(\d+)')
            if ($m.Success) { return $m.Groups[1].Value }
            return ''
        }
    }
    return ''
}

function Get-ProposalFiles([string]$Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.md' |
        Where-Object { $_.Name -match '^(proposal-)?WI-\d+' } |
        Sort-Object @{ Expression = { [long]([regex]::Match($_.Name, 'WI-(\d+)').Groups[1].Value) } })
}

function Get-UsFile([string]$Dir, [string]$UsId) {
    $f = @(Get-ProposalFiles $Dir | Where-Object { [regex]::Match($_.Name, 'WI-(\d+)').Groups[1].Value -eq $UsId })
    if ($f.Count -gt 0) { return $f[0].FullName }
    return ''
}

$selected = New-Object System.Collections.Generic.List[object]
if ($familyList.Count -gt 0) {
    foreach ($id in $familyList) {
        $dir = Join-Path $ReviewsRoot $id
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Fail-Usage "Family folder not found: $dir" }
        $parent = Get-ParentFeature (Get-UsFile $dir $id)
        if ($parent -ne $FeatureId) {
            $shown = if ($parent) { "Feature #$parent" } else { 'no Feature parent found' }
            $warnings.Add("Family $id was listed explicitly but its User Story parent is $shown, not Feature #$FeatureId.")
        }
        $selected.Add([pscustomobject]@{ Id = $id; Dir = $dir; Parent = $parent })
    }
} else {
    foreach ($d in $allFamilyDirs) {
        $parent = Get-ParentFeature (Get-UsFile $d.FullName $d.Name)
        if ($parent -eq $FeatureId) { $selected.Add([pscustomobject]@{ Id = $d.Name; Dir = $d.FullName; Parent = $parent }) }
    }
}
$selected = @($selected | Sort-Object @{ Expression = { [long]$_.Id } })
if ($selected.Count -eq 0) { Fail-Usage "No family under $ReviewsRoot has Feature #$FeatureId as parent (use -Families to list them)." }

# ---- Extraction ----
$entries = New-Object System.Collections.Generic.List[object]
$familyInfo = New-Object System.Collections.Generic.List[object]

function New-Entry([string]$Family, [string]$Item, [string]$Kind, [int]$Number, [string]$Text) {
    $letter = if ($Kind -eq 'pregunta') { 'P' } else { 'S' }
    $core = if ($Kind -eq 'pregunta') { Get-QuestionCore $Text } else { $Text }
    return [pscustomobject]@{
        Id = "F$Family-WI$Item-$letter$Number"; Family = $Family; Item = $Item; Kind = $Kind
        Number = $Number; Text = $Text.Trim()
        Set = (Get-ContentSet $core)
        Seq = ' ' + ((Get-StemSequence $Text) -join ' ') + ' '
    }
}

foreach ($fam in $selected) {
    $files = @(Get-ProposalFiles $fam.Dir)
    if ($files.Count -eq 0) { $warnings.Add("Family $($fam.Id) has no proposal files.") }
    $nq = 0; $ns = 0; $items = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $item = [regex]::Match($f.Name, 'WI-(\d+)').Groups[1].Value
        $items.Add($item)
        $kind = 'other'
        $cur = $null
        $seen = @{}
        $flush = {
            if ($null -ne $cur) {
                $key = "$($cur.Kind)$($cur.Number)"
                if ($seen.ContainsKey($key)) {
                    $warnings.Add("$($fam.Id)/$($f.Name): duplicate $($cur.Kind) number $($cur.Number); both kept.")
                }
                $seen[$key] = $true
                $entries.Add((New-Entry $fam.Id $item $cur.Kind $cur.Number $cur.Text))
            }
        }
        foreach ($l in (Read-Utf8Lines $f.FullName)) {
            if ($l -match '^#{1,6}\s+(.+?)\s*$') {
                . $flush; $cur = $null
                $kind = Get-SectionKind $Matches[1]
                continue
            }
            if ($kind -eq 'preg') {
                if ($l -match '^\s*(\d+)\.\s+(.*)$') {
                    . $flush
                    $cur = [pscustomobject]@{ Kind = 'pregunta'; Number = [int]$Matches[1]; Text = $Matches[2].Trim() }
                    $nq++
                } elseif ($l -match '^\s*$' -or $l -match '^\s*\|') {
                    . $flush; $cur = $null
                } elseif ($null -ne $cur) {
                    $cur.Text = $cur.Text + ' ' + $l.Trim()
                }
            } elseif ($kind -eq 'sup') {
                if ($l -match '^\|\s*(\d+)\s*\|') {
                    $cells = $l.Trim().Trim('|').Split('|')
                    if ($cells.Count -ge 2) {
                        $entries.Add((New-Entry $fam.Id $item 'supuesto' ([int]$cells[0].Trim()) $cells[1].Trim()))
                        $ns++
                    }
                }
            }
        }
        . $flush; $cur = $null
    }
    $familyInfo.Add([pscustomobject]@{
        Id = $fam.Id; Parent = $fam.Parent; ParentMatches = ($fam.Parent -eq $FeatureId)
        Items = @($items); Questions = $nq; Supuestos = $ns
    })
}

if ($entries.Count -eq 0) { Fail-Usage "No questions or supuestos found in the selected families." }

$kindOrder = @{ 'pregunta' = 0; 'supuesto' = 1 }
$entryArr = @($entries | Sort-Object @{ Expression = { [long]$_.Family } }, @{ Expression = { [long]$_.Item } },
    @{ Expression = { $kindOrder[$_.Kind] } }, @{ Expression = { $_.Number } }, @{ Expression = { $_.Id } })
$n = $entryArr.Count

# ---- Word weights: IDF over the distinct token sets ----
$distinctSets = @{}
foreach ($e in $entryArr) { $distinctSets[((Sort-Ordinal @($e.Set)) -join ' ')] = $e.Set }
$df = @{}
foreach ($set in $distinctSets.Values) { foreach ($t in $set) { $df[$t] = 1 + $(if ($df.ContainsKey($t)) { $df[$t] } else { 0 }) } }
$script:Idf = @{}
foreach ($t in $df.Keys) { $script:Idf[$t] = [math]::Log([double]$distinctSets.Count / [double]$df[$t]) }

# ---- Clustering: average linkage over IDF-weighted Jaccard ----
# Agglomerative: start with one cluster per entry and repeatedly merge the pair of clusters with
# the highest AVERAGE pairwise similarity while it is >= Threshold (ties: lowest indices, from the
# fixed scan order). Average linkage, not single linkage: single linkage chained unrelated
# questions through one shared middle entry (e.g. stock minimum -> stock email -> plazo email).
$simMatrix = New-Object 'double[,]' $n, $n   # (not $S: PowerShell names ignore case, $s is a scalar)
for ($i = 0; $i -lt $n; $i++) {
    $simMatrix[$i, $i] = 1.0
    for ($j = $i + 1; $j -lt $n; $j++) {
        $s = Get-Similarity $entryArr[$i].Set $entryArr[$j].Set
        $simMatrix[$i, $j] = $s; $simMatrix[$j, $i] = $s
    }
}
$sum = New-Object 'double[,]' $n, $n      # sum of pairwise similarities between active clusters
$size = New-Object int[] $n
$active = New-Object bool[] $n
$members = New-Object 'System.Collections.Generic.List[int][]' $n
for ($i = 0; $i -lt $n; $i++) {
    $size[$i] = 1; $active[$i] = $true
    $members[$i] = New-Object System.Collections.Generic.List[int]; $members[$i].Add($i)
    for ($j = 0; $j -lt $n; $j++) { $sum[$i, $j] = $simMatrix[$i, $j] }
}
while ($true) {
    $bestA = -1; $bestB = -1; $best = -1.0
    for ($a = 0; $a -lt $n; $a++) {
        if (-not $active[$a]) { continue }
        for ($b = $a + 1; $b -lt $n; $b++) {
            if (-not $active[$b]) { continue }
            $sab = $sum[$a, $b]
            if ($sab -le 0) { continue }
            $avg = $sab / ($size[$a] * $size[$b])
            if ($avg -gt $best) { $best = $avg; $bestA = $a; $bestB = $b }
        }
    }
    if ($bestA -lt 0 -or $best -lt $Threshold) { break }
    for ($c = 0; $c -lt $n; $c++) {
        if (-not $active[$c] -or $c -eq $bestA -or $c -eq $bestB) { continue }
        $v = $sum[$bestA, $c] + $sum[$bestB, $c]
        $sum[$bestA, $c] = $v; $sum[$c, $bestA] = $v
    }
    $size[$bestA] += $size[$bestB]
    $members[$bestA].AddRange($members[$bestB])
    $active[$bestB] = $false
}

$clusters = New-Object System.Collections.Generic.List[object]
for ($r = 0; $r -lt $n; $r++) {
    if (-not $active[$r]) { continue }
    $mem = @($members[$r] | Sort-Object)
    $fams = @($mem | ForEach-Object { $entryArr[$_].Family } | Sort-Object -Unique @{ Expression = { [long]$_ } })
    $scope = if ($fams.Count -ge 2) { 'cross-family' } elseif ($mem.Count -ge 2) { 'intra-family' } else { 'single' }
    $minS = 1.0; $maxS = 1.0; $avgS = 1.0
    if ($mem.Count -ge 2) {
        $minS = 1.0; $maxS = 0.0; $tot = 0.0; $pairs = 0
        for ($a = 0; $a -lt $mem.Count; $a++) {
            for ($b = $a + 1; $b -lt $mem.Count; $b++) {
                $s = $simMatrix[$mem[$a], $mem[$b]]
                if ($s -lt $minS) { $minS = $s }
                if ($s -gt $maxS) { $maxS = $s }
                $tot += $s; $pairs++
            }
        }
        $avgS = $tot / $pairs
    }
    $clusters.Add([pscustomobject]@{
        Members = $mem; First = $mem[0]; Families = $fams; Scope = $scope; Min = $minS; Max = $maxS; Avg = $avgS
    })
}
$clusters = @($clusters | Sort-Object @{ Expression = { $_.Families.Count }; Descending = $true },
    @{ Expression = { $_.Members.Count }; Descending = $true }, @{ Expression = { $_.First } })
for ($c = 0; $c -lt $clusters.Count; $c++) {
    $clusters[$c] | Add-Member -NotePropertyName Id -NotePropertyValue ('C' + ($c + 1).ToString('000', $inv))
}

# Coverage invariant: every entry in exactly one cluster.
$count = @{}
foreach ($cl in $clusters) { foreach ($m in $cl.Members) { $count[$m] = 1 + $(if ($count.ContainsKey($m)) { $count[$m] } else { 0 }) } }
$coverageOk = ($count.Count -eq $n) -and (@($count.Values | Where-Object { $_ -ne 1 }).Count -eq 0)

# ---- Terms ----
$termMap = @{}
foreach ($e in $entryArr) {
    $clean = [regex]::Replace($e.Text, '\[[^\]]*\]', ' ')
    foreach ($m in [regex]::Matches($clean, '"([^"]{1,120})"')) {
        $raw = $m.Groups[1].Value.Trim()
        $words = @(Get-Words $raw)
        if ($words.Count -eq 0 -or $words.Count -gt $MaxTermWords) { continue }
        if (@($words | Where-Object { -not $script:StopWords.Contains($_) -and $_ -notmatch '^\d+$' }).Count -eq 0) { continue }
        $key = (@($words | ForEach-Object { Get-Stem $_ }) -join ' ')
        if (-not $termMap.ContainsKey($key)) {
            # Case-sensitive dictionary for variants: PowerShell hashtables ignore case.
            $termMap[$key] = [pscustomobject]@{ Key = $key; Forms = @{}; QuotedIn = @{}
                Variants = (New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::Ordinal)) }
        }
        $t = $termMap[$key]
        $form = $words -join ' '
        $t.Forms[$form] = 1 + $(if ($t.Forms.ContainsKey($form)) { $t.Forms[$form] } else { 0 })
        $t.Variants[$raw] = $true
        $t.QuotedIn[$e.Id] = $true
    }
}
$terms = New-Object System.Collections.Generic.List[object]
foreach ($key in (Sort-Ordinal @($termMap.Keys))) {
    $t = $termMap[$key]
    $best = $null
    foreach ($f in (Sort-Ordinal @($t.Forms.Keys))) { if ($null -eq $best -or $t.Forms[$f] -gt $t.Forms[$best]) { $best = $f } }
    $needle = " $key "
    $src = @($entryArr | Where-Object { $_.Seq.Contains($needle) -or $t.QuotedIn.ContainsKey($_.Id) })
    $fams = @($src | ForEach-Object { $_.Family } | Sort-Object -Unique @{ Expression = { [long]$_ } })
    $terms.Add([pscustomobject]@{
        Term = $best; Key = $key; Variants = (Sort-Ordinal @($t.Variants.Keys))
        Families = $fams; Sources = @($src | ForEach-Object { $_.Id })
        QuotedIn = @($entryArr | Where-Object { $t.QuotedIn.ContainsKey($_.Id) } | ForEach-Object { $_.Id })
    })
}
$shared = @($terms | Where-Object { $_.Families.Count -ge 2 } |
    Sort-Object @{ Expression = { $_.Families.Count }; Descending = $true }, @{ Expression = { $_.Sources.Count }; Descending = $true },
        @{ Expression = { $_.Key } })

# ---- JSON sidecar ----
$byIdx = @{}; for ($i = 0; $i -lt $n; $i++) { $byIdx[$entryArr[$i].Id] = $entryArr[$i] }
$json = [ordered]@{
    featureId = $FeatureId
    threshold = $Threshold
    maxTermWords = $MaxTermWords
    method = 'IDF-weighted Jaccard over stemmed content words (question: inverted-question segments only), average linkage'
    coverageOk = $coverageOk
    warnings = @($warnings)
    families = @($familyInfo | ForEach-Object { [ordered]@{
        id = $_.Id; parent = $_.Parent; parentMatches = $_.ParentMatches; items = @($_.Items)
        questions = $_.Questions; supuestos = $_.Supuestos } })
    entries = @($entryArr | ForEach-Object { [ordered]@{
        id = $_.Id; family = $_.Family; item = $_.Item; kind = $_.Kind; number = $_.Number; text = $_.Text
        tokens = (Sort-Ordinal @($_.Set)) } })
    clusters = @($clusters | ForEach-Object { $cl = $_; [ordered]@{
        id = $cl.Id; scope = $cl.Scope; families = @($cl.Families)
        minSimilarity = [math]::Round($cl.Min, 4); avgSimilarity = [math]::Round($cl.Avg, 4); maxSimilarity = [math]::Round($cl.Max, 4)
        entries = @($cl.Members | ForEach-Object { $entryArr[$_].Id }) } })
    terms = @($terms | ForEach-Object { [ordered]@{
        term = $_.Term; key = $_.Key; variants = @($_.Variants); families = @($_.Families)
        quotedIn = @($_.QuotedIn); sources = @($_.Sources) } })
    sharedTerms = @($shared | ForEach-Object { [ordered]@{
        term = $_.Term; key = $_.Key; variants = @($_.Variants); families = @($_.Families)
        quotedIn = @($_.QuotedIn); sources = @($_.Sources) } })
}

# ---- Markdown report ----
function Esc([string]$S) { return ($S -replace '\|', '\|') }
function Format-Source($E) { return "#$($E.Item) $(if ($E.Kind -eq 'pregunta') { 'P' } else { 'S' })$($E.Number)" }

$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$S) { [void]$sb.Append($S).Append("`n") }
function Add-EntryTable($Members) {
    Add-Line '| Family | Item | Kind | N | Text |'
    Add-Line '|---|---|---|---|---|'
    foreach ($m in $Members) {
        $e = $entryArr[$m]
        Add-Line "| $($e.Family) | #$($e.Item) | $($e.Kind) | $($e.Number) | $(Esc $e.Text) |"
    }
}

$cross = @($clusters | Where-Object { $_.Scope -eq 'cross-family' })
$intra = @($clusters | Where-Object { $_.Scope -eq 'intra-family' })
$single = @($clusters | Where-Object { $_.Scope -eq 'single' })
$totQ = @($entryArr | Where-Object { $_.Kind -eq 'pregunta' }).Count
$totS = $n - $totQ

Add-Line "# Feature candidate clusters - Feature #$FeatureId"
Add-Line ''
Add-Line 'Generated by `src/review/cluster-feature.ps1` from the family proposals, which it never modifies.'
Add-Line 'A cluster is a CANDIDATE (similar wording), not a confirmed finding: the feature analyst confirms or discards it.'
Add-Line ''
Add-Line '| Parameter | Value |'
Add-Line '|---|---|'
Add-Line "| Reviews root | $ReviewsRoot |"
Add-Line "| Similarity | IDF-weighted Jaccard over stemmed content words; questions compared by their question segments only |"
Add-Line "| Threshold (average linkage) | $(Format-Num $Threshold) |"
Add-Line "| Max words per term | $MaxTermWords |"
Add-Line ''
Add-Line '## Families parsed'
Add-Line '| Family | Parent | Items | Questions | Supuestos |'
Add-Line '|---|---|---|---|---|'
foreach ($fi in $familyInfo) {
    $p = if ($fi.Parent) { "Feature #$($fi.Parent)" } else { '(none found)' }
    if (-not $fi.ParentMatches) { $p = "$p (not #$FeatureId)" }
    Add-Line "| $($fi.Id) | $p | $((@($fi.Items) | ForEach-Object { "#$_" }) -join ', ') | $($fi.Questions) | $($fi.Supuestos) |"
}
Add-Line ''
Add-Line '## Warnings'
if ($warnings.Count -eq 0) { Add-Line 'None.' } else { foreach ($w in $warnings) { Add-Line "- $w" } }
Add-Line ''
Add-Line '## Summary'
Add-Line "- Entries: $n ($totQ questions, $totS supuestos)."
Add-Line "- Clusters: $($cross.Count) cross-family, $($intra.Count) intra-family, $($single.Count) single entries."
Add-Line "- Shared terms (2+ families): $($shared.Count)."
Add-Line "- Coverage (every entry in exactly one cluster): $(if ($coverageOk) { 'OK' } else { 'BROKEN' })."
Add-Line ''
Add-Line "## Cross-family candidate clusters ($($cross.Count))"
foreach ($cl in $cross) {
    Add-Line ''
    Add-Line "### $($cl.Id) - families $($cl.Families -join ', ') - $($cl.Members.Count) entries - pair similarity min $(Format-Num $cl.Min), avg $(Format-Num $cl.Avg), max $(Format-Num $cl.Max)"
    Add-EntryTable $cl.Members
}
Add-Line ''
Add-Line "## Intra-family groups ($($intra.Count))"
Add-Line 'Same question or supuesto repeated inside one family (typically a User Story repeating its Tasks).'
foreach ($cl in $intra) {
    Add-Line ''
    Add-Line "### $($cl.Id) - family $($cl.Families[0]) - $($cl.Members.Count) entries - pair similarity min $(Format-Num $cl.Min), avg $(Format-Num $cl.Avg), max $(Format-Num $cl.Max)"
    Add-EntryTable $cl.Members
}
Add-Line ''
Add-Line "## Single entries ($($single.Count))"
if ($single.Count -gt 0) {
    Add-Line '| Cluster | Family | Item | Kind | N | Text |'
    Add-Line '|---|---|---|---|---|---|'
    foreach ($cl in $single) {
        $e = $entryArr[$cl.Members[0]]
        Add-Line "| $($cl.Id) | $($e.Family) | #$($e.Item) | $($e.Kind) | $($e.Number) | $(Esc $e.Text) |"
    }
}
Add-Line ''
Add-Line "## Shared terms ($($shared.Count))"
Add-Line 'Quoted terms whose wording appears (quoted or not) in the questions or supuestos of 2 or more families.'
if ($shared.Count -gt 0) {
    Add-Line ''
    Add-Line '| Term | Quoted as | Families | Sources |'
    Add-Line '|---|---|---|---|'
    foreach ($t in $shared) {
        $srcText = @(foreach ($fid in $t.Families) {
            "${fid}: " + ((@($t.Sources | Where-Object { $byIdx[$_].Family -eq $fid }) | ForEach-Object { Format-Source $byIdx[$_] }) -join ', ')
        }) -join '; '
        $vars = (@($t.Variants) | ForEach-Object { '"' + $_ + '"' }) -join ', '
        Add-Line "| $(Esc $t.Term) | $(Esc $vars) | $($t.Families -join ', ') | $srcText |"
    }
}

# ---- Write ----
[void][System.IO.Directory]::CreateDirectory($OutDir)
$enc = [System.Text.UTF8Encoding]::new($false)
$mdPath = Join-Path $OutDir 'candidates.md'
$jsonPath = Join-Path $OutDir 'candidates.json'
[System.IO.File]::WriteAllText($mdPath, $sb.ToString(), $enc)
[System.IO.File]::WriteAllText($jsonPath, ($json | ConvertTo-Json -Depth 8) + "`n", $enc)

Write-Host ("Feature candidates: {0} entries, {1} cross-family, {2} intra-family, {3} single, {4} shared terms. Report: {5}" -f
    $n, $cross.Count, $intra.Count, $single.Count, $shared.Count, $mdPath)
if (-not $coverageOk) {
    [Console]::Error.WriteLine('cluster-feature: coverage invariant broken (an entry is missing or duplicated in the clusters).')
    exit 1
}
exit 0
