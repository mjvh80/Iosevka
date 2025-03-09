

All the private-build-plans.toml are copied to their output dir.

Sample ps command: $font = "marcus-qpe"; npm run build -- "ttf::iosevka-$font"; copy-item .\private-build-plans.toml ".\dist\iosevka-$font\" -Force

Here "qpe" is the part in the toml sections, the family is the "full" name.

The fonts are then patched using nerd font.

Get-ChildItem ..\Iosevka\dist\io* -recurse -Filter *.ttf | ?{ !$_.FullName.Contains("ttf-unhinted") } | %{ &"C:\Program Files (x86)\FontForgeBuilds\fontforge.bat" -script font-patcher --complete --careful -out /C/Users/mjvh8/Repos/Iosevka/dist/iosevka-marcus/patched $_.FullName }  