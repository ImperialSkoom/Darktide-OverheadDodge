local mod = get_mod("OverheadDodge")
local BreedActions = require("scripts/settings/breed/breed_actions")
local Dodge = require("scripts/extension_systems/character_state_machine/character_states/utilities/dodge")
local Interacting = require("scripts/extension_systems/character_state_machine/character_states/utilities/interacting")
local MinionAttack = require("scripts/utilities/minion_attack")

-- A replicated windup has no server impact timestamp.
local CLIENT_IMPACT_GRACE = 0.10
local PLAYER_HALF_HEIGHT = 0.75
local PLAYER_RADIUS = 0.50
local HEAD_TRACK_LEAD = 0.55
local HEAD_NODE = "enemy_aim_target_03"

local slam_actions = {
    chaos_ogryn_executor = {
        melee_attack_cleave = { "attack_01", "attack_02", "attack_07", "attack_08" },
        moving_melee_attack_cleave = { "attack_move_01" },
        melee_attack = { "attack_down_01" },
    },
    renegade_executor = {
        melee_cleave_attack = { "attack_01", "attack_02", "attack_down_01" },
        moving_melee_cleave_attack = { "attack_move_01" },
        melee_attack = { "attack_down_01" },
    },
    renegade_captain = { powermaul_ground_slam = { "attack_ground_slam" } },
    cultist_captain = { powermaul_ground_slam = { "cultist_heavy_slam" } },
}

local attacks = {}
local event_indices = {}
local host_actions = {}
local client_actions = {}
local map_world
local pending_dodge

local function reset()
    event_indices, host_actions, client_actions = {}, {}, {}
    map_world = nil
    pending_dodge = nil
end

mod.on_game_state_changed = reset
mod.on_disabled = reset

mod.on_setting_changed = function(setting_id)
    if setting_id == "enable_mod" then
        reset()
    end
end

