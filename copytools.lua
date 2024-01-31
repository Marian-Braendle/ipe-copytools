label = "Copy Tools"
about = [[
Tools to create different patterns of objects.

By Marian Braendle
]]

---Settings
local DEFAULT_COPYCOLOR = { 0.0, 0.5, 1.0 }
local DEFAULT_NINSTANCES = 5

-- shortcuts.ipelet_1_copytools = "Ctrl+Alt+R"
-- shortcuts.ipelet_2_copytools = "Ctrl+Alt+L"
-- shortcuts.ipelet_3_copytools = "Ctrl+Alt+P"

---Global constants/functions
transformShape = _G.transformShape
type = _G.type
M = ipe.Matrix
V = ipe.Vector
R = ipe.Rect

local PI_1_2 = 1.57079632679489661923
local PI     = 3.14159265358979323846
local PI_3_2 = 4.71238898038468985769
local PI_2   = 6.28318530717958647692
local MAT_ROT45 = M(0, 1, -1, 0)
local MARK_TYPE = { vertex = 1, splineCP = 2, center = 3, radius = 4, minor = 5, current = 6, scissor = 7 }

------------------ Helper Functions ------------------
local function dump(t, max_level, cur_level)
    local INDENT = 2
    max_level = max_level or 10
    cur_level = cur_level or 1
    if type(t) == "table" and cur_level <= max_level then
        local s = "{\n"
        for k, v in pairs(t) do
            if type(k) ~= "number" then k = "\"" .. k .. "\"" end
            s = s ..  string.rep(" ", cur_level * INDENT) .. "[" .. k .. "] = " .. dump(v, max_level, cur_level + 1) .. ",\n"
        end
        return s .. string.rep(" ", (cur_level - 1) * INDENT) .. "}"
    else
        if type(t) == "userdata" and t["__name"] == "Ipe.vector" then
            return string.format("x = %.17g, y = %.17g", t.x, t.y) -- high precision for vectors
        else
            return tostring(t)
        end
    end
end

local function cloneTable(tab)
    if type(tab) ~= "table" then return tab end
    local cloned = {}
    for k, v in pairs(tab) do
        cloned[cloneTable(k)] = cloneTable(v)
    end
    return _G.setmetatable(cloned, _G.getmetatable(tab))
end

---Calculate corrected matrix respecting the transformation type
local function correctedObjectMatrix(obj, m)
    -- This correction is important for objects that have been transformed but whose transformation
    -- types are not "affine", for example a rotated object with "translations" type or a "rigid" object
    -- with applied non-uniform scaling
    local trafoType = obj:get("transformations")
    if trafoType == "translations" then
        return ipe.Translation(m:translation())
    elseif trafoType == "rigid" then
        local el = m:elements()
        return ipe.Translation(m:translation()) * ipe.Rotation(V(el[1], el[2]):angle())
    else -- "affine"
        return m
    end
end

local function simpleReferenceShape(obj, m)
    -- FIXME: rotated in case of circular pattern
    local pos = m * obj:matrix() * obj:position()
    return { {
        type = "curve", closed = false,
        { type = "segment", pos - V(10, 0), pos + V(10, 0) }
    }, {
        type = "curve", closed = false,
        { type = "segment", pos - V(0, 10), pos + V(0, 10) }
    } }
end

local function simpleTextShape(obj, m)
    local width, height, depth = obj:dimensions()
    local totalHeight = height + depth
    local vAlign, hAlign = obj:get("verticalalignment"), obj:get("horizontalalignment")
    local hOffset = { left = 0, right = width, hcenter = 0.5 * width }
    local vOffset = { top = totalHeight, bottom = 0, vcenter = 0.5 * totalHeight, baseline = depth }
    local pos = V(-hOffset[hAlign], -vOffset[vAlign])
    local shape = { {
        type = "curve", closed = true,
        { type = "segment", pos, pos + V(width, 0) },
        { type = "segment", pos + V(width, 0), pos + V(width, totalHeight) },
        { type = "segment", pos + V(width, totalHeight), pos + V(0, totalHeight) }
    } }
    local trafo = correctedObjectMatrix(obj, m * obj:matrix() * ipe.Translation(obj:position()))
    transformShape(trafo, shape)
    return shape
