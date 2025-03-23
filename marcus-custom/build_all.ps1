param ([switch]$skipIoBuild, $nameFilter)

$iodir = join-path $PSScriptRoot ".."
Push-Location $iodir
trap { pop-location }

$plans = Get-Item (join-path $PSScriptRoot "private-build-plans_*.toml")

if ($plans.Count -eq 0) {
    throw "no plans found in $iodir"
}

if (-not (get-command "fontforge" -ErrorAction SilentlyContinue)) {
    throw "cannot find fontforge";
}
if (-not (get-command "python" -ErrorAction SilentlyContinue)) {
    throw "cannot find python"
}

if (-not (get-command "ttfautohint" -ErrorAction SilentlyContinue)) {
    #https://freetype.org/ttfautohint/
    throw "cannot find ttfautohint"
}

write-host "Building plans...";

function cap($s) {
    return $s[0].ToString().ToUpperInvariant() + $s.Substring(1);
}


foreach($p in $plans) {

    write-host "Plan file: $p"
    $c = get-content $p -raw;

    if ($c -notmatch "\[buildPlans\.(iosevka-marcus(-.+)?)\]") {
        throw "could not extract name from plan"
    }

    $name = $matches[1];

    if ($c -notmatch "family = (.+)") {
        throw "could not get family"
    }

    copy-item -Path $p -Destination (Join-Path $PSScriptRoot "..\private-build-plans.toml") -Force;

    $family = ($matches[1]).Trim().Trim('"');

    $newName = "Iosemka";
    if ($family -match "Iosevka Marcus (.+)") {
        # We need to remove the space here so that NerdFonts does not consider it 
        # part of the subfamily. It appears to then correctly insert a space anyway.
        $newName += $matches[1];
    }

    if ($nameFilter -and ($newName -notmatch $nameFilter)) {
        write-host "Skipping $name → $newName ($family)"
        continue;
    }

    if (-not $skipIoBuild) {
        write-host "Building plan $name ($family)"

        push-location (join-path $PSScriptRoot "..\")
        npm run build -- ttf::$name
    }

    write-host "Patching with Nerd font"

    $fontfiles = get-item (join-path $PSScriptRoot "..\dist\$name\ttf\*.ttf");
    if ($fontfiles.Count -eq 0) {
        throw "could not find any font files"
    }

    $patchdir = join-path $PSScriptRoot "..\dist\$name\ttf.patched";
    Remove-Item -Path $patchdir -Recurse -force -ErrorAction SilentlyContinue;
    New-Item -Path $patchdir -ItemType Directory -ErrorAction SilentlyContinue | out-null;

    Push-Location (join-path $PSScriptRoot "nerd-fonts")
    foreach($ff in $fontfiles) {

        $part = (get-item $ff).BaseName

        if ($part -notmatch "-([^-]+)`$") {
            throw "unexpected format $ff ($part)"
        }

        $part = $matches[1]

        if (!$part.StartsWith("normal")) {
            throw "expected part to end with 'normal'";
        }

        $part = $part.Substring("normal".Length)

        $currentName = $newName;

        if ($part.Length) {
            
            $m = [regex]::Matches($part, "[A-Z][a-z]+");

            if ($m.Count -eq 0) {
                throw "expected subfamily matches"
            }

            $currentName += " " + ($m -join " ")
        } else {
            # nerdfont needs this, or it may see "Condensed" as a subfamily
            $currentName += " Regular"
        }

        write-host "Name to use is $currentName"

        # note: absolute -out causes error
        fontforge -script font-patcher --name $currentName --complete --quiet $ff -out ..\..\dist\$name\ttf.patched | out-null;
    }
}

Push-Location $PSScriptRoot
write-host "Done"