for breed, action_names in pairs(slam_actions) do
    local entries = {}
    attacks[breed] = entries
    local breed_actions = BreedActions[breed]
    for name, events in pairs(action_names) do
        local action = breed_actions and breed_actions[name]
        for _, event in ipairs(events) do
            local timings = action and action.attack_anim_damage_timings
            local timing = timings and timings[event]
            if type(timing) == "number" then
                local entry = entries[event] or {}
                entry[#entry + 1] = { action = action, timing = timing, event = event }
                entries[event] = entry
            end
        end
    end
end

local function alive(unit)
    return unit and Unit.alive(unit) and (not HEALTH_ALIVE or HEALTH_ALIVE[unit] ~= false)
end

local function client_event_map(world, breed)
    if map_world ~= world then
        event_indices, client_actions = {}, {}
        map_world = world
    end

    local name = breed.name
    if event_indices[name] then
        return event_indices[name]
    end

    -- Unit.animation_event plays the event as it resolves the index.
    local indices, proxy = {}, nil
    local ok, err = pcall(function()
        proxy = World.spawn_unit_ex(world, breed.base_unit, nil, Vector3(0, 0, -10000))
        Unit.set_animation_state_machine(proxy, breed.state_machine)
        for event, entries in pairs(attacks[name]) do
            if Unit.has_animation_event(proxy, event) then
                local index = Unit.animation_event(proxy, event)
                if type(index) == "number" then
                    indices[index] = entries
                end
            end
        end
    end)
    if proxy then
        World.destroy_unit(world, proxy)
    end
    if not ok then
        mod:warning("Could not resolve %s slam animations: %s", name, tostring(err))
        indices = {}
    end
    event_indices[name] = indices
    return indices
end

local function receive_animation(self, _, id, index)
    if mod:get("enable_mod") == false then
        return
    end
    local unit = Managers.state.unit_spawner:unit(id)
    if not alive(unit) then
        return
    end
    local animation = ScriptUnit.has_extension(unit, "animation_system")
    local breed = animation and animation._breed
    if not breed or not attacks[breed.name] then
        return
    end

    local entries = client_event_map(self._world, breed)[index]
    if not entries then
        client_actions[unit] = nil
        return
    end

    local connection = Managers.connection
    local host = connection and connection:host()
    local ping = host and Network.ping(host) or 0
    client_actions[unit] = {
        entries = entries,
        start = Managers.time:time("gameplay") - math.min(0.15, math.max(0, ping * 0.5)),
        session = animation._game_session,
        id = id,
    }
end

local function position_of(unit)
    return POSITION_LOOKUP and POSITION_LOOKUP[unit] or Unit.world_position(unit, 1)
end

local function threatens(attacker, position, is_target, entry, time_to_impact)
    local action = entry.action
    local displacement = position - position_of(attacker)
    local advance = (action.move_speed or 0) * time_to_impact
    if action.attack_type == "oobb" then
        local center, rotation, half = MinionAttack.melee_oobb_extents(attacker, action)
        local offset = position + Vector3.up() * PLAYER_HALF_HEIGHT - center
        local forward = Vector3.dot(offset, Quaternion.forward(rotation))
        local overlaps = math.abs(Vector3.dot(offset, Quaternion.right(rotation))) <= half.x + PLAYER_RADIUS
            and forward >= -half.y - PLAYER_RADIUS and forward <= half.y + PLAYER_RADIUS + advance
            and math.abs(Vector3.dot(offset, Quaternion.up(rotation))) <= half.z + PLAYER_HALF_HEIGHT
        if overlaps then
            return true
        end

        -- The attacker can still turn toward its target during the windup.
        local reach = action.range + PLAYER_RADIUS + advance
        return is_target and math.abs(offset.z) <= half.z + PLAYER_HALF_HEIGHT
            and Vector3.length_squared(Vector3.flat(displacement)) <= reach * reach
    end

    if not is_target then
        return false
    end
    local reach = action.weapon_reach
    if type(reach) == "table" then
        reach = reach[entry.event] or reach.default
    end
    if not reach then
        return false
    end
    reach = reach + advance
    return math.abs(displacement.z) < (action.max_z_diff or 2.2)
        and Vector3.length_squared(Vector3.flat(displacement)) <= reach * reach
end

local function incoming_slam(unit, position, t, lead)
    local selected_attacker, selected_record
    local earliest = math.huge

    local function consider(attacker, record, target, entry, impact, grace)
        if impact >= t - grace and impact <= t + lead and impact < earliest then
            local threatened = threatens(attacker, position, target == unit, entry, math.max(0, impact - t))
            if threatened then
                selected_attacker, selected_record = attacker, record
                earliest = impact
            end
        end
    end

    for attacker, record in pairs(host_actions) do
        local scratchpad = record.scratchpad
        local impact = scratchpad.attack_timing
        if not alive(attacker) or not impact or impact < t or scratchpad.finished_attack then
            host_actions[attacker] = nil
        elseif not record.responded then
            consider(attacker, record, scratchpad.perception_component.target_unit, record.entry, impact, 0)
        end
    end
    local spawner = Managers.state and Managers.state.unit_spawner
    for attacker, record in pairs(client_actions) do
        if not alive(attacker) or not spawner or spawner:unit(record.id) ~= attacker or t > record.start + 4.5 then
            client_actions[attacker] = nil
        elseif not record.responded then
            local session = record.session
            local target_id = session and GameSession.game_object_exists(session, record.id)
                and GameSession.game_object_field(session, record.id, "target_unit_id")
            local target = target_id and spawner:unit(target_id)
            for _, entry in ipairs(record.entries) do
                consider(attacker, record, target, entry, record.start + entry.timing, CLIENT_IMPACT_GRACE)
            end
        end
    end
    return selected_attacker, selected_record, earliest
end

local function track_head(attacker, data, position, yaw, pitch)
    local direction = position_of(attacker) - position
    if Unit.has_node(attacker, HEAD_NODE) then
        local head = Unit.world_position(attacker, Unit.node(attacker, HEAD_NODE))
        direction = head - data:read_component("first_person").position
        if Vector3.length_squared(direction) > 0.001 then
            local rotation = Quaternion.look(direction, Vector3.up())
            pitch = Quaternion.pitch(rotation)
        end
    end

    local flat = Vector3.flat(direction)
    if Vector3.length_squared(flat) > 0.001 then
        yaw = math.mod_two_pi(Quaternion.yaw(Quaternion.look(flat, Vector3.up())))
    end
    return yaw, pitch
end

local dodge_input = {
    get = function(_, action)
        if action == "move" then
            return -Vector3.forward()
        end
        return action == "dodge"
    end,
}

local function inject_dodge(func, self, dt, t, frame, service, yaw, pitch, roll)
    if mod:get("enable_mod") == false then
        return func(self, dt, t, frame, service, yaw, pitch, roll)
    end
    local player = self._player
    local unit = player and player.player_unit
    local local_player = Managers.player and Managers.player:local_player_safe(1)
    if player ~= local_player or not alive(unit)
        or (not pending_dodge and not next(host_actions) and not next(client_actions)) then
        return func(self, dt, t, frame, service, yaw, pitch, roll)
    end

    local data = ScriptUnit.has_extension(unit, "unit_data_system")
    if not data or data.is_resimulating then
        return func(self, dt, t, frame, service, yaw, pitch, roll)
    end

    local character_state = data:read_component("character_state")
    local state = character_state.state_name
    if pending_dodge then
        if unit == pending_dodge.unit and state == "dodging" and character_state.entered_t >= pending_dodge.time then
            pending_dodge.record.responded = true
        end
        pending_dodge = nil
    end

    local sprinting = state == "sprinting"
    if (not next(host_actions) and not next(client_actions)) or Managers.ui:using_input()
        or (state ~= "walking" and not sprinting) or not data:read_component("inair_state").on_ground
        or data:read_component("force_look_rotation").use_force_look_rotation
        or Interacting.check(data:read_component("interaction")) then
        return func(self, dt, t, frame, service, yaw, pitch, roll)
    end

    local position = position_of(unit)
    local sprint_lead = sprinting and dt or 0
    local dodge_lead = (mod:get("lead_time") or 0.32) + sprint_lead
    local attacker, record, impact = incoming_slam(unit, position, t, math.max(HEAD_TRACK_LEAD, dodge_lead))
    if not attacker then
        return func(self, dt, t, frame, service, yaw, pitch, roll)
    end

    yaw, pitch = track_head(attacker, data, position, yaw, pitch)
    player:set_orientation(yaw, pitch, roll)
    func(self, dt, t, frame, service, yaw, pitch, roll)

    -- Give sprint a fixed frame to end before sending the dodge.
    if impact > t + dodge_lead or t + sprint_lead < data:read_component("dodge_character_state").cooldown then
        return
    end
    if not sprinting and data:read_component("action_sweep").is_sticky
        and not Dodge.check(t, data, data:archetype().dodge, dodge_input) then
        return
    end

    -- Use the same frame for prediction, server input and any replay of this input.
    local index = self:_buffer_index(frame)
    local cache, actions = self._input_cache, self._action_lookup
    cache[actions.move_forward][index] = 0
    cache[actions.sprint][index] = false
    cache[actions.sprinting][index] = false

    if sprinting or (t < character_state.entered_t + 0.5
        and data:read_component("walking_character_state").previous_state_allowed_slide) then
        cache[actions.crouch][index] = false
        cache[actions.crouching][index] = false
    end
    if not sprinting then
        local side = cache[actions.move_right][index] - cache[actions.move_left][index]
        cache[actions.move_left][index] = side < 0 and 1 or 0
        cache[actions.move_right][index] = side > 0 and 1 or 0
        cache[actions.move_backward][index] = side == 0 and 1 or 0
        cache[actions.dodge][index] = true
        pending_dodge = { unit = unit, record = record, time = t }
    end
end

mod:hook_safe("BtMeleeAttackAction", "enter", function(_, unit, breed, _, scratchpad, action)
    if mod:get("enable_mod") == false then
        return
    end
    local entries = attacks[breed.name]
    entries = entries and entries[scratchpad.attack_event]
    for _, entry in ipairs(entries or {}) do
        if entry.action == action then
            host_actions[unit] = { scratchpad = scratchpad, entry = entry }
            return
        end
    end
end)
mod:hook_safe("BtMeleeAttackAction", "leave", function(_, unit)
    host_actions[unit] = nil
end)
mod:hook_safe("AnimationSystem", "rpc_minion_anim_event", receive_animation)
mod:hook_safe("AnimationSystem", "rpc_minion_anim_event_variable_float", receive_animation)
mod:hook("HumanInputHandler", "fixed_update", inject_dodge)
