local mod = get_mod("OverheadDodge")

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "enable_mod",
                type = "checkbox",
                default_value = true,
            },
            {
                setting_id = "lead_time",
                type = "numeric",
                default_value = 0.32,
                range = { 0.10, 0.48 },
                decimals_number = 2,
            },
        },
    },
}
