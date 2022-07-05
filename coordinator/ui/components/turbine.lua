local core = require("graphics.core")

local style = require("coordinator.ui.style")

local Div            = require("graphics.elements.div")
local DataIndicator  = require("graphics.elements.indicators.data")
local StateIndicator = require("graphics.elements.indicators.state")
local Rectangle      = require("graphics.elements.rectangle")
local TextBox        = require("graphics.elements.textbox")
local VerticalBar    = require("graphics.elements.indicators.vbar")

local TEXT_ALIGN = core.graphics.TEXT_ALIGN

local cpair = core.graphics.cpair
local border = core.graphics.border

local function new_view(root, x, y)
    local turbine = Rectangle{parent=root,border=border(1, colors.gray, true),width=23,height=7,x=x,y=y}

    local text_fg_bg = cpair(colors.black, colors.lightGray)
    local lu_col = cpair(colors.gray, colors.gray)

    local status     = StateIndicator{parent=turbine,x=8,y=1,states=style.turbine.states,value=3,min_width=10}
    local production = DataIndicator{parent=turbine,x=5,y=3,lu_colors=lu_col,label="",unit="MFE",format="%10.2f",value=3.2,width=16,fg_bg=text_fg_bg}
    local flow_rate  = DataIndicator{parent=turbine,x=5,y=4,lu_colors=lu_col,label="",unit="mB/t",format="%10.0f",value=801523,commas=true,width=16,fg_bg=text_fg_bg}

    local steam = VerticalBar{parent=turbine,x=2,y=1,fg_bg=cpair(colors.white,colors.gray),height=5,width=2}

    steam.update(0.12)
end

return new_view