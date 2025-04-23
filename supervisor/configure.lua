--
-- Configuration GUI
--

local log         = require("scada-common.log")
local tcd         = require("scada-common.tcd")
local util        = require("scada-common.util")

local facility    = require("supervisor.config.facility")
local system      = require("supervisor.config.system")

local core        = require("graphics.core")
local themes      = require("graphics.themes")

local DisplayBox  = require("graphics.elements.DisplayBox")
local Div         = require("graphics.elements.Div")
local ListBox     = require("graphics.elements.ListBox")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local PushButton  = require("graphics.elements.controls.PushButton")

local println = util.println
local tri = util.trinary

local cpair = core.cpair

local CENTER = core.ALIGN.CENTER

-- changes to the config data/format to let the user know
local changes = {
    { "v1.2.12", { "Added front panel UI theme", "Added color accessibility modes" } },
    { "v1.3.2", { "Added standard with black off state color mode", "Added blue indicator color modes" } },
    { "v1.6.0", { "Added sodium emergency coolant option" } }
}

---@class svr_configurator
local configurator = {}

local style = {}

style.root          = cpair(colors.black, colors.lightGray)
style.header        = cpair(colors.white, colors.gray)

style.colors        = themes.smooth_stone.colors

style.bw_fg_bg      = cpair(colors.black, colors.white)
style.g_lg_fg_bg    = cpair(colors.gray, colors.lightGray)
style.nav_fg_bg     = style.bw_fg_bg
style.btn_act_fg_bg = cpair(colors.white, colors.gray)
style.btn_dis_fg_bg = cpair(colors.lightGray, colors.white)

---@class _svr_cfg_tool_ctl
local tool_ctl = {
    launch_startup = false,
    ask_config = false,
    has_config = false,
    viewing_config = false,
    jumped_to_color = false,

    view_cfg = nil,       ---@type PushButton
    color_cfg = nil,      ---@type PushButton
    color_next = nil,     ---@type PushButton
    color_apply = nil,    ---@type PushButton
    settings_apply = nil, ---@type PushButton

    num_units = nil,      ---@type NumberField
    en_fac_tanks = nil,   ---@type Checkbox
    tank_mode = nil,      ---@type RadioButton

    gen_summary = nil,    ---@type function
    load_legacy = nil,    ---@type function

    cooling_elems = {},   ---@type { line: Div, turbines: NumberField, boilers: NumberField, tank: Checkbox }[]
    tank_elems = {},      ---@type { div: Div, tank_opt: Radio2D, no_tank: TextBox }[]
    aux_cool_elems = {}   ---@type { line: Div, enable: Checkbox }[]
}

---@class svr_config
local tmp_cfg = {
    UnitCount = 1,
    CoolingConfig = {},     ---@type { TurbineCount: integer, BoilerCount: integer, TankConnection: boolean }[]
    FacilityTankMode = 0,   -- dynamic tank emergency coolant layout
    FacilityTankDefs = {},  ---@type integer[] each unit's tank connection target (0 = disconnected, 1 = unit, 2 = facility)
    FacilityTankList = {},  ---@type integer[] list of tanks by slot (0 = none or covered by an above tank, 1 = unit tank, 2 = facility tank)
    FacilityTankConns = {}, ---@type integer[] map of unit tank connections (indicies are units, values are tank indicies in the tank list)
    TankFluidTypes = {},    ---@type integer[] which type of fluid each tank in the tank list should be containing
    AuxiliaryCoolant = {},  ---@type boolean[] if a unit has auxiliary coolant
    ExtChargeIdling = false,
    SVR_Channel = nil,      ---@type integer
    PLC_Channel = nil,      ---@type integer
    RTU_Channel = nil,      ---@type integer
    CRD_Channel = nil,      ---@type integer
    PKT_Channel = nil,      ---@type integer
    PLC_Timeout = nil,      ---@type number
    RTU_Timeout = nil,      ---@type number
    CRD_Timeout = nil,      ---@type number
    PKT_Timeout = nil,      ---@type number
    TrustedRange = nil,     ---@type number
    AuthKey = nil,          ---@type string|nil
    LogMode = 0,            ---@type LOG_MODE
    LogPath = "",
    LogDebug = false,
    FrontPanelTheme = 1,    ---@type FP_THEME
    ColorMode = 1           ---@type COLOR_MODE
}

---@class svr_config
local ini_cfg = {}
---@class svr_config
local settings_cfg = {}

