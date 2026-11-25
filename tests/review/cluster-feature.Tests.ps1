<#
  Pester 5 tests for src/review/cluster-feature.ps1.
  Run: powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/review -Output Detailed"
  Fixtures: tests/fixtures/feature-1000 (synthetic, Feature 1000; family 4001 belongs to Feature 9999).
  Pure ASCII on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 files as Windows-1252).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Script = Join-Path $RepoRoot 'src\review\cluster-feature.ps1'
    $script:FixtureRoot = Join-Path $RepoRoot 'tests\fixtures\feature-1000'

    function New-FixtureCopy {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:FixtureRoot -Destination $dest -Recurse
        return $dest
    }

    function Invoke-Cluster([string[]]$Arguments) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Script @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    }

    function Read-Json([string]$Path) {
        return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }

    function Get-FileHashes([string]$Root) {
        $h = @{}
        Get-ChildItem -LiteralPath $Root -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]_feature-' } |
            ForEach-Object { $h[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        return $h
    }

    function Get-ClusterOf($Json, [string]$EntryId) {
        return @($Json.clusters | Where-Object { @($_.entries) -contains $EntryId })
    }

    # One run shared by the read-only assertions.
    $script:Root = New-FixtureCopy
    $script:Run = Invoke-Cluster @('-ReviewsRoot', $script:Root, '-FeatureId', '1000')
    $script:OutDir = Join-Path $script:Root '_feature-1000'
    $script:Json = Read-Json (Join-Path $script:OutDir 'candidates.json')
    $script:Md = [System.IO.File]::ReadAllText((Join-Path $script:OutDir 'candidates.md'), [System.Text.Encoding]::UTF8)
}

