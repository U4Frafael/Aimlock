--[[
    FOCUS SYSTEM — Versão Otimizada
    ================================
    Melhorias principais:
      • RaycastParams reutilizado e só recriado quando a lista de jogadores muda
      • UI atualizada em intervalos (0.15s) em vez de cada frame
      • Sistema de lock com histerese, grace period e cooldown entre trocas
      • isInvisible usa cache por personagem para evitar GetDescendants em loop
      • Loops de jogadores só correm quando necessário (alvo inválido)
      • Separação clara: Targeting / Camera / UI / Input
--]]

--------------------------------------------------
--// SERVICES
--------------------------------------------------
local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")

--------------------------------------------------
--// PLAYER / CAMERA
--------------------------------------------------
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

--------------------------------------------------
--// SETTINGS
--------------------------------------------------
local CONFIG = {
    FOV_RADIUS    = 150,      -- Raio do FOV em pixels
    SMOOTHNESS    = 0.95,     -- Suavidade da câmara (lerp)
    TOGGLE_KEY    = Enum.KeyCode.Q,
    UI_KEY        = Enum.KeyCode.J,
    AIM_KEY       = Enum.UserInputType.MouseButton2,

    -- Targeting
    HYSTERESIS    = 40,       -- Pixels de vantagem dados ao alvo atual vs candidatos
    GRACE_PERIOD  = 0.25,     -- Segundos antes de largar um alvo que saiu do FOV
    SWITCH_COOLDOWN = 0.3,    -- Segundos mínimos entre trocas de alvo

    -- UI
    UI_UPDATE_RATE = 0.15,    -- Intervalo de atualização da UI (segundos)
}

--------------------------------------------------
--// STATES
--------------------------------------------------
local State = {
    enabled        = false,
    holding        = false,
    uiVisible      = true,
    teamCheck      = true,
    wallCheck      = true,
    showFOV        = true,
    invisibleCheck = true,
}

-- Targeting
local lockedTarget    = nil   -- Alvo atual bloqueado
local graceTimer      = 0     -- Tempo restante de grace period
local lastSwitchTime  = 0     -- Última vez que o alvo trocou

-- UI dirty flags — só redesenha quando algo muda
local uiDirty     = true
local uiTimer     = 0

--------------------------------------------------
--// RAYCAST PARAMS (reutilizado, só recriado quando necessário)
--------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Blacklist

-- Reconstrói o filtro do raycast quando jogadores entram/saem
local function rebuildRayFilter()
    local filtered = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then
            table.insert(filtered, plr.Character)
        end
    end
    rayParams.FilterDescendantsInstances = filtered
end

rebuildRayFilter()
Players.PlayerAdded:Connect(rebuildRayFilter)
Players.PlayerRemoving:Connect(rebuildRayFilter)
Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(rebuildRayFilter)
    plr.CharacterRemoving:Connect(rebuildRayFilter)
end)

--------------------------------------------------
--// GUI
--------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "FocusUI"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 290, 0, 320)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(70, 70, 70)
stroke.Thickness = 1
stroke.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingTop   = UDim.new(0, 40)
padding.PaddingLeft  = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.Parent = frame

local title = Instance.new("TextLabel")
title.Size               = UDim2.new(1, 0, 0, 28)
title.BackgroundTransparency = 1
title.Text               = "TERROR DO EB"
title.Font               = Enum.Font.GothamBold
title.TextSize           = 14
title.TextColor3         = Color3.fromRGB(255, 255, 255)
title.Parent             = frame

--------------------------------------------------
--// BUTTONS
--------------------------------------------------
local function createButton(text)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(1, 0, 0, 34)
    b.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
    b.TextColor3       = Color3.fromRGB(255, 255, 255)
    b.Text             = text
    b.Font             = Enum.Font.Gotham
    b.TextSize         = 12
    b.BorderSizePixel  = 0
    b.Parent           = frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)

    local s = Instance.new("UIStroke")
    s.Color       = Color3.fromRGB(90, 90, 90)
    s.Thickness   = 1
    s.Transparency = 0.25
    s.Parent      = b

    b.MouseEnter:Connect(function()
        b.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
        s.Transparency = 0
    end)
    b.MouseLeave:Connect(function()
        b.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
        s.Transparency = 0.25
    end)
    return b
end

local toggleBtn = createButton("Focus: OFF")
local teamBtn   = createButton("Team Check: ON")
local wallBtn   = createButton("Wall Check: ON")
local fovBtn    = createButton("FOV: ON")
local invisBtn  = createButton("Invisible Check: ON")

--------------------------------------------------
--// FOV SLIDER
--------------------------------------------------
local fovContainer = Instance.new("Frame")
fovContainer.Size             = UDim2.new(1, 0, 0, 28)
fovContainer.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
fovContainer.BorderSizePixel  = 0
fovContainer.Parent           = frame
Instance.new("UICorner", fovContainer).CornerRadius = UDim.new(0, 6)

