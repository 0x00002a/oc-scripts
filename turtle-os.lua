local sides = require('sides')
local component = require('component')
local robot = component.proxy(component.list('robot')())
local event = require('event')
local robot_api = require('robot')
local thread = require('thread')

function table.deepcopy(tbl)
    local out = {}
    for k, v in pairs(tbl) do
        if type(v) == 'table' then
            v = table.deepcopy(v)
        end
        out[k] = v
    end
    return out
end

function table.tostring(tbl)
    local out = "{ "
    for k, v in pairs(tbl) do
        out = out .. ((type(k) == 'table' and table.tostring(k)) or tostring(k)) .. ': '
        if type(v) == 'function' then
            out = out .. " func"
        elseif type(v) == 'table' then
            out = out .. table.tostring(v)
        else
            out = out .. tostring(v)
        end
        out = out .. ', '
    end
    out = out .. ' }'
    return out
end

local Coord = {}

function Coord:new(x, y, z)
    local c = {}
    c.x = tonumber(x) or 0
    c.y = tonumber(y) or 0
    c.z = tonumber(z) or 0
    function c:tostring()
        return '{ x: ' .. tostring(self.x) .. ", y: " .. tostring(self.y) .. ', z: ' .. tostring(self.z) .. " }"
    end

    function c:add(b)
        local rs = table.deepcopy(self)
        rs.x = self.x + b.x
        rs.y = self.y + b.y
        rs.z = self.z + b.z
        return rs
    end
    function c:sub(b)
        local rs = table.deepcopy(self)
        rs.x = self.x - b.x
        rs.y = self.y - b.y
        rs.z = self.z - b.z
        return rs
    end

    return c
end


local MineContext = {}
function MineContext:new(width, height, home)
    local m = {}

    function m:rotate(clockwise)
        local newside = nil
        if self.direction == sides.back then
            newside = (clockwise and sides.left) or sides.right
        elseif self.direction == sides.forward then
            newside = (clockwise and sides.right) or sides.left
        elseif self.direction == sides.right then
            newside = (clockwise and sides.back) or sides.forward

        elseif self.direction == sides.left then
            newside = (clockwise and sides.forward) or sides.back
        end
        self.direction = newside
        robot.turn(clockwise)
    end
    function m:point_to(side)
        if self.direction == side then
            return
        end
        local clockwise = true -- TODO: optimisation point, reduce turns
        while self.direction ~= side do
            self:rotate(clockwise)
        end
    end


    function m:move(to)
        local translate = to
        function point_and_move(side, blocks)
            if blocks == 0 then
                return
            end

            local oldside = self.direction
            self:point_to(side)
            for _ = 1, math.abs(blocks) do
                robot.move(sides.forward)
            end
            self:point_to(oldside)
        end
        local function handle_negatives()
            if translate.x < 0 then
                point_and_move(sides.left, translate.x)
            end

            -- special case, cannot point up or down
            if translate.y < 0 then
                for _ = translate.y, -1 do
                    robot.move(sides.down)
                end
            end
            if translate.z < 0 then
                point_and_move(sides.back, translate.z)
            end
        end
        local function handle_positives()
            if translate.z > 0 then
               point_and_move(sides.forward, translate.z)
            end

            -- special case, cannot point up or down
            if translate.y > 0 then
                for _ = 1, translate.y do
                    robot.move(sides.up)
                end
            end
            if translate.x > 0 then
                point_and_move(sides.right, translate.x)
            end
        end
        handle_negatives()
        handle_positives()

        self.pos = to
    end

    function m:moveabs(to)
        self:move(to:sub(self.pos))
    end
    function m:tick()
        local target = Coord:new()
        --print("tick: " .. self.home:tostring())
        if self.corner ~= 'topright' and self.pos.x >= self.max_width and self.pos.y >= self.max_height then
            target.z = target.z + 1
            self.corner = 'topright'
        elseif self.corner ~= 'topleft' and self.pos.x <= self.home.x and self.pos.y >= self.max_height then
            target.z = target.z + 1
            self.corner = 'topleft'
        elseif self.pos.x >= self.max_width and self.pos.y > self.home.y then
            target.x = target.x - 1
        elseif self.pos.x >= self.max_width then
            target.y = target.y + 1
            self.corner = 'botright'
        elseif self.pos.x <= self.home.x and self.pos.y <= self.home.y then
            print("mov y")
            target.y = target.y + 1
        elseif self.pos.x <= self.home.x then
            print("mov x")
            target.x = target.x + 1
        end
        print("mov: ", table.tostring(target))
        self:move(target)
    end
    m.max_width = tonumber(width)
    m.max_height = tonumber(height)
    m.home = home
    m.pos = Coord:new()
    m.corner = 'botleft'
    m.direction = sides.forward
    return m