-- all settings fields, their nice names, and their default values
local fields = {
    { "UnitCount", "N\xb0 de Reatores", 1 },
    { "CoolingConfig", "Config. de Refrigera\xe7\xe3o", {} },
    { "FacilityTankMode", "Modo de Tanque", 0 },
    { "FacilityTankDefs", "Defini\xe7\xe3o de Tanques", {} },
    { "FacilityTankList", "Lista de Tanques", {} },         -- hidden
    { "FacilityTankConns", "Conex\xe3o de Tanquess", {} }, -- hidden
    { "TankFluidTypes", "Tipos de Fluido do Tanque", {} },
    { "AuxiliaryCoolant", "Refrig. de \xc1gua Aux.", {} },
    { "ExtChargeIdling", "Extended Charge Idling", false },
    { "SVR_Channel", "Canal do SVR", 16240 },
    { "PLC_Channel", "Canal do PLC", 16241 },
    { "RTU_Channel", "Canal do RTU", 16242 },
    { "CRD_Channel", "Canal do CRD", 16243 },
    { "PKT_Channel", "Canal do PKT", 16244 },
    { "PLC_Timeout", "Tempo Limite de Conex\xe3o do PLC", 5 },
    { "RTU_Timeout", "Tempo Limite de Conex\xe3o do RTU", 5 },
    { "CRD_Timeout", "Tempo Limite de Conex\xe3o do CRD", 5 },
    { "PKT_Timeout", "Tempo Limite de Conex\xe3o do PKT", 5 },
    { "TrustedRange", "Alcance de Confian\xe7a", 0 },
    { "AuthKey", "Chave de Auten. da Instala\xe7\xe3o" , ""},
    { "LogMode", "Modo do Registro", log.MODE.APPEND },
    { "LogPath", "Caminho do Registro", "/log.txt" },
    { "LogDebug", "Registrar Mensagens de Depura\xe7\xe3o", false },
    { "FrontPanelTheme", "Tema do Painel Frontal", themes.FP_THEME.SANDSTONE },
    { "ColorMode", "Modo de Cor", themes.COLOR_MODE.STANDARD }
}

-- load data from the settings file
---@param target svr_config
---@param raw boolean? true to not use default values
local function load_settings(target, raw)
    for _, v in pairs(fields) do settings.unset(v[1]) end

    local loaded = settings.load("/supervisor.settings")

    for _, v in pairs(fields) do target[v[1]] = settings.get(v[1], tri(raw, nil, v[3])) end

    return loaded
end

-- create the config view
---@param display DisplayBox
local function config_view(display)
    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