local bar = Instance.new("Frame")
bar.Size             = UDim2.new(1, -10, 0, 6)
bar.Position         = UDim2.new(0, 5, 0.5, -3)
bar.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
bar.BorderSizePixel  = 0
bar.Parent           = fovContainer
Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

local fill = Instance.new("Frame")
fill.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
fill.BorderSizePixel  = 0
fill.Parent           = bar
Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

local dragging = false

fovContainer.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    local x       = input.Position.X
    local start   = fovContainer.AbsolutePosition.X
    local size    = fovContainer.AbsoluteSize.X
    local percent = math.clamp((x - start) / size, 0, 1)
    CONFIG.FOV_RADIUS = math.floor(1 + (399 * percent))
    uiDirty = true  -- Slider mudou, força redesenho
end)

--------------------------------------------------
--// FOV VISUAL
--------------------------------------------------
local fovCircle = Drawing.new("Circle")
fovCircle.Thickness    = 2
fovCircle.Color        = Color3.fromRGB(255, 80, 80)
fovCircle.Transparency = 0.6
fovCircle.Visible      = false

--------------------------------------------------
--// BUTTON EVENTS  (marcam uiDirty para redesenho imediato)
--------------------------------------------------
toggleBtn.MouseButton1Click:Connect(function()
    State.enabled = not State.enabled
    uiDirty = true
end)
teamBtn.MouseButton1Click:Connect(function()
    State.teamCheck = not State.teamCheck
    uiDirty = true
end)
wallBtn.MouseButton1Click:Connect(function()
    State.wallCheck = not State.wallCheck
    uiDirty = true
end)
fovBtn.MouseButton1Click:Connect(function()
    State.showFOV = not State.showFOV
    uiDirty = true
end)
invisBtn.MouseButton1Click:Connect(function()
    State.invisibleCheck = not State.invisibleCheck
    uiDirty = true
end)

--------------------------------------------------
--// INPUT
--------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CONFIG.TOGGLE_KEY then
        State.enabled = not State.enabled
        uiDirty = true
    end
    if input.KeyCode == CONFIG.UI_KEY then
        State.uiVisible = not State.uiVisible
        frame.Visible   = State.uiVisible
    end
    if input.UserInputType == CONFIG.AIM_KEY then
        State.holding = true
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == CONFIG.AIM_KEY then
        State.holding  = false
        lockedTarget   = nil   -- Limpa lock ao soltar
        graceTimer     = 0
    end
end)

--------------------------------------------------
--// TARGETING — Funções auxiliares
--------------------------------------------------

-- Cache de invisibilidade: evita chamar GetDescendants a cada frame
-- É limpo quando o personagem muda
local invisCache = {}

local function getLeftArm(char)
    return char:FindFirstChild("LeftHand")
        or char:FindFirstChild("LeftLowerArm")
        or char:FindFirstChild("LeftUpperArm")
        or char:FindFirstChild("Left Arm")
end

-- Verifica invisibilidade com cache por personagem
local function isInvisible(char)
    if invisCache[char] ~= nil then
        return invisCache[char]
    end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.Transparency < 0.8 then
            invisCache[char] = false
            return false
        end
    end
    invisCache[char] = true
    return true
end

-- Limpa cache quando o personagem é removido
Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function(char)
        invisCache[char] = nil
        char.DescendantAdded:Connect(function() invisCache[char] = nil end)
        char.DescendantRemoving:Connect(function() invisCache[char] = nil end)
    end)
    plr.CharacterRemoving:Connect(function(char)
        invisCache[char] = nil
    end)
end)

local function isValid(plr)
    if plr == player then return false end
    local char = plr.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if State.invisibleCheck and isInvisible(char) then return false end
    if not State.teamCheck then return true end
    if player.Team and plr.Team then
        return player.Team ~= plr.Team
    end
    return true
end

-- Raycast com params reutilizados (sem recriar a cada chamada)
local function hasLineOfSight(part)
    if not State.wallCheck then return true end
    local origin = camera.CFrame.Position
    local dir    = part.Position - origin
    local result = Workspace:Raycast(origin, dir, rayParams)
    if result then
        return result.Instance:IsDescendantOf(part.Parent)
    end
    return true
end

--------------------------------------------------
--// TARGETING — Sistema de lock com histerese e grace period
--------------------------------------------------

--[[
    Histerese: ao comparar candidatos com o alvo atual,
    adiciona HYSTERESIS pixels ao score do candidato.
    Isto significa que um novo alvo só "ganha" se for
    consideravelmente melhor, evitando trocas desnecessárias.

    Grace period: quando o alvo atual sai do FOV ou perde
    linha de visão, não troca imediatamente — espera
    GRACE_PERIOD segundos. Se o alvo voltar entretanto, mantém.
]]

