-- #REQUIRES comms.lua
-- #REQUIRES modbus.lua
-- #REQUIRES mqueue.lua
-- #REQUIRES svsessions.lua

local PROTOCOLS = comms.PROTOCOLS
local RPLC_TYPES = comms.RPLC_TYPES
local SCADA_MGMT_TYPES = comms.SCADA_MGMT_TYPES
local RTU_ADVERT_TYPES = comms.RTU_ADVERT_TYPES

local SESSION_TYPE = svsessions.SESSION_TYPE

-- supervisory controller communications
function superv_comms(mode, num_reactors, modem, dev_listen, coord_listen)
    local self = {
        mode = mode,
        ln_seq_num = 0,
        num_reactors = num_reactors,
        modem = modem,
        dev_listen = dev_listen,
        coord_listen = coord_listen,
        reactor_struct_cache = nil
    }

    -- PRIVATE FUNCTIONS --

    -- open all channels
    local _open_channels = function ()
        if not self.modem.isOpen(self.dev_listen) then
            self.modem.open(self.dev_listen)
        end
        if not self.modem.isOpen(self.coord_listen) then
            self.modem.open(self.coord_listen)
        end
    end

    local _send_plc_linking = function (dest, msg)
        local packet = comms.scada_packet()
        packet.make(self.ln_seq_num, PROTOCOLS.RPLC, msg)
        self.modem.transmit(dest, self.dev_listen, packet.raw())
        self.ln_seq_num = self.ln_seq_num + 1
    end

    -- PUBLIC FUNCTIONS --

    -- reconnect a newly connected modem
    local reconnect_modem = function (modem)
        self.modem = modem
        _open_channels()
    end

    -- parse a packet
    local parse_packet = function(side, sender, reply_to, message, distance)
        local pkt = nil
        local s_pkt = scada_packet()

        -- parse packet as generic SCADA packet
        s_pkt.recieve(side, sender, reply_to, message, distance)

        if s_pkt.is_valid() then
            -- get as MODBUS TCP packet
            if s_pkt.protocol() == PROTOCOLS.MODBUS_TCP then
                local m_pkt = comms.modbus_packet()
                if m_pkt.decode(s_pkt) then
                    pkt = m_pkt.get()
                end
            -- get as RPLC packet
            elseif s_pkt.protocol() == PROTOCOLS.RPLC then
                local rplc_pkt = comms.rplc_packet()
                if rplc_pkt.decode(s_pkt) then
                    pkt = rplc_pkt.get()
                end
            -- get as SCADA management packet
            elseif s_pkt.protocol() == PROTOCOLS.SCADA_MGMT then
                local mgmt_pkt = comms.mgmt_packet()
                if mgmt_pkt.decode(s_pkt) then
                    pkt = mgmt_packet.get()
                end
            -- get as coordinator packet
            elseif s_pkt.protocol() == PROTOCOLS.COORD_DATA then
                local coord_pkt = comms.coord_packet()
                if coord_pkt.decode(s_pkt) then
                    pkt = coord_pkt.get()
                end
            else
                log._debug("attempted parse of illegal packet type " .. s_pkt.protocol(), true)
            end
        end

        return pkt
    end

    local handle_packet = function(packet)
        if packet ~= nil then
            local sender = packet.scada_frame.sender()
            local receiver = packet.scada_frame.receiver()
            local protocol = packet.scada_frame.protocol()

            -- device (RTU/PLC) listening channel
            if receiver == self.dev_listen then
                if protocol == PROTOCOLS.MODBUS_TCP then
                    -- MODBUS response
                elseif protocol == PROTOCOLS.RPLC then
                    -- reactor PLC packet
                    local session = svsessions.find_session(SESSION_TYPE.PLC_SESSION, sender)
                    if session then
                        if packet.type == RPLC_TYPES.LINK_REQ then
                            -- new device on this port? that's a collision
                            _send_plc_linking(sender, { RPLC_LINKING.COLLISION })
                        else
                            -- pass the packet onto the session handler
                            session.in_queue.push_packet(packet)
                        end
                    else
                        -- unknown session, is this a linking request?
                        if packet.type == RPLC_TYPES.LINK_REQ then
                            -- this is a linking request
                            local plc_id = svsessions.establish_plc_session(sender)
                            if plc_id == false then
                                -- reactor already has a PLC assigned
                                _send_plc_linking(sender, { RPLC_LINKING.COLLISION })
                            else
                                -- got an ID; assigned to a reactor successfully
                                _send_plc_linking(sender, { RPLC_LINKING.ALLOW })
                            end
                        else
                            -- force a re-link
                            _send_plc_linking(sender, { RPLC_LINKING.DENY })
                        end
                    end
                elseif protocol == PROTOCOLS.SCADA_MGMT then
                    -- SCADA management packet
                else
                    log._debug("illegal packet type " .. protocol .. " on device listening channel")
                end
            -- coordinator listening channel
            elseif reciever == self.coord_listen then
                if protocol == PROTOCOLS.SCADA_MGMT then
                    -- SCADA management packet
                elseif protocol == PROTOCOLS.COORD_DATA then
                    -- coordinator packet
                else
                    log._debug("illegal packet type " .. protocol .. " on coordinator listening channel")
                end
            else
                log._error("received packet on unused channel " .. receiver, true)
            end
        end
    end

    return {
        reconnect_modem = reconnect_modem,
        parse_packet = parse_packet,
        handle_packet = handle_packet
    }
end