---@diagnostic disable-next-line: undefined-field
    local function exit() os.queueEvent("terminate") end

    TextBox{parent=display,y=1,text="Configurador do Supervisor",alignment=CENTER,fg_bg=style.header}

    local root_pane_div = Div{parent=display,x=1,y=2}

    local main_page = Div{parent=root_pane_div,x=1,y=1}
    local fac_cfg = Div{parent=root_pane_div,x=1,y=1}
    local net_cfg = Div{parent=root_pane_div,x=1,y=1}
    local log_cfg = Div{parent=root_pane_div,x=1,y=1}
    local clr_cfg = Div{parent=root_pane_div,x=1,y=1}
    local summary = Div{parent=root_pane_div,x=1,y=1}
    local changelog = Div{parent=root_pane_div,x=1,y=1}
    local import_err = Div{parent=root_pane_div,x=1,y=1}

    local main_pane = MultiPane{parent=root_pane_div,x=1,y=1,panes={main_page,fac_cfg,net_cfg,log_cfg,clr_cfg,summary,changelog,import_err}}

    --#region Main Page

    local y_start = 5

    TextBox{parent=main_page,x=2,y=2,height=2,text="Bem-vindo ao configurador do Supervisor! Por favor, selecione uma das op\xe7\xf5es a seguir."}

    if tool_ctl.ask_config then
        TextBox{parent=main_page,x=2,y=y_start,height=4,width=49,text="Aviso: Este dispositivo n\xe3o foi configurado para esta vers\xe3o do supervisor. Se voc\xea tinha uma configura\xe7\xe3o anteriormente, olhe o Registro de Altera\xe7\xf5es para ver o que mudou.",fg_bg=cpair(colors.red,colors.lightGray)}
        y_start = y_start + 5
    end

    local function view_config()
        tool_ctl.viewing_config = true
        tool_ctl.gen_summary(settings_cfg)
        tool_ctl.settings_apply.hide(true)
        main_pane.set_value(6)
    end

    if fs.exists("/supervisor/config.lua") then
        PushButton{parent=main_page,x=2,y=y_start,min_width=28,text="Importar 'config.lua' Antigo",callback=function()tool_ctl.load_legacy()end,fg_bg=cpair(colors.black,colors.cyan),active_fg_bg=btn_act_fg_bg}
        y_start = y_start + 2
    end

    PushButton{parent=main_page,x=2,y=y_start,min_width=20,text="Configurar Sistema",callback=function()main_pane.set_value(2)end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg}
    tool_ctl.view_cfg = PushButton{parent=main_page,x=2,y=y_start+2,min_width=20,text="Ver Configura\xe7\xe3o",callback=view_config,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}

    local function jump_color()
        tool_ctl.jumped_to_color = true
        tool_ctl.color_next.hide(true)
        tool_ctl.color_apply.show()
        main_pane.set_value(5)
    end

    local function startup()
        tool_ctl.launch_startup = true
        exit()
    end

    PushButton{parent=main_page,x=2,y=17,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}
    local start_btn = PushButton{parent=main_page,x=42,y=17,min_width=9,text="Inicializa\xe7\xe3o",callback=startup,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    tool_ctl.color_cfg = PushButton{parent=main_page,x=36,y=y_start,min_width=15,text="Op\xe7\xf5es de Cor",callback=jump_color,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    PushButton{parent=main_page,x=39,y=y_start+2,min_width=12,text="Change-Log",callback=function()main_pane.set_value(7)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    if tool_ctl.ask_config then start_btn.disable() end

    if not tool_ctl.has_config then
        tool_ctl.view_cfg.disable()
        tool_ctl.color_cfg.disable()
    end

    --#endregion

    local settings = { settings_cfg, ini_cfg, tmp_cfg, fields, load_settings }

    --#region Facility Configuration

    local fac_pane = facility.create(tool_ctl, main_pane, settings, fac_cfg, style)

    --#endregion

    --#region System Configuration

    local divs = { net_cfg, log_cfg, clr_cfg, summary, import_err }

    system.create(tool_ctl, main_pane, settings, divs, fac_pane, style, exit)

    --#endregion

    --#region Config Change Log

    local cl = Div{parent=changelog,x=2,y=4,width=49}

    TextBox{parent=changelog,x=1,y=2,text=" Config Change Log",fg_bg=bw_fg_bg}

    local c_log = ListBox{parent=cl,x=1,y=1,height=12,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    for _, change in ipairs(changes) do
        TextBox{parent=c_log,text=change[1],fg_bg=bw_fg_bg}
        for _, v in ipairs(change[2]) do
            local e = Div{parent=c_log,height=#util.strwrap(v,46)}
            TextBox{parent=e,y=1,x=1,text="- ",fg_bg=cpair(colors.gray,colors.white)}
            TextBox{parent=e,y=1,x=3,text=v,height=e.get_height(),fg_bg=cpair(colors.gray,colors.white)}
        end
    end

    PushButton{parent=cl,x=1,y=14,text="\x1bVoltar",callback=function()main_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
end

-- reset terminal screen
local function reset_term()
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
end

-- run the supervisor configurator
---@param ask_config? boolean indicate if this is being called by the startup app due to an invalid configuration
function configurator.configure(ask_config)
    tool_ctl.ask_config = ask_config == true

    load_settings(settings_cfg, true)
    tool_ctl.has_config = load_settings(ini_cfg)

    -- these need to be initialized as they are used before being set
    tmp_cfg.FacilityTankMode = ini_cfg.FacilityTankMode
    tmp_cfg.TankFluidTypes = { table.unpack(ini_cfg.TankFluidTypes) }

    reset_term()

    -- set overridden colors
    for i = 1, #style.colors do
        term.setPaletteColor(style.colors[i].c, style.colors[i].hex)
    end

    local status, error = pcall(function ()
        local display = DisplayBox{window=term.current(),fg_bg=style.root}
        config_view(display)

        while true do
            local event, param1, param2, param3 = util.pull_event()

            -- handle event
            if event == "timer" then
                tcd.handle(param1)
            elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or event == "double_click" then
                local m_e = core.events.new_mouse_event(event, param1, param2, param3)
                if m_e then display.handle_mouse(m_e) end
            elseif event == "char" or event == "key" or event == "key_up" then
                local k_e = core.events.new_key_event(event, param1, param2)
                if k_e then display.handle_key(k_e) end
            elseif event == "paste" then
                display.handle_paste(param1)
            end

            if event == "terminate" then return end
        end
    end)

    -- restore colors
    for i = 1, #style.colors do
        local r, g, b = term.nativePaletteColor(style.colors[i].c)
        term.setPaletteColor(style.colors[i].c, r, g, b)
    end

    reset_term()
    if not status then
        println("configurator error: " .. error)
    end

    return status, error, tool_ctl.launch_startup
end

return configurator
