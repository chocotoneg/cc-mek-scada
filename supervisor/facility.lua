local log        = require("scada-common.log")
local types      = require("scada-common.types")
local util       = require("scada-common.util")

local fac_update = require("supervisor.facility_update")

local unit       = require("supervisor.unit")

local rsctl      = require("supervisor.session.rsctl")

local PROCESS       = types.PROCESS
local RTU_UNIT_TYPE = types.RTU_UNIT_TYPE
local WASTE         = types.WASTE_PRODUCT

---@enum AUTO_SCRAM
local AUTO_SCRAM = {
    NONE = 0,
    MATRIX_DC = 1,
    MATRIX_FILL = 2,
    CRIT_ALARM = 3,
    RADIATION = 4,
    GEN_FAULT = 5
}

---@enum START_STATUS
local START_STATUS = {
    OK = 0,
    NO_UNITS = 1,
    BLADE_MISMATCH = 2
}

---@class facility_management
local facility = {}

-- create a new facility management object
---@nodiscard
---@param config svr_config supervisor configuration
---@param cooling_conf sv_cooling_conf cooling configurations of reactor units
---@param check_rtu_id function ID checking function for RTUs attempting to be linked
function facility.new(config, cooling_conf, check_rtu_id)
    ---@class _facility_self
    local self = {
        units = {},
        types = { AUTO_SCRAM = AUTO_SCRAM, START_STATUS = START_STATUS },
        status_text = { "START UP", "initializing..." },
        all_sys_ok = false,
        allow_testing = false,
        -- facility tanks
        tank_defs = cooling_conf.fac_tank_defs,
        tank_list = {},
        -- rtus
        rtu_conn_count = 0,
        rtu_list = {},
        redstone = {},
        induction = {},
        sps = {},
        tanks = {},
        envd = {},
        -- redstone I/O control
        io_ctl = nil,   ---@type rs_controller
        -- process control
        units_ready = false,
        mode = PROCESS.INACTIVE,
        last_mode = PROCESS.INACTIVE,
        return_mode = PROCESS.INACTIVE,
        mode_set = PROCESS.MAX_BURN,
        start_fail = START_STATUS.OK,
        max_burn_combined = 0.0,        -- maximum burn rate to clamp at
        burn_target = 0.1,              -- burn rate target for aggregate burn mode
        charge_setpoint = 0,            -- FE charge target setpoint
        gen_rate_setpoint = 0,          -- FE/t charge rate target setpoint
        group_map = {},                 -- units -> group IDs
        prio_defs = { {}, {}, {}, {} }, -- priority definitions (each level is a table of units)
        at_max_burn = false,
        ascram = false,
        ascram_reason = AUTO_SCRAM.NONE,
        ---@class ascram_status
        ascram_status = {
            matrix_dc = false,
            matrix_fill = false,
            crit_alarm = false,
            radiation = false,
            gen_fault = false
        },
        -- closed loop control
        charge_conversion = 1.0,
        time_start = 0.0,
        initial_ramp = true,
        waiting_on_ramp = false,
        waiting_on_stable = false,
        accumulator = 0.0,
        saturated = false,
        last_update = 0,
        last_error = 0.0,
        last_time = 0.0,
        -- waste processing
        waste_product = WASTE.PLUTONIUM,
        current_waste_product = WASTE.PLUTONIUM,
        pu_fallback = false,
        sps_low_power = false,
        disabled_sps = false,
        -- alarm tones
        tone_states = {},
        test_tone_set = false,
        test_tone_reset = false,
        test_tone_states = {},
        test_alarm_states = {},
        -- statistics
        im_stat_init = false,
        avg_charge = util.mov_avg(3),  -- 3 seconds
        avg_inflow = util.mov_avg(6),  -- 3 seconds
        avg_outflow = util.mov_avg(6), -- 3 seconds
        -- induction matrix charge delta stats
        avg_net = util.mov_avg(60),    -- 60 seconds
        imtx_last_capacity = 0,
        imtx_last_charge = 0,
        imtx_last_charge_t = 0,
        -- track faulted induction matrix update times to reject
        imtx_faulted_times = { 0, 0, 0 }
    }

    -- provide self to facility update functions
    local f_update = fac_update(self)

    -- create units
    for i = 1, config.UnitCount do
        table.insert(self.units, unit.new(i, cooling_conf.r_cool[i].BoilerCount, cooling_conf.r_cool[i].TurbineCount, check_rtu_id, config.ExtChargeIdling))
        table.insert(self.group_map, 0)
    end

    -- list for RTU session management
    self.rtu_list = { self.redstone, self.induction, self.sps, self.tanks, self.envd }

    -- init redstone RTU I/O controller
    self.io_ctl = rsctl.new(self.redstone)

    -- fill blank alarm/tone states
    for _ = 1, 12 do table.insert(self.test_alarm_states, false) end
    for _ = 1, 8 do
        table.insert(self.tone_states, false)
        table.insert(self.test_tone_states, false)
    end

    --#region decode tank configuration

    -- determine tank information
    if cooling_conf.fac_tank_mode == 0 then
        self.tank_defs = {}

        -- on facility tank mode 0, setup tank defs to match unit tank option
        for i = 1, config.UnitCount do
            self.tank_defs[i] = util.trinary(cooling_conf.r_cool[i].TankConnection, 1, 0)
        end

        self.tank_list = { table.unpack(self.tank_defs) }
    else
        -- decode the layout of tanks from the connections definitions
        local tank_mode = cooling_conf.fac_tank_mode
        local tank_defs = self.tank_defs
        local tank_list = { table.unpack(tank_defs) }

        local function calc_fdef(start_idx, end_idx)
            local first = 4
            for i = start_idx, end_idx do
                if self.tank_defs[i] == 2 then
                    if i < first then first = i end
                end
            end
            return first
        end

        if tank_mode == 1 then
            -- (1) 1 total facility tank (A A A A)
            local first_fdef = calc_fdef(1, #tank_defs)
            for i = 1, #tank_defs do
                if i > first_fdef and tank_defs[i] == 2 then
                    tank_list[i] = 0
                end
            end
        elseif tank_mode == 2 then
            -- (2) 2 total facility tanks (A A A B)
            local first_fdef = calc_fdef(1, math.min(3, #tank_defs))
            for i = 1, #tank_defs do
                if (i ~= 4) and (i > first_fdef) and (tank_defs[i] == 2) then
                    tank_list[i] = 0
                end
            end
        elseif tank_mode == 3 then
            -- (3) 2 total facility tanks (A A B B)
            for _, a in pairs({ 1, 3 }) do
                local b = a + 1
                if (tank_defs[a] == 2) and (tank_defs[b] == 2) then
                    tank_list[b] = 0
                end
            end
        elseif tank_mode == 4 then
            -- (4) 2 total facility tanks (A B B B)
            local first_fdef = calc_fdef(2, #tank_defs)
            for i = 1, #tank_defs do
                if (i ~= 1) and (i > first_fdef) and (tank_defs[i] == 2) then
                    tank_list[i] = 0
                end
            end
        elseif tank_mode == 5 then
            -- (5) 3 total facility tanks (A A B C)
            local first_fdef = calc_fdef(1, math.min(2, #tank_defs))
            for i = 1, #tank_defs do
                if (not (i == 3 or i == 4)) and (i > first_fdef) and (tank_defs[i] == 2) then
                    tank_list[i] = 0
                end
            end
        elseif tank_mode == 6 then
            -- (6) 3 total facility tanks (A B B C)
            local first_fdef = calc_fdef(2, math.min(3, #tank_defs))
            for i = 1, #tank_defs do
                if (not (i == 1 or i == 4)) and (i > first_fdef) and (tank_defs[i] == 2) then
                    tank_list[i] = 0
                end
            end
        elseif tank_mode == 7 then
            -- (7) 3 total facility tanks (A B C C)
            local first_fdef = calc_fdef(3, #tank_defs)
            for i = 1, #tank_defs do
                if (not (i == 1 or i == 2)) and (i > first_fdef) and (tank_defs[i] == 2) then
                    tank_list[i] = 0
                end
            end
        end

        self.tank_list = tank_list
    end

    --#endregion

    -- PUBLIC FUNCTIONS --

    ---@class facility
    local public = {}

    --#region Add/Link Devices

    -- link a redstone RTU session
    ---@param rs_unit unit_session
    function public.add_redstone(rs_unit) table.insert(self.redstone, rs_unit) end

    -- link an induction matrix RTU session
    ---@param imatrix unit_session
    ---@return boolean linked induction matrix accepted (max 1)
    function public.add_imatrix(imatrix)
        local fail_code, fail_str = check_rtu_id(imatrix, self.induction, 1)

        if fail_code == 0 then
            table.insert(self.induction, imatrix)
        else
            log.warning(util.c("FAC: rejected induction matrix linking due to failure code ", fail_code, " (", fail_str, ")"))
        end

        return fail_code == 0
    end

    -- link an SPS RTU session
    ---@param sps unit_session
    ---@return boolean linked SPS accepted (max 1)
    function public.add_sps(sps)
        local fail_code, fail_str = check_rtu_id(sps, self.sps, 1)

        if fail_code == 0 then
            table.insert(self.sps, sps)
        else
            log.warning(util.c("FAC: rejected SPS linking due to failure code ", fail_code, " (", fail_str, ")"))
        end

        return fail_code == 0
    end

    -- link a dynamic tank RTU session
    ---@param dynamic_tank unit_session
    function public.add_tank(dynamic_tank) table.insert(self.tanks, dynamic_tank) end

    -- link an environment detector RTU session
    ---@param envd unit_session
    function public.add_envd(envd) table.insert(self.envd, envd) end

    -- purge devices associated with the given RTU session ID
    ---@param session integer RTU session ID
    function public.purge_rtu_devices(session)
        for _, v in pairs(self.rtu_list) do util.filter_table(v, function (s) return s.get_session_id() ~= session end) end
    end

    --#endregion

    --#region Update

    -- update (iterate) the facility management
    function public.update()
        -- run process control and evaluate automatic SCRAM
        f_update.pre_auto()
        f_update.auto_control(config.ExtChargeIdling)
        f_update.auto_safety()
        f_update.post_auto()

        -- handle redstone I/O
        f_update.redstone(public.ack_all)

        -- unit tasks
        f_update.unit_mgmt(cooling_conf)

        -- update alarm tones
        f_update.alarm_audio()
    end

    -- call the update function of all units in the facility<br>
    -- additionally sets the requested auto waste mode if applicable
    function public.update_units()
        for i = 1, #self.units do
            local u = self.units[i] ---@type reactor_unit
            u.auto_set_waste(self.current_waste_product)
            u.update()
        end
    end

    --#endregion

    --#region Commands

    -- SCRAM all reactor units
    function public.scram_all()
        for i = 1, #self.units do
            local u = self.units[i] ---@type reactor_unit
            u.scram()
        end
    end

    -- ack all alarms on all reactor units
    function public.ack_all()
        for i = 1, #self.units do
            local u = self.units[i] ---@type reactor_unit
            u.ack_all()
        end
    end

    -- stop auto control
    function public.auto_stop() self.mode = PROCESS.INACTIVE end

    -- set automatic control configuration and start the process
    ---@param auto_cfg coord_auto_config configuration
    ---@return table response ready state (successfully started) and current configuration (after updating)
    function public.auto_start(auto_cfg)
        local charge_scaler = 1000000   -- convert MFE to FE
        local gen_scaler    = 1000      -- convert kFE to FE
        local ready         = false

        -- load up current limits
        local limits = {}
        for i = 1, config.UnitCount do
            local u = self.units[i] ---@type reactor_unit
            limits[i] = u.get_control_inf().lim_br100 * 100
        end

        -- only allow changes if not running
        if self.mode == PROCESS.INACTIVE then
            if (type(auto_cfg.mode) == "number") and (auto_cfg.mode > PROCESS.INACTIVE) and (auto_cfg.mode <= PROCESS.GEN_RATE) then
                self.mode_set = auto_cfg.mode
            end

            if (type(auto_cfg.burn_target) == "number") and auto_cfg.burn_target >= 0.1 then
                self.burn_target = auto_cfg.burn_target
            end

            if (type(auto_cfg.charge_target) == "number") and auto_cfg.charge_target >= 0 then
                self.charge_setpoint = auto_cfg.charge_target * charge_scaler
            end

            if (type(auto_cfg.gen_target) == "number") and auto_cfg.gen_target >= 0 then
                self.gen_rate_setpoint = auto_cfg.gen_target * gen_scaler
            end

            if (type(auto_cfg.limits) == "table") and (#auto_cfg.limits == config.UnitCount) then
                for i = 1, config.UnitCount do
                    local limit = auto_cfg.limits[i]

                    if (type(limit) == "number") and (limit >= 0.1) then
                        limits[i] = limit
                        self.units[i].set_burn_limit(limit)
                    end
                end
            end

            ready = self.mode_set > 0

            if (self.mode_set == PROCESS.CHARGE) and (self.charge_setpoint <= 0) or
               (self.mode_set == PROCESS.GEN_RATE) and (self.gen_rate_setpoint <= 0) or
               (self.mode_set == PROCESS.BURN_RATE) and (self.burn_target < 0.1) then
                ready = false
            end

            ready = ready and self.units_ready

            if ready then self.mode = self.mode_set end
        end

        return {
            ready,
            self.mode_set,
            self.burn_target,
            self.charge_setpoint / charge_scaler,
            self.gen_rate_setpoint / gen_scaler,
            limits
        }
    end

    --#endregion

    --#region Settings

    -- set the automatic control group of a unit
    ---@param unit_id integer unit ID
    ---@param group integer group ID or 0 for independent
    function public.set_group(unit_id, group)
        if (group >= 0 and group <= 4) and (unit_id > 0 and unit_id <= config.UnitCount) and self.mode == PROCESS.INACTIVE then
            -- remove from old group if previously assigned
            local old_group = self.group_map[unit_id]
            if old_group ~= 0 then
                util.filter_table(self.prio_defs[old_group], function (u) return u.get_id() ~= unit_id end)
            end

            self.group_map[unit_id] = group

            -- add to group if not independent
            if group > 0 then
                table.insert(self.prio_defs[group], self.units[unit_id])
            end
        end
    end

    -- set waste production
    ---@param product WASTE_PRODUCT target product
    ---@return WASTE_PRODUCT product newly set value, if valid
    function public.set_waste_product(product)
        if product == WASTE.PLUTONIUM or product == WASTE.POLONIUM or product == WASTE.ANTI_MATTER then
            self.waste_product = product
        end

        return self.waste_product
    end

    -- enable/disable plutonium fallback
    ---@param enabled boolean requested state
    ---@return boolean enabled newly set value
    function public.set_pu_fallback(enabled)
        self.pu_fallback = enabled == true
        return self.pu_fallback
    end

    -- enable/disable SPS at low power
    ---@param enabled boolean requested state
    ---@return boolean enabled newly set value
    function public.set_sps_low_power(enabled)
        self.sps_low_power = enabled == true
        return self.sps_low_power
    end

    --#endregion

    --#region Diagnostic Testing

    -- attempt to set a test tone state
    ---@param id TONE|0 tone ID or 0 to disable all
    ---@param state boolean state
    ---@return boolean allow_testing, table test_tone_states
    function public.diag_set_test_tone(id, state)
        if self.allow_testing then
            self.test_tone_set = true
            self.test_tone_reset = false

            if id == 0 then
                for i = 1, #self.test_tone_states do self.test_tone_states[i] = false end
            else
                self.test_tone_states[id] = state
            end
        end

        return self.allow_testing, self.test_tone_states
    end

    -- attempt to set a test alarm state
    ---@param id ALARM|0 alarm ID or 0 to disable all
    ---@param state boolean state
    ---@return boolean allow_testing, table test_alarm_states
    function public.diag_set_test_alarm(id, state)
        if self.allow_testing then
            self.test_tone_set = true
            self.test_tone_reset = false

            if id == 0 then
                for i = 1, #self.test_alarm_states do self.test_alarm_states[i] = false end
            else
                self.test_alarm_states[id] = state
            end
        end

        return self.allow_testing, self.test_alarm_states
    end

    --#endregion

    --#region Read States/Properties

    -- get current alarm tone on/off states
    ---@nodiscard
    function public.get_alarm_tones() return self.tone_states end

    -- get build properties of all facility devices
    ---@nodiscard
    ---@param type RTU_UNIT_TYPE? type or nil to include only a particular unit type, or to include all if nil
    function public.get_build(type)
        local all = type == nil
        local build = {}

        if all or type == RTU_UNIT_TYPE.IMATRIX then
            build.induction = {}
            for i = 1, #self.induction do
                local matrix = self.induction[i]    ---@type unit_session
                build.induction[i] = { matrix.get_db().formed, matrix.get_db().build }
            end
        end

        if all or type == RTU_UNIT_TYPE.SPS then
            build.sps = {}
            for i = 1, #self.sps do
                local sps = self.sps[i] ---@type unit_session
                build.sps[i] = { sps.get_db().formed, sps.get_db().build }
            end
        end

        if all or type == RTU_UNIT_TYPE.DYNAMIC_VALVE then
            build.tanks = {}
            for i = 1, #self.tanks do
                local tank = self.tanks[i]  ---@type unit_session
                build.tanks[tank.get_device_idx()] = { tank.get_db().formed, tank.get_db().build }
            end
        end

        return build
    end

    -- get automatic process control status
    ---@nodiscard
    function public.get_control_status()
        local astat = self.ascram_status
        return {
            self.all_sys_ok,
            self.units_ready,
            self.mode,
            self.waiting_on_ramp or self.waiting_on_stable,
            self.at_max_burn or self.saturated,
            self.ascram,
            astat.matrix_dc,
            astat.matrix_fill,
            astat.crit_alarm,
            astat.radiation,
            astat.gen_fault or self.mode == PROCESS.GEN_RATE_FAULT_IDLE,
            self.status_text[1],
            self.status_text[2],
            self.group_map,
            self.current_waste_product,
            self.pu_fallback and (self.current_waste_product == WASTE.PLUTONIUM) and (self.waste_product ~= WASTE.PLUTONIUM),
            self.disabled_sps
        }
    end

    -- get RTU statuses
    ---@nodiscard
    function public.get_rtu_statuses()
        local status = {}

        -- total count of all connected RTUs in the facility
        status.count = self.rtu_conn_count

        -- power averages from induction matricies
        status.power = {
            self.avg_charge.compute(),
            self.avg_inflow.compute(),
            self.avg_outflow.compute(),
            0
        }

        -- status of induction matricies (including tanks)
        status.induction = {}
        for i = 1, #self.induction do
            local matrix = self.induction[i] ---@type unit_session
            local db     = matrix.get_db()   ---@type imatrix_session_db

            status.induction[i] = { matrix.is_faulted(), db.formed, db.state, db.tanks }

            local fe_per_ms = self.avg_net.compute()
            local remaining = util.joules_to_fe_rf(util.trinary(fe_per_ms >= 0, db.tanks.energy_need, db.tanks.energy))
            status.power[4] = remaining / fe_per_ms
        end

        -- status of sps
        status.sps = {}
        for i = 1, #self.sps do
            local sps = self.sps[i]     ---@type unit_session
            local db  = sps.get_db()    ---@type sps_session_db
            status.sps[i] = { sps.is_faulted(), db.formed, db.state, db.tanks }
        end

        -- status of dynamic tanks
        status.tanks = {}
        for i = 1, #self.tanks do
            local tank = self.tanks[i]  ---@type unit_session
            local db   = tank.get_db()  ---@type dynamicv_session_db
            status.tanks[tank.get_device_idx()] = { tank.is_faulted(), db.formed, db.state, db.tanks }
        end

        -- radiation monitors (environment detectors)
        status.envds = {}
        for i = 1, #self.envd do
            local envd = self.envd[i]   ---@type unit_session
            local db   = envd.get_db()  ---@type envd_session_db
            status.envds[envd.get_device_idx()] = { envd.is_faulted(), db.radiation, db.radiation_raw }
        end

        return status
    end

    --#endregion

    -- supervisor sessions reporting the list of active RTU sessions
    ---@param rtu_sessions table session list of all connected RTUs
    function public.report_rtus(rtu_sessions) self.rtu_conn_count = #rtu_sessions end

    -- get the units in this facility
    ---@nodiscard
    function public.get_units() return self.units end

    return public
end

return facility
