<#
  Pester 5 tests for src/review/check-feature-analysis.ps1.
  Run: powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/review -Output Detailed"
  Fixtures:
  - tests/fixtures/feature-1000: synthetic family proposals (Feature 1000).
  - tests/fixtures/feature-1000-analysis/candidates.json: output of cluster-feature.ps1 on that
    fixture (a drift test below regenerates it and compares).
  - tests/fixtures/feature-1000-analysis/analysis.json: hand-written VALID analysis; every invalid
    case is a mutation of it built in the test.
  Pure ASCII on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 files as Windows-1252).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Script = Join-Path $RepoRoot 'src\review\check-feature-analysis.ps1'
    $script:ClusterScript = Join-Path $RepoRoot 'src\review\cluster-feature.ps1'
    $script:FamiliesFixture = Join-Path $RepoRoot 'tests\fixtures\feature-1000'
    $script:AnalysisFixture = Join-Path $RepoRoot 'tests\fixtures\feature-1000-analysis'
    $script:Utf8 = [System.Text.UTF8Encoding]::new($false)

    # Reviews root copy: family folders plus _feature-1000 with candidates.json and analysis.json.
    function New-Workspace {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:FamiliesFixture -Destination $root -Recurse
        $dir = Join-Path $root '_feature-1000'
        [void][System.IO.Directory]::CreateDirectory($dir)
        Copy-Item -LiteralPath (Join-Path $script:AnalysisFixture 'candidates.json') -Destination $dir
        Copy-Item -LiteralPath (Join-Path $script:AnalysisFixture 'analysis.json') -Destination $dir
        return [pscustomobject]@{ Root = $root; Dir = $dir }
    }

    function Invoke-Check([string[]]$Arguments) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Script @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    }

    function Read-Text([string]$Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }

    function Read-Analysis([string]$Dir) { return (Read-Text (Join-Path $Dir 'analysis.json') | ConvertFrom-Json) }

    function Write-Analysis([string]$Dir, $Obj) {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'analysis.json'), ($Obj | ConvertTo-Json -Depth 12), $script:Utf8)
    }

    # Runs the validator on a mutated copy of the valid analysis. $Mutate receives the parsed object.
    function Invoke-Variant([scriptblock]$Mutate) {
        $ws = New-Workspace
        $a = Read-Analysis $ws.Dir
        & $Mutate $a
        Write-Analysis $ws.Dir $a
        $r = Invoke-Check @('-AnalysisDir', $ws.Dir)
        $reportPath = Join-Path $ws.Dir 'analysis-check.md'
        $report = if (Test-Path -LiteralPath $reportPath) { Read-Text $reportPath } else { '' }
        return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Report = $report }
    }

    function Get-Finding($A, [string]$Id) { return @($A.findings | Where-Object { $_.id -eq $Id })[0] }
    function Get-Cq($A, [string]$Id) { return @($A.consolidatedQuestions | Where-Object { $_.id -eq $Id })[0] }

    function Get-FileHashes([string]$Root) {
        $h = @{}
        Get-ChildItem -LiteralPath $Root -Recurse -File |
            Where-Object { $_.Name -ne 'analysis-check.md' } |
            ForEach-Object { $h[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        return $h
    }

    # One run on the valid analysis, shared by the read-only assertions.
    $script:Valid = New-Workspace
    $script:ValidRun = Invoke-Check @('-AnalysisDir', $script:Valid.Dir)
    $script:ValidReport = Read-Text (Join-Path $script:Valid.Dir 'analysis-check.md')
}

Describe 'check-feature-analysis.ps1' {

    Context 'fixture integrity' {
        It 'the committed candidates.json matches a fresh cluster-feature run on the family fixture' {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $FamiliesFixture -Destination $root -Recurse
            $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $ClusterScript -ReviewsRoot $root -FeatureId 1000 2>&1
            $LASTEXITCODE | Should -Be 0
            $fresh = (Read-Text (Join-Path $root '_feature-1000\candidates.json')) -replace "`r`n", "`n"
            $committed = (Read-Text (Join-Path $AnalysisFixture 'candidates.json')) -replace "`r`n", "`n"
            $fresh | Should -BeExactly $committed
        }
    }

    Context 'valid analysis' {
        It 'exits 0 and writes analysis-check.md with result OK' {
            $ValidRun.ExitCode | Should -Be 0 -Because $ValidRun.Output
            $ValidReport | Should -Match 'Result: OK'
        }

        It 'reports the coverage of every candidate question entry' {
            $ValidReport | Should -Match 'F1001-WI1001-P2 \| CQ-01'
            $ValidReport | Should -Match 'F3001-WI3001-P1 \| family-local'
        }

        It 'leaves analysis.json, candidates.json and family files untouched' {
            $ws = New-Workspace
            $before = Get-FileHashes $ws.Root
            $r = Invoke-Check @('-AnalysisDir', $ws.Dir)
            $r.ExitCode | Should -Be 0
            $after = Get-FileHashes $ws.Root
            $after.Count | Should -Be $before.Count
            foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] -Because $k }
        }

        It 'writes the report to -Out when given' {
            $ws = New-Workspace
            $out = Join-Path $ws.Root 'custom-check.md'
            (Invoke-Check @('-AnalysisDir', $ws.Dir, '-Out', $out)).ExitCode | Should -Be 0
            Test-Path -LiteralPath $out | Should -BeTrue
        }

        It 'still passes after a parse/serialize round trip (so mutation failures come from the mutation)' {
            $r = Invoke-Variant { param($a) $a.notConsolidated = @($a.notConsolidated) + @() }
            $r.ExitCode | Should -Be 0 -Because $r.Report
        }

        It 'warns, without failing, when feature-report.md is missing' {
            $ValidReport | Should -Match 'feature-report.md'
        }
    }

    Context '(a) cross-family findings cite every family' {
        It 'fails a dependency whose evidence comes from one family only' {
            $r = Invoke-Variant { param($a) $f = Get-Finding $a 'FF-04'; $f.evidence = @($f.evidence[0]) }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'FF-04'
        }

        It 'fails an overlap whose evidence is all in one family' {
            $r = Invoke-Variant { param($a) $f = Get-Finding $a 'FF-03'; $f.evidence = @($f.evidence | Where-Object { $_.family -eq '2001' }) }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'FF-03'
        }

        It 'fails a repeated-question finding that links no consolidated question' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-02').consolidatedQuestions = @() }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'FF-02'
        }
    }

    Context '(b) consolidated questions keep every affected item' {
        It 'fails when an item that produced a covered entry is missing from affectedItems' {
            $r = Invoke-Variant { param($a) (Get-Cq $a 'CQ-02').affectedItems = @('1001', '2001') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'CQ-02'
            $r.Report | Should -Match '1002'
        }
    }

    Context '(c) every candidate question entry accounted for exactly once' {
        It 'fails when a question entry is neither consolidated nor kept local' {
            $r = Invoke-Variant { param($a) $a.notConsolidated = @($a.notConsolidated | Where-Object { $_.entry -ne 'F3001-WI3001-P1' }) }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'F3001-WI3001-P1'
        }

        It 'fails when a question entry is both consolidated and kept local' {
            $r = Invoke-Variant { param($a)
                $a.notConsolidated = @($a.notConsolidated) + @([pscustomobject]@{ entry = 'F2001-WI2001-P1'; status = 'family-local'; reason = 'x' }) }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'F2001-WI2001-P1'
        }

        It 'fails when a question entry is covered by two consolidated questions' {
            $r = Invoke-Variant { param($a) $q = Get-Cq $a 'CQ-03'; $q.entries = @($q.entries) + @('F1001-WI1001-P3'); $q.affectedItems = @($q.affectedItems) + @('1001') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'F1001-WI1001-P3'
        }

        It 'fails a not-consolidated entry without a reason' {
            $r = Invoke-Variant { param($a) @($a.notConsolidated)[0].reason = '' }
            $r.ExitCode | Should -Be 1
        }

        It 'fails a not-consolidated entry with an unknown status' {
            $r = Invoke-Variant { param($a) @($a.notConsolidated)[0].status = 'ignored' }
            $r.ExitCode | Should -Be 1
        }
    }

    Context '(d) cited ids exist in candidates.json and the family folders' {
        It 'fails an unknown entry id in a consolidated question' {
            $r = Invoke-Variant { param($a) $q = Get-Cq $a 'CQ-01'; $q.entries = @($q.entries) + @('F1001-WI1001-P99') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'F1001-WI1001-P99'
        }

        It 'fails an unknown family in evidence' {
            $r = Invoke-Variant { param($a) @((Get-Finding $a 'FF-04').evidence)[1].family = '5555' }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match '5555'
        }

        It 'fails an item that does not belong to the cited family' {
            $r = Invoke-Variant { param($a) @((Get-Finding $a 'FF-04').evidence)[1].item = '2002' }
            $r.ExitCode | Should -Be 1
        }

        It 'fails an unknown affected item' {
            $r = Invoke-Variant { param($a) $q = Get-Cq $a 'CQ-01'; $q.affectedItems = @($q.affectedItems) + @('7777') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match '7777'
        }

        It 'fails an unknown cluster id' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-04').clusters = @('C999') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'C999'
        }

        It 'fails evidence citing a question number that does not exist for that item' {
            $r = Invoke-Variant { param($a) @((Get-Finding $a 'FF-02').evidence)[2].number = 9 }
            $r.ExitCode | Should -Be 1
        }

        It 'fails evidence citing a criterion that does not exist in the proposal' {
            $r = Invoke-Variant { param($a) @((Get-Finding $a 'FF-04').evidence)[0].number = 7 }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'criterion 7'
        }

        It 'fails a non-numeric section without detail' {
            $r = Invoke-Variant { param($a) @((Get-Finding $a 'FF-03').evidence)[0].detail = '' }
            $r.ExitCode | Should -Be 1
        }
    }

    Context 'cluster reviews' {
        It 'fails when a cross-family cluster has no review' {
            $r = Invoke-Variant { param($a) $a.clusterReviews = @($a.clusterReviews | Where-Object { $_.cluster -ne 'C004' }) }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'C004'
        }

        It 'fails a cluster reviewed twice' {
            $r = Invoke-Variant { param($a) $a.clusterReviews = @($a.clusterReviews) + @(@($a.clusterReviews)[0]) }
            $r.ExitCode | Should -Be 1
        }

        It 'fails a review without a reason' {
            $r = Invoke-Variant { param($a) @($a.clusterReviews)[2].reason = ' ' }
            $r.ExitCode | Should -Be 1
        }

        It 'fails a confirmed cluster that no finding or consolidated question uses' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-03').clusters = @(); (Get-Cq $a 'CQ-03').clusters = @() }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'C004'
        }

        It 'fails a discarded cluster that a finding still uses' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-04').clusters = @('C003') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'C003'
        }
    }

    Context '(e) schema well-formed' {
        It 'fails an unknown finding kind' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-01').kind = 'conflict' }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'conflict'
        }

        It 'fails a featureId that does not match candidates.json' {
            $r = Invoke-Variant { param($a) $a.featureId = '2000' }
            $r.ExitCode | Should -Be 1
        }

        It 'fails a missing top-level section' {
            $r = Invoke-Variant { param($a) $a.PSObject.Properties.Remove('notConsolidated') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'notConsolidated'
        }

        It 'fails duplicate finding ids' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-02').id = 'FF-01' }
            $r.ExitCode | Should -Be 1
        }

        It 'fails a malformed id' {
            $r = Invoke-Variant { param($a) (Get-Cq $a 'CQ-03').id = 'Q3' }
            $r.ExitCode | Should -Be 1
        }

        It 'fails a link to a consolidated question that does not exist' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-01').consolidatedQuestions = @('CQ-09') }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'CQ-09'
        }

        It 'fails a forbidden character (em dash) in the analysis text' {
            $r = Invoke-Variant { param($a) (Get-Finding $a 'FF-01').title = 'A ' + [char]0x2014 + ' B' }
            $r.ExitCode | Should -Be 1
            $r.Report | Should -Match 'U\+2014'
        }

        It 'fails unparseable JSON with exit 1 and a report' {
            $ws = New-Workspace
            [System.IO.File]::WriteAllText((Join-Path $ws.Dir 'analysis.json'), '{ "featureId": ', $Utf8)
            $r = Invoke-Check @('-AnalysisDir', $ws.Dir)
            $r.ExitCode | Should -Be 1
            Test-Path -LiteralPath (Join-Path $ws.Dir 'analysis-check.md') | Should -BeTrue
        }
    }

    Context 'usage errors' {
        It 'exits 2 when the analysis folder does not exist' {
            (Invoke-Check @('-AnalysisDir', (Join-Path $TestDrive 'missing'))).ExitCode | Should -Be 2
        }

        It 'exits 2 when analysis.json is missing' {
            $ws = New-Workspace
            Remove-Item -LiteralPath (Join-Path $ws.Dir 'analysis.json')
            (Invoke-Check @('-AnalysisDir', $ws.Dir)).ExitCode | Should -Be 2
        }

        It 'exits 2 when candidates.json is missing' {
            $ws = New-Workspace
            Remove-Item -LiteralPath (Join-Path $ws.Dir 'candidates.json')
            (Invoke-Check @('-AnalysisDir', $ws.Dir)).ExitCode | Should -Be 2
        }

        It 'refuses a report path inside a family folder (exit 2, nothing written)' {
            $ws = New-Workspace
            $out = Join-Path $ws.Root '1001\analysis-check.md'
            (Invoke-Check @('-AnalysisDir', $ws.Dir, '-Out', $out)).ExitCode | Should -Be 2
            Test-Path -LiteralPath $out | Should -BeFalse
        }
    }
}
