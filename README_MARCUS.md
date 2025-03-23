

All the private-build-plans.toml are copied to their output dir.

Sample ps command: $font = "marcus-qpe"; npm run build -- "ttf::iosevka-$font"; copy-item .\private-build-plans.toml ".\dist\iosevka-$font\" -Force

Here "qpe" is the part in the toml sections, the family is the "full" name.

The fonts are then patched using nerd font.

Get-ChildItem ..\Iosevka\dist\io* -recurse -Filter *.ttf | ?{ !$_.FullName.Contains("ttf-unhinted") } | %{ &"C:\Program Files (x86)\FontForgeBuilds\fontforge.bat" -script font-patcher --complete --careful -out /C/Users/mjvh8/Repos/Iosevka/dist/iosevka-marcus/patched $_.FullName }  


Usual worflow is:

1. build the Iosevka font from the given plans
2. patch using nerdfont
3. patch to create script font (only for condensed)

Various scripts:

- opentype_freeze.py: freezes the ss01 feature set into the font (for freezing Cascadia's cursive)
- create_italic_script_font.py: supports either monaspace Radon or Cascadia, replaces the italic fonts with their cursive variants