end

local function handle_stop_cmd(context)
    if context.mine_thread == nil then
        print("not running!")
        return
    end
    context.mine_thread:kill()
end
local function handle_moveabs_cmd(context, tox, toy, toz)
    if context.mine_thread ~= nil then
        print("cannot move while mining, please run stop first")
        return
    end
    local to = Coord:new(tox, toy, toz)
    context.minectx:move(to:sub(context.minectx.pos))
end

local function handle_start_cmd(context, width, height)
    if context.mine_thread ~= nil then
        print("already mining!")
        return
    end
    context.minectx.max_width = tonumber(width)
    context.minectx.max_height = tonumber(height)
    context.mine_thread = thread.create(function(ctx)
        while true do
            if not xpcall(function() ctx:tick() end, function(err) print("error while mining: ", err) end) then
                print("aborting mine due to errors")
                break
            end
            os.sleep(0.1)
        end
    end, table.deepcopy(context.minectx))
    print("started mining")
end

function table.extend(from, other)
    for _, v in pairs(other) do
        if type(v) == 'table' then
            table.extend(from, v)
        else
            table.insert(from, v)
        end
    end
end

DIGIT_PATTERN = "[%-%d]+"

function table.from_generator(gen)
    local out = {}
    table.extend(out, table.pack(gen()))
    return out
end

local function handle_exit_cmd(ctx)
    if ctx.mine_thread ~= nil then
        handle_stop_cmd(ctx)
    end
    ctx.running = false
end

local function handle_movrel_cmd(ctx, dx, dy, dz)
    if ctx.mine_thread ~= nil then
        print("cannot move while mining")
        return
    end
    local to = Coord:new(dx, dy, dz)
    ctx.minectx:move(to)
end

local RunContext = {}
function RunContext:new()
    local ctx = {}
    ctx.running = true
    ctx.minectx = MineContext:new(0, 0, Coord:new())
    ctx.mine_thread = nil

    function ctx:cmdloop()
        local function unpack_ent(entry)
            local reg = "(%a+)%s?(.+)"
            for cmd, args in string.gmatch(entry, reg) do
                return cmd, args
            end
        end
        io.stdout:write("> ")
        local ent_raw = io.stdin:read("*L")
        local cmd, args_raw = unpack_ent(ent_raw)
        local cmd_tbl = {
            moveabs = { '(%d+) (%d+) (%d+)', handle_moveabs_cmd },
            start = { '(%d+) (%d+)', handle_start_cmd },
            stop = { nil, handle_stop_cmd },
            exit = {nil, handle_exit_cmd },
            move = {string.format('(%s) (%s) (%s)', DIGIT_PATTERN, DIGIT_PATTERN, DIGIT_PATTERN), handle_movrel_cmd  }
        }
        local resolved_cmd = cmd_tbl[cmd]
        if resolved_cmd == nil then
            print("unknown command: '" .. cmd .. "'")
            return
        end
        print(args_raw)
        local args = (resolved_cmd[1] ~= nil) and table.from_generator(string.gmatch(args_raw, resolved_cmd[1]))
        if args == nil then
            args = {}
            print("nil args")
        end
        print(table.tostring(args))
        resolved_cmd[2](self, table.unpack(args))
    end


    function ctx:mainloop()
        while self.running do
            local id, _, x, y = event.pull(0.01, "interrupted")
            if id == 'interrupted' then
                print("stopping")
                break
            else
                self:cmdloop()
            end
        end
    end
    return ctx
end


RunContext:new():mainloop()
