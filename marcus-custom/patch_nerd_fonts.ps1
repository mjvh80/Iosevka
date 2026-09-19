#Requires -Version 7.0

function Invoke-NerdFontPatch {
    param (
        [Parameter(Mandatory)][string]$InputDirectory,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$FamilyName,
        [Parameter(Mandatory)][string]$SourcePrefix,
        [Parameter(Mandatory)][string]$FontForgeExecutable,
        [Parameter(Mandatory)][string]$NerdFontsDirectory,
        [ValidateRange(1, 256)][int]$MaxParallel = 4,
        [ValidateRange(-1, 2147483647)][int]$ProgressParentId = -1
    )

    $ErrorActionPreference = "Stop"
    $inputPath = (Resolve-Path -LiteralPath $InputDirectory).Path
    $nerdPath = (Resolve-Path -LiteralPath $NerdFontsDirectory).Path
    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $separator = [IO.Path]::DirectorySeparatorChar
    if ($inputPath -eq $outputPath -or
        $inputPath.StartsWith($outputPath.TrimEnd($separator) + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $outputPath.StartsWith($inputPath.TrimEnd($separator) + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Nerd Fonts output must not overlap its input directory"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $nerdPath "font-patcher") -PathType Leaf)) {
        throw "Cannot find font-patcher in $nerdPath"
    }

    $fonts = @(Get-ChildItem -LiteralPath $inputPath -Filter "*.ttf" -File | Sort-Object Name)
    if ($fonts.Count -eq 0) {
        throw "No input TTF files found in $inputPath"
    }
    $workDirectory = Join-Path (Split-Path $outputPath -Parent) ".nerd-fonts-$([guid]::NewGuid().ToString('N'))"
    $jobs = @(foreach ($font in $fonts) {
        if (-not $font.BaseName.StartsWith($SourcePrefix, [StringComparison]::Ordinal)) {
            throw "Unexpected font name: $($font.Name) (expected prefix $SourcePrefix)"
        }
        $style = $font.BaseName.Substring($SourcePrefix.Length)
        if (-not $style) {
            $style = "Regular"
        }
        if ($style -cnotmatch '^(?:[A-Z][a-z]+)+$') {
            throw "Unexpected font style: $style"
        }
        $styleWords = [regex]::Matches($style, "[A-Z][a-z]+") -join " "
        $jobDirectory = Join-Path $workDirectory $style
        $relativeOutput = [IO.Path]::GetRelativePath($nerdPath, $jobDirectory)
        if ([IO.Path]::IsPathRooted($relativeOutput)) {
            throw "Nerd Fonts output must be on the same drive as its checkout"
        }
        [pscustomobject]@{
            Style = $style
            Name = "$FamilyName $styleWords"
            InputPath = $font.FullName
            OutputDirectory = $jobDirectory
            RelativeOutput = $relativeOutput
            LogPath = Join-Path $workDirectory "$style.log"
        }
    })
    if (@($jobs | Group-Object Style | Where-Object Count -gt 1).Count) {
        throw "Duplicate font styles in $inputPath"
    }
    foreach ($job in $jobs) {
        New-Item -Path $job.OutputDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Host "Patching $($jobs.Count) fonts for $FamilyName with up to $MaxParallel workers"
    Write-Host "Worker logs: $workDirectory"
    $batchTimer = [Diagnostics.Stopwatch]::StartNew()
    $completed = 0
    $activity = "Nerd Fonts: $FamilyName"
    try {
        Write-Progress -Id 1 -ParentId $ProgressParentId -Activity $activity -Status "0/$($jobs.Count) fonts completed" -PercentComplete 0
        $results = @($jobs | ForEach-Object -Parallel {
            $ErrorActionPreference = "Stop"
            $PSNativeCommandUseErrorActionPreference = $false
            $job = $_
            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                Write-Host "Starting $($job.Name)"
                Set-Location -LiteralPath $using:nerdPath
                & $using:FontForgeExecutable -lang=py -script font-patcher --name $job.Name --complete --quiet $job.InputPath -out $job.RelativeOutput *> $job.LogPath
                if ($LASTEXITCODE -ne 0) {
                    throw "FontForge exited with code $LASTEXITCODE"
                }
                $generated = @(Get-ChildItem -LiteralPath $job.OutputDirectory -Filter "*.ttf" -File)
                if ($generated.Count -ne 1) {
                    throw "Expected one patched TTF, found $($generated.Count)"
                }
                [pscustomobject]@{ InputPath = $job.InputPath; OutputPath = $generated[0].FullName; Error = $null; Seconds = $timer.Elapsed.TotalSeconds }
            } catch {
                [pscustomobject]@{ InputPath = $job.InputPath; OutputPath = $null; Error = "$($_.Exception.Message); log: $($job.LogPath)"; Seconds = $timer.Elapsed.TotalSeconds }
            }
        } -ThrottleLimit $MaxParallel | ForEach-Object {
            $completed++
            $status = if ($_.Error) { "FAILED" } else { "Patched" }
            $fontName = Split-Path $_.InputPath -Leaf
            Write-Progress -Id 1 -ParentId $ProgressParentId -Activity $activity -Status ("{0}/{1} fonts completed; elapsed {2:N1}s" -f $completed, $jobs.Count, $batchTimer.Elapsed.TotalSeconds) -CurrentOperation "$status $fontName" -PercentComplete ($completed * 100 / $jobs.Count)
            Write-Host ("[{0}/{1}] {2} {3} ({4:N1}s; elapsed {5:N1}s)" -f $completed, $jobs.Count, $status, $fontName, $_.Seconds, $batchTimer.Elapsed.TotalSeconds)
            if ($_.Error) {
                Write-Host "  $($_.Error)"
            }
            $_
        })

        $failures = @($results | Where-Object Error)
        if ($failures.Count -or $results.Count -ne $jobs.Count) {
            $details = ($failures | ForEach-Object { "$($_.InputPath): $($_.Error)" }) -join "`n"
            throw "Nerd Fonts patching failed. Work files retained in $workDirectory`n$details"
        }
        $outputs = @($results | ForEach-Object { Get-Item -LiteralPath $_.OutputPath })
        if (@($outputs | Group-Object Name | Where-Object Count -gt 1).Count) {
            throw "Nerd Fonts produced duplicate output names. Work files retained in $workDirectory"
        }
        Write-Progress -Id 1 -ParentId $ProgressParentId -Activity $activity -Status "Publishing $($results.Count) patched fonts" -PercentComplete 100
        if (Test-Path -LiteralPath $outputPath) {
            Remove-Item -LiteralPath $outputPath -Recurse -Force
        }
        New-Item -Path $outputPath -ItemType Directory | Out-Null
        foreach ($output in $outputs) {
            Move-Item -LiteralPath $output.FullName -Destination $outputPath
        }
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
        Write-Host ("Finished {0}: {1} fonts in {2:N1}s -> {3}" -f $FamilyName, $results.Count, $batchTimer.Elapsed.TotalSeconds, $outputPath)
    } finally {
        Write-Progress -Id 1 -ParentId $ProgressParentId -Activity $activity -Completed
    }
}