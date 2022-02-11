local sides = require('sides')
local component = require('component')
local robot = component.proxy(component.list('robot')())
local event = require('event')
local robot_api = require('robot')

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

function Coord:new()
    local c = {}
    c.x = 0
    c.y = 0
    c.z = 0
    function c:tostring()
        return '{ x: ' .. self.x .. ", y: " .. self.y .. ', z: ' .. self.z .. " }"
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
        print(table.tostring(robot))
        local translate = to:sub(self.pos)
        if translate.z > 0 then
            for i = 0, translate.z do
                robot.move(sides.forward)
            end
        elseif translate.z < 0 then
            for i = translate.z, 0, -1 do
                robot.move(sides.back)
            end
        end

        if translate.y > 0 then
            for i = 0, translate.y do
                robot.move(sides.up)
            end
        elseif translate.y < 0 then
            for i = translate.y, 0, -1 do
                robot.move(sides.down)
            end
        end

        if translate.x > 0 then
            for i = 0, translate.x do
                robot.move(sides.right)
            end
        elseif translate.x < 0 then
            for i = translate.x, 0, -1 do
                robot.move(sides.left)
            end
        end
        self.pos = to
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
        print("move: " .. self.pos:tostring() .. ' -> ' .. target:tostring())
        self:move(target)
    end
    m.max_width = width
    m.max_height = height
    m.home = home
    m.pos = Coord:new()
    m.corner = 'botleft'
    return m
end




local function mainloop()
    local context = MineContext:new(10, 10, Coord:new())
    while true do
        local id, _, x, y = event.pull(0.01, "interrupted")
        if id == 'interrupted' then
            print("stopping")
            break
        else
            context:tick()
        end
    end


end


mainloop()