local function scoreCandidate(arm)
    local pos, vis = camera:WorldToViewportPoint(arm.Position)
    if not vis then return nil end
    local center = fovCircle.Position
    local dist   = (Vector2.new(pos.X, pos.Y) - center).Magnitude
    if dist > CONFIG.FOV_RADIUS then return nil end
    return dist
end

local function findBestTarget()
    local best      = nil
    local bestScore = math.huge
    local now       = tick()

    for _, plr in ipairs(Players:GetPlayers()) do
        if not isValid(plr) then continue end
        local char = plr.Character
        local arm  = getLeftArm(char)
        if not arm then continue end
        if State.wallCheck and not hasLineOfSight(arm) then continue end

        local score = scoreCandidate(arm)
        if not score then continue end

        -- Histerese: penaliza candidatos que não são o alvo atual
        -- para dar estabilidade ao lock existente
        if arm ~= lockedTarget and now - lastSwitchTime < CONFIG.SWITCH_COOLDOWN then
            score = score + CONFIG.HYSTERESIS
        elseif arm ~= lockedTarget then
            score = score + CONFIG.HYSTERESIS * 0.5
        end

        if score < bestScore then
            bestScore = best and bestScore or score
            best      = arm
            bestScore = score
        end
    end

    return best
end

-- Atualiza o sistema de alvo com grace period
-- Chamado apenas quando holding == true
local function updateTarget(dt)
    local now = tick()

    -- Verifica se o alvo atual ainda é usável
    local currentValid = false
    if lockedTarget and lockedTarget.Parent then
        local char = lockedTarget.Parent
        local plr  = Players:GetPlayerFromCharacter(char)
        if plr and isValid(plr) then
            local score = scoreCandidate(lockedTarget)
            local los   = not State.wallCheck or hasLineOfSight(lockedTarget)
            if score and los then
                currentValid = true
                graceTimer   = 0
            end
        end
    end

    if not currentValid then
        if lockedTarget then
            -- Grace period: dá uma janela antes de largar o alvo
            graceTimer = graceTimer + dt
            if graceTimer < CONFIG.GRACE_PERIOD then
                return -- Mantém o alvo atual durante o grace period
            end
        end
        -- Grace expirou ou não havia alvo — procura novo
        local best = findBestTarget()
        if best ~= lockedTarget then
            lastSwitchTime = now
        end
        lockedTarget = best
        graceTimer   = 0
    end
end

--------------------------------------------------
--// UI — Atualização em intervalo (não a cada frame)
--------------------------------------------------
local function updateUI()
    toggleBtn.Text = State.enabled        and "Focus: ON"          or "Focus: OFF"
    teamBtn.Text   = State.teamCheck      and "Team Check: ON"     or "Team Check: OFF"
    wallBtn.Text   = State.wallCheck      and "Wall Check: ON"     or "Wall Check: OFF"
    fovBtn.Text    = State.showFOV        and "FOV: ON"            or "FOV: OFF"
    invisBtn.Text  = State.invisibleCheck and "Invisible Check: ON" or "Invisible Check: OFF"
    fill.Size      = UDim2.new((CONFIG.FOV_RADIUS - 1) / 399, 0, 1, 0)
    uiDirty = false
end

--------------------------------------------------
--// LOOP PRINCIPAL
--------------------------------------------------
RunService.RenderStepped:Connect(function(dt)

    -- ── FOV Circle (visual leve, corre sempre) ──────────────────
    local center = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
    fovCircle.Position = center
    fovCircle.Radius   = CONFIG.FOV_RADIUS
    fovCircle.Visible  = State.enabled and State.showFOV

    -- ── UI (só atualiza quando necessário ou no intervalo) ───────
    uiTimer = uiTimer + dt
    if uiDirty or uiTimer >= CONFIG.UI_UPDATE_RATE then
        updateUI()
        uiTimer = 0
    end

    -- ── Targeting + Câmara (só corre quando ativo e a segurar) ───
    if not State.enabled or not State.holding then
        -- Limpa grace timer quando não está a apontar
        if not State.holding then graceTimer = 0 end
        return
    end

    updateTarget(dt)

    if not lockedTarget then return end

    -- ── Câmara suave com lerp ────────────────────────────────────
    local camPos    = camera.CFrame.Position
    local targetPos = lockedTarget.Position + Vector3.new(0, 0.15, 0)
    local dir       = (targetPos - camPos).Unit
    local goal      = CFrame.new(camPos, camPos + dir)

    -- Lerp frame-rate independente para evitar jitter
    local alpha = 1 - (1 - CONFIG.SMOOTHNESS) ^ (dt * 60)
    camera.CFrame = camera.CFrame:Lerp(goal, alpha)
end)