end

local function simpleImageShape(obj, m)
    -- Unfortunately, it is not possible to access irect of the image object directly.
    -- However, we can use the bounding box of the untransformed image object to compute it indirectly.
    local trafo =  obj:matrix()
    local inv = trafo:inverse()
    local bbox = R()
    obj:addToBBox(bbox, inv)
    local bottomLeft = bbox:bottomLeft()
    local topRight = bbox:topRight()
    local shape = { {
        type = "curve", closed = true,
        { type = "segment", bottomLeft, V(topRight.x, bottomLeft.y) },
        { type = "segment", V(topRight.x, bottomLeft.y), topRight },
        { type = "segment", topRight, V(bottomLeft.x, topRight.y) }
    } }
    transformShape(correctedObjectMatrix(obj, m * obj:matrix()), shape)
    return shape
end

local function createSimpleShape(obj, m)
    local objType = obj:type()
    if objType == "path" then
        local shape = obj:shape()
        transformShape(correctedObjectMatrix(obj, m * obj:matrix()), shape)
        return shape
    elseif objType == "reference" then
        return simpleReferenceShape(obj, m)
    elseif objType == "group" then
        -- Recursively create simple shapes and apply group transformation
        local shape = {}
        for _, el in ipairs(obj:elements()) do
            for _, newEl in ipairs(createSimpleShape(el, correctedObjectMatrix(obj, m * obj:matrix()))) do
                shape[#shape + 1] = newEl
            end
        end
        return shape
    elseif objType == "text" then
        return simpleTextShape(obj, m)
    elseif objType == "image" then
        return simpleImageShape(obj, m)
    else
        print("[ERROR] unsupported type " .. objType)
        return {}
    end
end

------------------ Circular Pattern ------------------
CIRCPATTERNTOOL = {}
CIRCPATTERNTOOL.__index = CIRCPATTERNTOOL

function CIRCPATTERNTOOL:new(model, iObjects)
    local tool = {}
    _G.setmetatable(tool, CIRCPATTERNTOOL)
    tool.model = model
    model.ui:shapeTool(tool)
    tool.nInstances = DEFAULT_NINSTANCES
    tool.setColor(table.unpack(DEFAULT_COPYCOLOR))
    tool.iObjects = iObjects
    tool.simpleShapes = {}
    for _, iObj in ipairs(tool.iObjects) do
        local simpleShape = createSimpleShape(model:page()[iObj], ipe.Matrix())
        for _, path in ipairs(simpleShape) do
            tool.simpleShapes[#tool.simpleShapes + 1] = path
        end
    end
    tool.posAngle = -1 -- Distribute along path
    tool:updatePosTrafos()
    tool:setCopyShape()
    -- Create hook for action_set_origin to update the tool when new origin is set
    tool.action_set_origin_orig = model.action_set_origin
    model.action_set_origin = function(model)
        tool.action_set_origin_orig(model) -- Call original method
        tool:updatePosTrafos()
        tool:setCopyShape()
        tool.model.ui:update(false) -- Update tool
    end
    return tool
end

function CIRCPATTERNTOOL:finish()
    -- Restore original action_set_origin
    self.model.action_set_origin = self.action_set_origin_orig
    self.model.ui:finishTool()
end

function CIRCPATTERNTOOL:updatePosTrafos()
    local posTrafos = {}
    local step = (self.posAngle == -1) and (PI_2 / self.nInstances) or (self.posAngle * PI / 180.0)
    for i = 0, self.nInstances - 1 do
        if i * step >= PI_2 then break end
        posTrafos[#posTrafos+1] = ipe.Translation(self.model.snap.origin) * ipe.Rotation(i * step) * ipe.Translation(-self.model.snap.origin)
    end
    self.posTrafos = posTrafos
end

function CIRCPATTERNTOOL:setCopyShape()
    local shapes = {}
    for _, trafo in ipairs(self.posTrafos) do
        local newShapes = cloneTable(self.simpleShapes)
        transformShape(trafo, newShapes)
        for _, shape in ipairs(newShapes) do
            shapes[#shapes + 1] = shape
        end
    end
    self.setShape(shapes)
end

function CIRCPATTERNTOOL:mouseButton(button, modifiers, press)
    if button == 2 then
        self:showMenu()
    end
end

function CIRCPATTERNTOOL:mouseMove()
    self.model.ui:explain("0-9: # instances | J/K: +/- # instances | Right: set # instances | Space: accept | Set new origin")
end

function CIRCPATTERNTOOL:acceptCopy()
    local p = self.model:page()
    local t = {
        label = "Create circular pattern with " .. self.nInstances .. " instances",
        pno = self.model.pno,
        vno = self.model.vno,
        iObjects = self.iObjects,
        posTrafos = self.posTrafos,
        layer = p:active(self.model.vno),
        original = p:clone(),
        undo = _G.revertOriginal
    }
    t.redo = function(t, doc)
        local p = doc[t.pno]
        -- Don't duplicate objects at origin
        for iPosTrafo = 2, #t.posTrafos do
            for _, iObj in ipairs(t.iObjects) do
                p:insert(nil, p[iObj]:clone(), 2, t.layer)
                p:transform(#p, t.posTrafos[iPosTrafo])
            end
        end
    end
    self.model:register(t)
end

function CIRCPATTERNTOOL:key(text, modifiers)
    if text == "\027" then -- Esc
        self:finish()
        return true
    elseif text == " " then -- Space: accept
        self:acceptCopy()
        self:finish()
        return true
    elseif text:match("^[%djk]$") then -- 0-9: set # instances
        if text == "j" then
            self.nInstances = math.max(self.nInstances - 1, 0)
        elseif text == "k" then
            self.nInstances = self.nInstances + 1
        else
            self.nInstances = tonumber(text)
        end
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
        return true
    else -- Not consumed
        return false
    end
end

function CIRCPATTERNTOOL:showMenu()
    local m = ipeui.Menu(self.model.ui:win())
    local gp = self.model.ui:globalPos()
    m:add("action_set_nInstances", "Set number of total instances")
    m:add("action_set_posAngle", "Set fixed angle between instances")
    if self.posAngle ~= -1 then m:add("action_set_posDistribute", "Distribute instances") end
    m:add("accept", "Accept")
    local item = m:execute(gp.x, gp.y)
    if item == "accept" then
        self:acceptCopy()
        self:finish()
        return
    elseif item == "action_set_nInstances" then
        local str = self.model:getString("Enter number of total instances") or ""
        if not str:match("^%d+$") then return end
        self.nInstances = tonumber(str)
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
    elseif item == "action_set_posAngle" then
        local x = tonumber(self.model:getString("Enter angle between instances in degrees") or -1)
        if x == nil or x < 0 then return end
        self.posAngle = x
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
    elseif item == "action_set_posDistribute" then
        self.posAngle = -1;
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
    end
end

function createCircularPattern(model)
    local p = model:page()
    if not p:hasSelection() then
        model.ui:explain("no selection")
        return
    end
    if not model.snap.with_axes then
        model:warning("Cannot create circular pattern", "The coordinate system has not been set")
        return
    end
    local iObjects = {}
    for i, _, sel, _ in p:objects() do
        if sel then
            iObjects[#iObjects+1] = i
        end
    end
    CIRCPATTERNTOOL:new(model, iObjects)
end

------------------- Linear Pattern -------------------
LINPATTERNTOOL = {}
LINPATTERNTOOL.__index = LINPATTERNTOOL

function LINPATTERNTOOL:new(model, iObjects)
    local tool = {}
    _G.setmetatable(tool, LINPATTERNTOOL)
    tool.model = model
    model.ui:shapeTool(tool)
    tool.nInstances = DEFAULT_NINSTANCES
    tool.setColor(table.unpack(DEFAULT_COPYCOLOR))
    tool.iObjects = iObjects
    tool.simpleShapes = {}
    for _, iObj in ipairs(tool.iObjects) do
        local simpleShape = createSimpleShape(model:page()[iObj], ipe.Matrix())
        for _, path in ipairs(simpleShape) do
            tool.simpleShapes[#tool.simpleShapes + 1] = path
        end
    end
    tool:resetCP()
    tool:updatePosTrafos()
    tool:setCopyShape()
    tool:setShapeMarks()
    return tool
end

function LINPATTERNTOOL:finish()
    self.model.ui:finishTool()
end

function LINPATTERNTOOL:resetCP()
    -- Calculate reasonable default displacement vector
    local frame = self.model.doc:sheets():find("layout").framesize
    -- Get bounding box of selected objects
    local p = self.model:page()
    local box = R()
    for _, i in ipairs(self.model:selection()) do
        box:add(p:bbox(i))
    end
    local startCP = 0.5 * (box:bottomLeft() + box:topRight())
    local width = math.max(16, math.min(box:width() / 2, frame.x / 5))
    local endCP = startCP + V(width, 0)
    self.cp = { startCP, endCP }
    self.curCP = 2
end

function LINPATTERNTOOL:setShapeMarks()
    local marks = { self.cp[1], MARK_TYPE.center, self.cp[2], MARK_TYPE.minor, self.cp[self.curCP], MARK_TYPE.current }
    local aux = { { type = "curve", closed = false, { type = "segment", self.cp[1], self.cp[2] } } }
    self.setShape(aux, 1)
    self.setMarks(marks)
end

function LINPATTERNTOOL:updatePosTrafos()
    local posTrafos = {}
    local dirVector = self.cp[2] - self.cp[1]
    for i = 0, self.nInstances - 1 do
        posTrafos[#posTrafos+1] = ipe.Translation(i * dirVector)
    end
    self.posTrafos = posTrafos
end

function LINPATTERNTOOL:setCopyShape()
    local shapes = {}
    for _, trafo in ipairs(self.posTrafos) do
        local newShapes = cloneTable(self.simpleShapes)
        transformShape(trafo, newShapes)
        for _, shape in ipairs(newShapes) do
            shapes[#shapes + 1] = shape
        end
    end
    self.setShape(shapes)
end

function LINPATTERNTOOL:mouseButton(button, modifiers, press)
    self.moving = false
    if button == 1 then
        if not press then
            self.setSnapping(true, false)
            return
        end
        local mousePos = self.model.ui:unsnappedPos()
        local sqDist1 = (mousePos - self.cp[1]):sqLen()
        local sqDist2 = (mousePos - self.cp[2]):sqLen()
        self.curCP = (sqDist1 < sqDist2) and 1 or 2
        self.moving = true
        self.setSnapping(false, false)
        self:updatePosTrafos()
        self:setCopyShape()
        self:setShapeMarks()
        self.model.ui:update(false) -- Update tool
    elseif button == 2 then
        self:showMenu()
        return
    end
end

function LINPATTERNTOOL:mouseMove()
    if self.moving then
        local pos = self.model.ui:pos()
        self.cp[self.curCP] = pos
        self:updatePosTrafos()
        self:setCopyShape()
        self:setShapeMarks()
        self.model.ui:update(false) -- Update tool
    end
    self.model.ui:explain("0-9: # instances | J/K: +/- # instances | Right: set # instances | Space: accept")
end

function LINPATTERNTOOL:acceptCopy()
    local p = self.model:page()
    local t = {
        label = "Create linear pattern with " .. self.nInstances .. " instances",
        pno = self.model.pno,
        vno = self.model.vno,
        iObjects = self.iObjects,
        posTrafos = self.posTrafos,
        layer = p:active(self.model.vno),
        original = p:clone(),
        undo = _G.revertOriginal
    }
    t.redo = function(t, doc)
        local p = doc[t.pno]
        -- Don't duplicate objects at origin
        for iPosTrafo = 2, #t.posTrafos do
            for _, iObj in ipairs(t.iObjects) do
                p:insert(nil, p[iObj]:clone(), 2, t.layer)
                p:transform(#p, t.posTrafos[iPosTrafo])
            end
        end
    end
    self.model:register(t)
end

function LINPATTERNTOOL:key(text, modifiers)
    if text == "\027" then -- Esc
        self:finish()
        return true
    elseif text == " " then -- Space: accept
        self.moving = false
        self:acceptCopy()
        self:finish()
        return true
    elseif text:match("^[%djk]$") then -- 0-9: set # instances
        if text == "j" then
            self.nInstances = math.max(self.nInstances - 1, 0)
        elseif text == "k" then
            self.nInstances = self.nInstances + 1
        else
            self.nInstances = tonumber(text)
        end
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
        return true
    else -- Not consumed
        return false
    end
end

function LINPATTERNTOOL:showMenu()
    local m = ipeui.Menu(self.model.ui:win())
    local gp = self.model.ui:globalPos()
    m:add("action_set_nInstances", "Set number of total instances")
    m:add("accept", "Accept")
    local item = m:execute(gp.x, gp.y)
    if item == "accept" then
        self.moving = false
        self:acceptCopy()
        self:finish()
        return
    elseif item == "action_set_nInstances" then
        local str = self.model:getString("Enter number of total instances") or ""
        if not str:match("^%d+$") then return end
        self.nInstances = tonumber(str)
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
    end
end

function createLinearPattern(model)
    local p = model:page()
    if not p:hasSelection() then
        model.ui:explain("no selection")
        return
    end
    local iObjects = {}
    for i, _, sel, _ in p:objects() do
        if sel then
            iObjects[#iObjects+1] = i
        end
    end
    LINPATTERNTOOL:new(model, iObjects)
end

----------------- Pattern along Path -----------------

---Approximate circular arc as Beziers (see https://pomax.github.io/bezierinfo/#circles_cubic)
local function arcToBeziers(m, theta)
    -- local K = 0.55228474983079334
    local K = 0.55197038140111286 -- Minimize total squared error
    local beziers = {}
    while theta > 0 do
        if theta >= PI_1_2 then
            beziers[#beziers + 1] = { type = "spline", m * V(1, 0), m * V(1, K), m * V(K, 1), m * V(0, 1) }
            theta = theta - PI_1_2
            m = m * MAT_ROT45
        else
            local st, ct, k = math.sin(theta), math.cos(theta), 4 * math.tan(theta / 4) / 3
            beziers[#beziers + 1] = { type = "spline", m * V(1, 0), m * V(1, k), m * V(ct + k * st, st - k * ct), m * V(ct, st) }
            break
        end
    end
    return beziers
end

---Create length LUT for a Bezier using line segments
local function bezierLenLUT(splinePath, n)
    local a, b, c, d = table.unpack(splinePath)
    local lut = { 0 }
    local lastP = nil
    for i = 0, n do
        local t = i / n
        local tn = 1 - t
        local p = tn * tn * tn * a + 3 * t * tn * tn * b + 3 * t * t * tn * c + t * t * t * d
        if i > 0 then
            lut[#lut + 1] = lut[#lut] + (p - lastP):len()
        end
        lastP = p
    end
    return lut
end

---Approximate path using only line segments and Bezier curves
local function preprocessPath(path)
    local newPath = { closed = false }
    if path.type == "curve" then
        for _, subpath in ipairs(path) do
            if subpath.type == "segment" then
                newPath[#newPath + 1] = subpath
            elseif subpath.type == "spline" or subpath.type == "oldspline" or subpath.type == "cardinal" or subpath.type == "spiro" then
                local beziers = ipe.splineToBeziers(subpath, false)
                for _, bez in ipairs(beziers) do
                    newPath[#newPath + 1] = bez
                end
            elseif subpath.type == "arc" then
                local alpha, beta = subpath.arc:angles()
                local beziers = arcToBeziers(subpath.arc:matrix() * ipe.Rotation(alpha), ipe.normalizeAngle(beta - alpha, 0))
                if #beziers > 0 then
                    -- For (debug) drawing exact equality of start and end points is needed
                    beziers[1][1] = subpath[1]
                    beziers[#beziers][4] = subpath[2]
                end
                for _, bez in ipairs(beziers) do
                    newPath[#newPath + 1] = bez
                end
            else
                print("ERROR: unsupported subpath type:", dump(subpath))
                return nil
            end
        end
        if path.closed then
            -- Add closing line segment
            local first, last = path[1][1], path[#path][#path[#path]]
            newPath[#newPath + 1] = { type = "segment", last, first }
            newPath.closed = true
        end
    elseif path.type == "closedspline" then
        local beziers = ipe.splineToBeziers(path, true)
        for _, bez in ipairs(beziers) do
            newPath[#newPath + 1] = bez
        end
        newPath.closed = true
    elseif path.type == "ellipse" then
        local beziers = arcToBeziers(path[1], PI_2)
        for _, bez in ipairs(beziers) do
            newPath[#newPath + 1] = bez
        end
        newPath.closed = true
    else
        print("ERROR: unsupported path type")
        print(dump(path))
        return nil
    end
    return newPath
end

---Create length table for all segments of a preprocessed path (only line segments & Beziers)
local function createPathLengths(path)
    local res = { total = 0, closed = path.closed }
    for _, subpath in ipairs(path) do
        local segLen
        if subpath.type == "segment" then
            if subpath[1] ~= subpath[2] then
                segLen = (subpath[2] - subpath[1]):len()
                res[#res + 1] = { start = res.total, len = segLen, type = subpath.type, segment = subpath }
                res.total = res.total + segLen
            end
        elseif subpath.type == "spline" then
            if subpath[1] ~= subpath[2] or subpath[1] ~= subpath[3] or subpath[1] ~= subpath[4] then
                local bezierLUT = bezierLenLUT(subpath, 50)
                -- LUT summation is good enough for arc length computation in our case.
                -- Otherwise, for more accurate arc length approximation Legendre-Gauss summation could be used for example.
                segLen = bezierLUT[#bezierLUT]
                res[#res + 1] = { start = res.total, len = segLen, type = subpath.type, spline = subpath, lut = bezierLUT }
                res.total = res.total + segLen
            end
        else
            print("[ERROR]", "Unsupported subpath:", dump(subpath))
            return nil
        end
    end
    if #res == 0 then print("ERROR", "length table has no entries") return nil end

    if res[1].type == "segment" then
        res.startPos = res[1].segment[1]
    elseif res[1].type == "spline" then
        res.startPos = res[1].spline[1]
    else
        print("[ERROR]", "Unsupported subpath to calculate start position:", dump(res[1]))
    end
    return res
end

---Calculate transformation matrices of positions, posDist = -1 means distribute along path
local function calcPathPosTrafos(lenTable, n, posDist, fixedRot)
    local posTrafos = {}
    local invOrigTrafo = M()
    local curSeg = 1
    if posDist == -1 then
        posDist = lenTable.closed and (lenTable.total / n) or (lenTable.total / (n - 1))
    end
    for i = 0, n - 1 do
        local globalDist = (n > 1) and i * posDist or 0
        if globalDist > lenTable.total then
            return posTrafos
        end
        while curSeg < #lenTable and lenTable[curSeg].start + lenTable[curSeg].len < globalDist do
            curSeg = curSeg + 1
        end
        local pos, tangent
        local localDist = globalDist - lenTable[curSeg].start
        if lenTable[curSeg].type == "segment" then
            local s, e = lenTable[curSeg].segment[1], lenTable[curSeg].segment[2]
            assert(lenTable[curSeg].len > 0, "segment length must be positive")
            local t = localDist / lenTable[curSeg].len
            -- Interpolate line segment
            pos = (1 - t) * s + t * e
            tangent = (e - s):normalized()
        elseif lenTable[curSeg].type == "spline" then
            local lut = lenTable[curSeg].lut
            local j = 2
            while j < #lut and localDist > lut[j] do
                j = j + 1
            end
            -- Interpolate t of approximated segment of spline
            local fract = ((lut[j] - lut[j - 1]) > 0) and ((localDist - lut[j]) / (lut[j] - lut[j - 1])) or 0
            local t = (j - 1 + fract) / (#lut - 1)
            local a, b, c, d = table.unpack(lenTable[curSeg].spline)
            local tn = 1 - t
            pos = tn * tn * tn * a + 3 * t * tn * tn * b + 3 * t * t * tn * c + t * t * t * d
            tangent = a * ((6 - 3 * t) * t - 3) + b * (t * (9 * t - 12) + 3) + t * (t * (3 * d - 9 * c) + 6 * c)
        else
            print("[ERROR] unsupported segment type in length table: ", lenTable[curSeg].type)
        end
        if i == 0 then
            if fixedRot then
                invOrigTrafo = ipe.Translation(-pos)
            else
                invOrigTrafo = ipe.Rotation(-tangent:angle()) * ipe.Translation(-pos)
            end
        end
        if fixedRot then
            posTrafos[#posTrafos + 1] = ipe.Translation(pos)  * invOrigTrafo
        else
            posTrafos[#posTrafos + 1] = ipe.Translation(pos) * ipe.Rotation(tangent:angle()) * invOrigTrafo
        end
    end
    return posTrafos
end


PATHPATTERNTOOL = {}
PATHPATTERNTOOL.__index = PATHPATTERNTOOL

function PATHPATTERNTOOL:new(model, lengthTable, iObjects)
    local tool = {}
    _G.setmetatable(tool, PATHPATTERNTOOL)
    tool.model = model
    model.ui:shapeTool(tool)
    tool.nInstances = DEFAULT_NINSTANCES
    tool.setColor(table.unpack(DEFAULT_COPYCOLOR))
    tool.lengthTable = lengthTable
    tool.iObjects = iObjects
    tool.simpleShapes = {}
    for _, iObj in ipairs(tool.iObjects) do
        local simpleShape = createSimpleShape(model:page()[iObj], ipe.Matrix())
        for _, path in ipairs(simpleShape) do
            tool.simpleShapes[#tool.simpleShapes + 1] = path
        end
    end
    tool.posDist = -1 -- Distribute along path
    tool.fixedOrientation = false
    tool:resetCP()
    tool:updatePosTrafos()
    tool:setCopyShape()
    tool:setShapeMarks()
    return tool
end

function PATHPATTERNTOOL:finish()
    self.model.ui:finishTool()
end

function PATHPATTERNTOOL:resetCP()
    self.origin = self.lengthTable.startPos
    self.projection = self.origin
end

function PATHPATTERNTOOL:setShapeMarks()
    local marks = { self.origin, MARK_TYPE.minor, self.origin, MARK_TYPE.current }
    local aux = {{ type = "curve", closed = false, { type = "segment", self.origin, self.projection } }}
    self.setShape(aux, 1)
    self.setMarks(marks)
end

function PATHPATTERNTOOL:updatePosTrafos()
    local displacement = ipe.Translation(self.projection - self.origin)
    local posTrafos = {}
    for _, trafo in ipairs(calcPathPosTrafos(self.lengthTable, self.nInstances, self.posDist, self.fixedOrientation)) do
        posTrafos[#posTrafos+1] = trafo * displacement
    end
    self.posTrafos = posTrafos
end

function PATHPATTERNTOOL:setCopyShape()
    local shapes = {}
    for _, trafo in ipairs(self.posTrafos) do
        local newShapes = cloneTable(self.simpleShapes)
        transformShape(trafo, newShapes)
        for _, shape in ipairs(newShapes) do
            shapes[#shapes + 1] = shape
        end
    end
    self.setShape(shapes)
end

function PATHPATTERNTOOL:mouseButton(button, modifiers, press)
    self.moving = false
    if button == 1 then
        if not press then
            self.setSnapping(true, false)
            return
        end
        self.moving = true
        self.setSnapping(false, false)
        self:updatePosTrafos()
        self:setCopyShape()
        self:setShapeMarks()
        self.model.ui:update(false) -- Update tool
    elseif button == 2 then
        self:showMenu()
    end
end

function PATHPATTERNTOOL:mouseMove()
    if self.moving then
        self.origin = self.model.ui:pos()
        self:updatePosTrafos()
        self:setCopyShape()
        self:setShapeMarks()
        self.model.ui:update(false) -- Update tool
    end
    self.model.ui:explain("0-9: # instances | J/K: +/- # instances | Right: set # instances | Space: accept | Set new origin")
end

function PATHPATTERNTOOL:acceptCopy()
    local p = self.model:page()
    local t = {
        label = "Create pattern along path with " .. self.nInstances .. " instances",
        pno = self.model.pno,
        vno = self.model.vno,
        iObjects = self.iObjects,
        posTrafos = self.posTrafos,
        layer = p:active(self.model.vno),
        original = p:clone(),
        undo = _G.revertOriginal
    }
    t.redo = function(t, doc)
        local p = doc[t.pno]
        -- Don't duplicate objects at origin
        local iStart = (self.origin == self.projection) and 2 or 1
        for iPosTrafo = iStart, #t.posTrafos do
            for _, iObj in ipairs(t.iObjects) do
                p:insert(nil, p[iObj]:clone(), 2, t.layer)
                p:transform(#p, t.posTrafos[iPosTrafo])
            end
        end
    end
    self.model:register(t)
end

function PATHPATTERNTOOL:key(text, modifiers)
    if text == "\027" then -- Esc
        self:finish()
        return true
    elseif text == " " then -- Space: accept
        self.moving = false
        self:acceptCopy()
        self:finish()
        return true
    elseif text:match("^[%djk]$") then -- 0-9: set # instances
        if text == "j" then
            self.nInstances = math.max(self.nInstances - 1, 0)
        elseif text == "k" then
            self.nInstances = self.nInstances + 1
        else
            self.nInstances = tonumber(text)
        end
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
        return true
    else -- Not consumed
        return false
    end
end

function PATHPATTERNTOOL:showMenu()
    local m = ipeui.Menu(self.model.ui:win())
    local gp = self.model.ui:globalPos()
    m:add("action_set_nInstances", "Set number of total instances")
    m:add("action_set_posDistance", "Set fixed distance between instances")
    if self.posDist ~= -1 then m:add("action_set_posDistribute", "Distribute instances along path") end
    if self.fixedOrientation then m:add("action_set_alignedOrientation", "Align instances to tangents") end
    if not self.fixedOrientation then m:add("action_set_fixedOrientation", "Set fixed orientation of instances") end
    m:add("accept", "Accept")
    local item = m:execute(gp.x, gp.y)
    if item == "accept" then
        self.moving = false
        self:acceptCopy()
        self:finish()
        return
    else
        if item == "action_set_nInstances" then
            local str = self.model:getString("Enter number of total instances") or ""
            if not str:match("^%d+$") then return end
            self.nInstances = tonumber(str)
        elseif item == "action_set_posDistance" then
            local x = tonumber(self.model:getString("Enter distance between instances in pts") or -1)
            if x == nil or x < 0 then return end
            self.posDist = x
        elseif item == "action_set_posDistribute" then
            self.posDist = -1;
        elseif item == "action_set_alignedOrientation" then
            self.fixedOrientation = false
        elseif item == "action_set_fixedOrientation" then
            self.fixedOrientation = true
        end
        self:updatePosTrafos()
        self:setCopyShape()
        self.model.ui:update(false) -- Update tool
    end
end

function createPatternAlongPath(model)
    local p = model:page()
    local prim = p:primarySelection()

    if not prim or p[prim]:type() ~= "path" then model:warning("Primary selection is not path") return end

    local pathShape = p[prim]:shape()
    if #pathShape > 1 then model:warning("Cannot duplicate along composed paths") return end

    local path = preprocessPath(pathShape[1])
    if path == nil then model:warning("Error while preprocessing path. See console for details.") return end

    -- Apply transformation matrix after converting to Beziers (see https://github.com/otfried/ipe/issues/491)
    transformShape(p[prim]:matrix(), { path })

    local lengthTable = createPathLengths(path)
    if lengthTable == nil then model:warning("Error while computing length table. See console for details.") return end

    local iObjects = {}
    for i, _, sel, _ in p:objects() do
        if sel and i ~= prim then
            iObjects[#iObjects+1] = i
        end
    end
    PATHPATTERNTOOL:new(model, lengthTable, iObjects)
end

------------------------------------------------------
methods = { {
    label = "Circular Pattern",
    run = createCircularPattern
}, {
    label = "Linear/Grid Pattern",
    run = createLinearPattern
}, {
    label = "Pattern along Path",
    run = createPatternAlongPath
} }
