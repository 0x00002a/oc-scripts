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

    function m:move(to)
        local translate = to
        if translate.z > 0 then
            for i = 0, translate.z do
                robot.move(sides.forward)
            end
        elseif translate.z < 0 then
            for i = translate.z, -1 do
                robot.move(sides.back)
            end
        end

        if translate.y > 0 then
            for i = 0, translate.y do
                robot.move(sides.up)
            end
        elseif translate.y < 0 then
            for i = translate.y, -1 do
                robot.move(sides.down)
            end
        end

        if translate.x > 0 then
            for i = 0, translate.x do
                robot.move(sides.right)
            end
        elseif translate.x < 0 then
            for i = translate.x, -1 do
                robot.move(sides.left)
            end
        end
        print("move: " .. self.pos:tostring() .. ' -> ' .. to:tostring())
        self.pos = to
    end

    function m:moveabs(to)
        self:move(to:sub(self.pos))
    end
    function m:tick()
        local target = table.deepcopy(self.pos)
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
            target.y = target.y + 1
        elseif self.pos.x <= self.home.x then
            target.x = target.x + 1
        end
        self:moveabs(target)
    end
    m.max_width = width
    m.max_height = height
    m.home = home
    m.pos = Coord:new()
    m.corner = 'botleft'
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
    context.minectx.max_width = width
    context.minectx.max_height = height
    context.mine_thread = thread.create(function(ctx)
        ctx:tick()
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
