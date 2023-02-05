--
-- Main SCADA Coordinator GUI
--

local util          = require("scada-common.util")

local iocontrol     = require("coordinator.iocontrol")
local sounder       = require("coordinator.sounder")

local style         = require("coordinator.ui.style")

local imatrix       = require("coordinator.ui.components.imatrix")
local process_ctl   = require("coordinator.ui.components.processctl")
local unit_overview = require("coordinator.ui.components.unit_overview")

local core          = require("graphics.core")

local ColorMap      = require("graphics.elements.colormap")
local DisplayBox    = require("graphics.elements.displaybox")
local Div           = require("graphics.elements.div")
local TextBox       = require("graphics.elements.textbox")

local PushButton    = require("graphics.elements.controls.push_button")
local SwitchButton  = require("graphics.elements.controls.switch_button")

local DataIndicator = require("graphics.elements.indicators.data")

local TEXT_ALIGN = core.graphics.TEXT_ALIGN

local cpair = core.graphics.cpair

-- create new main view
---@param monitor table main viewscreen
local function init(monitor)
    local facility = iocontrol.get_db().facility
    local units = iocontrol.get_db().units

    local main = DisplayBox{window=monitor,fg_bg=style.root}

    -- window header message
    local header = TextBox{parent=main,y=1,text="Nuclear Generation Facility SCADA Coordinator",alignment=TEXT_ALIGN.CENTER,height=1,fg_bg=style.header}
    local ping = DataIndicator{parent=main,x=1,y=1,label="SVTT",format="%d",value=0,unit="ms",lu_colors=cpair(colors.lightGray, colors.white),width=12,fg_bg=style.header}
    -- max length example: "01:23:45 AM - Wednesday, September 28 2022"
    local datetime = TextBox{parent=main,x=(header.width()-42),y=1,text="",alignment=TEXT_ALIGN.RIGHT,width=42,height=1,fg_bg=style.header}

    facility.ps.subscribe("sv_ping", ping.update)
    facility.ps.subscribe("date_time", datetime.set_value)

    local uo_1, uo_2, uo_3, uo_4    ---@type graphics_element

    local cnc_y_start = 3
    local row_1_height = 0

    -- unit overviews
    if facility.num_units >= 1 then
        uo_1 = unit_overview(main, 2, 3, units[1])
        row_1_height = uo_1.height()
    end

    if facility.num_units >= 2 then
        uo_2 = unit_overview(main, 84, 3, units[2])
        row_1_height = math.max(row_1_height, uo_2.height())
    end

    cnc_y_start = cnc_y_start + row_1_height + 1

    if facility.num_units >= 3 then
        -- base offset 3, spacing 1, max height of units 1 and 2
        local row_2_offset = cnc_y_start

        uo_3 = unit_overview(main, 2, row_2_offset, units[3])
        cnc_y_start = row_2_offset + uo_3.height() + 1

        if facility.num_units == 4 then
            uo_4 = unit_overview(main, 84, row_2_offset, units[4])
            cnc_y_start = math.max(cnc_y_start, row_2_offset + uo_4.height() + 1)
        end
    end

    -- command & control    

    cnc_y_start = cnc_y_start

    -- induction matrix and process control interfaces are 24 tall + space needed for divider
    local cnc_bottom_align_start = main.height() - 26

    assert(cnc_bottom_align_start >= cnc_y_start, "main display not of sufficient vertical resolution (add an additional row of monitors)")

    TextBox{parent=main,y=cnc_bottom_align_start,text=util.strrep("\x8c", header.width()),alignment=TEXT_ALIGN.CENTER,height=1,fg_bg=cpair(colors.lightGray,colors.gray)}

    cnc_bottom_align_start = cnc_bottom_align_start + 2

    local process = process_ctl(main, 2, cnc_bottom_align_start)

    -- testing
    ---@fixme remove test code

    -- ColorMap{parent=main,x=98,y=(main.height()-1)}

    local audio = Div{parent=main,width=23,height=23,x=107,y=cnc_bottom_align_start}

    PushButton{parent=audio,x=16,y=1,text="TEST 1",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_1}
    PushButton{parent=audio,x=16,text="TEST 2",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_2}
    PushButton{parent=audio,x=16,text="TEST 3",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_3}
    PushButton{parent=audio,x=16,text="TEST 4",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_4}
    PushButton{parent=audio,x=16,text="TEST 5",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_5}
    PushButton{parent=audio,x=16,text="TEST 6",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_6}
    PushButton{parent=audio,x=16,text="TEST 7",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_7}
    PushButton{parent=audio,x=16,text="TEST 8",min_width=8,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_8}
    PushButton{parent=audio,x=16,text="STOP",min_width=8,fg_bg=cpair(colors.black,colors.red),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.stop}
    PushButton{parent=audio,x=16,text="PSCALE",min_width=8,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_power_scale}

    SwitchButton{parent=audio,x=1,y=12,text="CONTAINMENT BREACH",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_breach}
    SwitchButton{parent=audio,x=1,text="CONTAINMENT RADIATION",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_rad}
    SwitchButton{parent=audio,x=1,text="REACTOR LOST",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_lost}
    SwitchButton{parent=audio,x=1,text="CRITICAL DAMAGE",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_crit}
    SwitchButton{parent=audio,x=1,text="REACTOR DAMAGE",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_dmg}
    SwitchButton{parent=audio,x=1,text="REACTOR OVER TEMP",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_overtemp}
    SwitchButton{parent=audio,x=1,text="REACTOR HIGH TEMP",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_hightemp}
    SwitchButton{parent=audio,x=1,text="REACTOR WASTE LEAK",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_wasteleak}
    SwitchButton{parent=audio,x=1,text="REACTOR WASTE HIGH",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_highwaste}
    SwitchButton{parent=audio,x=1,text="RPS TRANSIENT",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_rps}
    SwitchButton{parent=audio,x=1,text="RCS TRANSIENT",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_rcs}
    SwitchButton{parent=audio,x=1,text="TURBINE TRIP",min_width=23,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=cpair(colors.white,colors.gray),callback=sounder.test_turbinet}

    local imatrix_1 = imatrix(main, 131, cnc_bottom_align_start, facility.induction_data_tbl[1], facility.induction_ps_tbl[1])

    return main
end

return init