Describe 'cluster-feature.ps1' {

    Context 'discovery and extraction' {
        It 'exits 0 and writes candidates.md and candidates.json in _feature-<id>' {
            $Run.ExitCode | Should -Be 0
            Test-Path (Join-Path $OutDir 'candidates.md') | Should -BeTrue
            Test-Path (Join-Path $OutDir 'candidates.json') | Should -BeTrue
        }

        It 'includes only families whose User Story parent is the Feature, and ignores _archive' {
            @($Json.families | ForEach-Object { $_.id }) | Should -Be @('1001', '2001', '3001')
        }

        It 'extracts every question and supuesto per family' {
            $f = @{}; foreach ($x in $Json.families) { $f[$x.id] = $x }
            $f['1001'].questions | Should -Be 7
            $f['1001'].supuestos | Should -Be 1
            $f['2001'].questions | Should -Be 5
            $f['2001'].supuestos | Should -Be 1
            $f['3001'].questions | Should -Be 4
            $f['3001'].supuestos | Should -Be 1
            @($Json.entries).Count | Should -Be 19
        }

        It 'joins a question wrapped over two lines' {
            $e = @($Json.entries | Where-Object { $_.id -eq 'F2001-WI2001-P2' })
            $e.Count | Should -Be 1
            $e[0].text | Should -Match 'reactiva cuando llega el repuesto'
        }

        It 'records family, item, kind and number for each entry' {
            $e = @($Json.entries | Where-Object { $_.id -eq 'F1001-WI1001-S1' })[0]
            $e.family | Should -Be '1001'
            $e.item | Should -Be '1001'
            $e.kind | Should -Be 'supuesto'
            $e.number | Should -Be 1
        }
    }

    Context 'clustering' {
        It 'finds the cross-family cluster on roles (1001 and 2001)' {
            $c = @(Get-ClusterOf $Json 'F2001-WI2001-P1')
            $c.Count | Should -Be 1
            $c[0].scope | Should -Be 'cross-family'
            @($c[0].families) | Should -Be @('1001', '2001')
        }

        It 'keeps every source of an intra-family duplicate (US repeats its Task question)' {
            $c = @(Get-ClusterOf $Json 'F1001-WI1001-P3')[0]
            @($c.entries) | Should -Contain 'F1001-WI1002-P1'
            @($c.entries) | Should -Contain 'F2001-WI2001-P1'
            $c3 = @(Get-ClusterOf $Json 'F3001-WI3001-P2')[0]
            @($c3.entries) | Should -Contain 'F3001-WI3002-P1'
            $c3.scope | Should -Be 'intra-family'
        }

        It 'does not merge unrelated questions' {
            $a = @(Get-ClusterOf $Json 'F3001-WI3001-P1')[0]
            @($a.entries) | Should -Not -Contain 'F1001-WI1001-P1'
            $a.scope | Should -Be 'single'
            $b = @(Get-ClusterOf $Json 'F1001-WI1001-P1')[0]
            @($b.entries) | Should -Not -Contain 'F1001-WI1001-P3'
        }

        It 'places every entry in exactly one cluster (no source lost)' {
            foreach ($e in $Json.entries) { @(Get-ClusterOf $Json $e.id).Count | Should -Be 1 -Because $e.id }
        }

        It 'lists every source of a cross-family cluster in the Markdown report' {
            $Md | Should -Match '## Cross-family candidate clusters'
            $Md | Should -Match '\| 1001 \| #1002 \| pregunta \| 1 \|'
            $Md | Should -Match '\| 2001 \| #2001 \| pregunta \| 1 \|'
        }

        It 'merges less with a higher threshold' {
            $root = New-FixtureCopy
            $r = Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '1000', '-Threshold', '0.95')
            $r.ExitCode | Should -Be 0
            $j = Read-Json (Join-Path $root '_feature-1000\candidates.json')
            $j.threshold | Should -Be 0.95
            @(Get-ClusterOf $j 'F2001-WI2001-P1')[0].scope | Should -Be 'single'
        }
    }

    Context 'shared terms' {
        It 'reports a quoted term used in 2+ families, also when mentioned without quotes' {
            $t = @($Json.sharedTerms | Where-Object { $_.term -eq 'en espera' })
            $t.Count | Should -Be 1
            @($t[0].families) | Should -Be @('1001', '2001', '3001')
        }

        It 'does not report a term used in one family only' {
            @($Json.sharedTerms | Where-Object { $_.term -eq 'cerrada' }).Count | Should -Be 0
        }

        It 'ignores quotes inside [fuente: ...] markers' {
            @($Json.terms | Where-Object { $_.term -eq 'notificaciones' }).Count | Should -Be 0
        }
    }

    Context 'determinism and safety' {
        It 'produces byte-identical output on two runs' {
            $root = New-FixtureCopy
            $null = Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '1000')
            $md1 = [System.IO.File]::ReadAllBytes((Join-Path $root '_feature-1000\candidates.md'))
            $js1 = [System.IO.File]::ReadAllBytes((Join-Path $root '_feature-1000\candidates.json'))
            $null = Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '1000')
            $md2 = [System.IO.File]::ReadAllBytes((Join-Path $root '_feature-1000\candidates.md'))
            $js2 = [System.IO.File]::ReadAllBytes((Join-Path $root '_feature-1000\candidates.json'))
            [Convert]::ToBase64String($md2) | Should -Be ([Convert]::ToBase64String($md1))
            [Convert]::ToBase64String($js2) | Should -Be ([Convert]::ToBase64String($js1))
        }

        It 'leaves family files untouched' {
            $root = New-FixtureCopy
            $before = Get-FileHashes $root
            $r = Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '1000')
            $r.ExitCode | Should -Be 0
            $after = Get-FileHashes $root
            $after.Count | Should -Be $before.Count
            foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] -Because $k }
        }

        It 'refuses an output folder inside a family folder (exit 2, nothing written)' {
            $root = New-FixtureCopy
            $before = Get-FileHashes $root
            $r = Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '1000', '-OutDir', (Join-Path $root '1001\out'))
            $r.ExitCode | Should -Be 2
            Test-Path (Join-Path $root '1001\out') | Should -BeFalse
            (Get-FileHashes $root).Count | Should -Be $before.Count
        }
    }

    Context 'explicit families and usage errors' {
        It 'accepts -Families as one comma-separated string and warns on a foreign parent' {
            $root = New-FixtureCopy
            $r = Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '1000', '-Families', '1001,4001')
            $r.ExitCode | Should -Be 0
            $j = Read-Json (Join-Path $root '_feature-1000\candidates.json')
            @($j.families | ForEach-Object { $_.id }) | Should -Be @('1001', '4001')
            @($j.families | Where-Object { $_.id -eq '4001' })[0].parentMatches | Should -BeFalse
            @($j.warnings).Count | Should -BeGreaterThan 0
        }

        It 'exits 2 when the reviews root does not exist' {
            (Invoke-Cluster @('-ReviewsRoot', (Join-Path $TestDrive 'missing'), '-FeatureId', '1000')).ExitCode | Should -Be 2
        }

        It 'exits 2 when a listed family folder does not exist' {
            $root = New-FixtureCopy
            (Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '1000', '-Families', '1001,5555')).ExitCode | Should -Be 2
        }

        It 'exits 2 when no family belongs to the Feature' {
            $root = New-FixtureCopy
            (Invoke-Cluster @('-ReviewsRoot', $root, '-FeatureId', '7777')).ExitCode | Should -Be 2
        }
    }
}
