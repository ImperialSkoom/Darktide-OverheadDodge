return {
    run = function()
        local path = "OverheadDodge/scripts/mods/OverheadDodge/OverheadDodge"
        new_mod("OverheadDodge", {
            mod_script = path,
            mod_data = path .. "_data",
            mod_localization = path .. "_localization",
        })
    end,
    packages = {},
}
