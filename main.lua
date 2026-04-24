--[[
    FOCUS SYSTEM — Versão 3D Targeting
    =====================================
    Melhorias desta versão sobre a anterior:

    [3D TARGETING]
      • Score calculado por ÂNGULO ao raio da câmara em vez de distância 2D em píxeis
        — completamente independente de shift lock ou rotação do personagem
        — um braço "à frente" da câmara tem sempre score baixo, mesmo que o personagem
          esteja de lado ou de costas
      • Sem chamadas a WorldToViewportPoint no targeting — substituído por
        matemática 3D pura (dot product + acos), mais rápido e mais preciso

    [POSIÇÃO DE MIRA COMPOSTA]
      • Em vez de mirar num único osso, calcula o centróide ponderado do braço esquerdo
          LeftHand × 2  +  LeftLowerArm × 1  +  LeftUpperArm × 0.5
        O ponto de mira fica naturalmente perto da mão (parte mais distal),
        mas não sofre tanto com animações abruptas do pulso
      • R6 (Left Arm) é tratado como caso especial — usa a posição direta

    [POSIÇÃO SUAVIZADA]
      • smoothedAimPos lerpa em direção ao centróide real a cada frame
        — elimina jitter causado pelas animações do braço
        — reset automático ao trocar de alvo

    [LINHA DE VISÃO]
      • hasLineOfSight faz o raycast para o centróide (posição de mira real)
        em vez do osso primário — consistência entre targeting e câmara

    [CÂMARA]
      • Usa smoothedAimPos diretamente, sem offset vertical arbitrário
      • Lerp frame-rate independente mantido

    [PERFORMANCE]
      • currentCamCF, currentMaxAngle, currentHystAngle calculados
        uma vez por frame e reutilizados em todas as funções
      • Restantes otimizações da versão anterior mantidas
        (RaycastParams reutilizado, cache de invisibilidade, UI em intervalo)
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
    FOV_RADIUS      = 150,    -- Raio do FOV em píxeis (visual + gate de targeting)
    SMOOTHNESS      = 0.95,   -- Suavidade da câmara (lerp)
    ARM_SMOOTH      = 0.30,   -- Suavidade da posição de mira (lerp anti-jitter)
    TOGGLE_KEY      = Enum.KeyCode.Q,
    UI_KEY          = Enum.KeyCode.J,
    AIM_KEY         = Enum.UserInputType.MouseButton2,

    -- Targeting
    HYSTERESIS      = 40,     -- Vantagem em píxeis dada ao alvo atual (convertida para ângulo)
    GRACE_PERIOD    = 0.25,   -- Segundos antes de largar um alvo que saiu do FOV
    SWITCH_COOLDOWN = 0.3,    -- Segundos mínimos entre trocas de alvo

    -- UI
    UI_UPDATE_RATE  = 0.15,   -- Intervalo de atualização da UI (segundos)
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
local lockedTarget    = nil   -- Part primário do braço (identidade do alvo)
local graceTimer      = 0
local lastSwitchTime  = 0

-- Posição de mira suavizada
local smoothedAimPos  = nil   -- Vector3 lerped, usado pela câmara
local prevLocked      = nil   -- Detecta troca de alvo para reset do smooth

-- Cache por frame (calculado uma vez em RenderStepped, usado em todas as funções)
local currentCamCF    = CFrame.new()
local currentMaxAngle = 0       -- FOV_RADIUS em radianos
local currentHystAngle = 0      -- HYSTERESIS em radianos

-- UI
local uiDirty = true
local uiTimer = 0

--------------------------------------------------
--// RAYCAST PARAMS (reutilizado, só recriado quando necessário)
--------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Blacklist

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
    s.Color        = Color3.fromRGB(90, 90, 90)
    s.Thickness    = 1
    s.Transparency = 0.25
    s.Parent       = b

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
    uiDirty = true
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
--// BUTTON EVENTS
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

        if not State.enabled then
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        end
    end

    if input.KeyCode == CONFIG.UI_KEY then
        State.uiVisible = not State.uiVisible
        frame.Visible   = State.uiVisible
    end

    if input.UserInputType == CONFIG.AIM_KEY then
        State.holding = true

        -- 🔒 LOCK NO CENTRO (cursor continua visível)
        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == CONFIG.AIM_KEY then
        State.holding  = false
        lockedTarget   = nil
        smoothedAimPos = nil
        prevLocked     = nil
        graceTimer     = 0

        -- 🔓 UNLOCK
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    end
end)

--------------------------------------------------
--// TARGETING — Funções auxiliares
--------------------------------------------------
local invisCache = {}

--[[
    Retorna (primaryPart, aimPos):
      primaryPart — Part usado para identificar o alvo (comparações, LOS)
      aimPos      — Vector3 centróide ponderado do braço, usado para mirar

    Pesos R15:  LeftHand × 2  |  LeftLowerArm × 1  |  LeftUpperArm × 0.5
    O resultado fica naturalmente próximo da mão sem ser instável ao pulso.
    R6 usa o único Part disponível (Left Arm) sem centróide.
--]]
local function getArmTarget(char)
    local leg = char:FindFirstChild("Left Arm")  -- R6
    if leg then
        return leg, leg.Position
    end

    local hand  = char:FindFirstChild("LeftHand")
    local lower = char:FindFirstChild("LeftLowerArm")
    local upper = char:FindFirstChild("LeftUpperArm")

    local primary = hand or lower or upper
    if not primary then return nil, nil end

    -- Centróide ponderado
    local wSum, wTotal = Vector3.zero, 0
    local partWeights  = { [hand] = 2, [lower] = 1, [upper] = 0.5 }
    for part, w in pairs(partWeights) do
        if part then
            wSum   = wSum + part.Position * w
            wTotal = wTotal + w
        end
    end

    local aimPos = (wTotal > 0) and (wSum / wTotal) or primary.Position
    return primary, aimPos
end

local function isInvisible(char)
    if invisCache[char] ~= nil then return invisCache[char] end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.Transparency < 0.8 then
            invisCache[char] = false
            return false
        end
    end
    invisCache[char] = true
    return true
end

Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function(char)
        invisCache[char] = nil
        char.DescendantAdded:Connect(function()   invisCache[char] = nil end)
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

--[[
    Raycast para aimPos (centróide) — não para o osso primário.
    Garante consistência: a linha de visão é verificada exatamente
    para o ponto que a câmara vai mirar.
    Todos os personagens estão no filtro, por isso apenas
    geometria do mapa pode bloquear o raycast.
--]]
local function hasLineOfSight(armPart, aimPos)
    if not State.wallCheck then return true end
    local origin = currentCamCF.Position
    local dir    = aimPos - origin
    local result = Workspace:Raycast(origin, dir, rayParams)
    if result then
        return result.Instance:IsDescendantOf(armPart.Parent)
    end
    return true
end

--------------------------------------------------
--// TARGETING 3D — Score por ângulo ao raio da câmara
--------------------------------------------------
--[[
    Em vez de medir distância 2D ao centro do ecrã em píxeis,
    medimos o ÂNGULO entre o vetor câmara→braço e o LookVector da câmara.

    Vantagens:
      • Independente da rotação do personagem — funciona sem shift lock
      • Independente da distância ao alvo — um braço longe e um perto
        têm o mesmo score se estiverem no mesmo ângulo
      • Sem WorldToViewportPoint — pura matemática vetorial

    Fórmula:
      toArm    = aimPos - camPos
      forward  = dot(toArm, LookVector)       → componente frontal
      cosAngle = forward / |toArm|            → cosseno do ângulo
      angle    = acos(cosAngle)               → ângulo em radianos
--]]
local function scoreCandidate(aimPos)
    local toArm  = aimPos - currentCamCF.Position
    local forward = toArm:Dot(currentCamCF.LookVector)

    -- Braço atrás da câmara — ignora
    if forward <= 0 then return nil end

    local cosAngle = forward / toArm.Magnitude
    local angle    = math.acos(math.clamp(cosAngle, -1, 1))

    -- Fora do FOV (em radianos) — ignora
    if angle > currentMaxAngle then return nil end

    return angle  -- menor = mais centrado = melhor
end

local function findBestTarget()
    local best      = nil
    local bestAim   = nil
    local bestScore = math.huge
    local now       = tick()

    for _, plr in ipairs(Players:GetPlayers()) do
        if not isValid(plr) then continue end
        local char = plr.Character
        local arm, aimPos = getArmTarget(char)
        if not arm or not aimPos then continue end
        if State.wallCheck and not hasLineOfSight(arm, aimPos) then continue end

        local score = scoreCandidate(aimPos)
        if not score then continue end

        -- Histerese em radianos: penaliza candidatos que não são o alvo atual.
        -- Só troca se o novo alvo for claramente melhor (não apenas ligeiramente).
        if arm ~= lockedTarget then
            if now - lastSwitchTime < CONFIG.SWITCH_COOLDOWN then
                score = score + currentHystAngle          -- penalidade máxima em cooldown
            else
                score = score + currentHystAngle * 0.5   -- penalidade reduzida após cooldown
            end
        end

        if score < bestScore then
            bestScore = score
            best      = arm
            bestAim   = aimPos
        end
    end

    return best, bestAim
end

local function updateTarget(dt)
    local now = tick()

    -- Verifica se o alvo atual ainda é válido
    local currentValid = false
    if lockedTarget and lockedTarget.Parent then
        local char = lockedTarget.Parent
        local plr  = Players:GetPlayerFromCharacter(char)
        if plr and isValid(plr) then
            local _, aimPos = getArmTarget(char)
            if aimPos then
                local score = scoreCandidate(aimPos)
                local los   = hasLineOfSight(lockedTarget, aimPos)
                if score and los then
                    currentValid = true
                    graceTimer   = 0
                end
            end
        end
    end

    if not currentValid then
        if lockedTarget then
            -- Grace period: aguarda antes de largar o alvo
            graceTimer = graceTimer + dt
            if graceTimer < CONFIG.GRACE_PERIOD then
                return  -- Mantém lock durante o grace period
            end
        end
        -- Grace expirou ou não havia alvo — procura novo
        local best, _ = findBestTarget()
        if best ~= lockedTarget then
            lastSwitchTime = now
            smoothedAimPos = nil  -- Reset do smooth ao trocar de alvo
        end
        lockedTarget = best
        graceTimer   = 0
    end
end

--------------------------------------------------
--// UI — Atualização em intervalo
--------------------------------------------------
local function updateUI()
    toggleBtn.Text = State.enabled        and "Focus: ON"           or "Focus: OFF"
    teamBtn.Text   = State.teamCheck      and "Team Check: ON"      or "Team Check: OFF"
    wallBtn.Text   = State.wallCheck      and "Wall Check: ON"      or "Wall Check: OFF"
    fovBtn.Text    = State.showFOV        and "FOV: ON"             or "FOV: OFF"
    invisBtn.Text  = State.invisibleCheck and "Invisible Check: ON" or "Invisible Check: OFF"
    fill.Size      = UDim2.new((CONFIG.FOV_RADIUS - 1) / 399, 0, 1, 0)
    uiDirty = false
end

--------------------------------------------------
--// LOOP PRINCIPAL
--------------------------------------------------
RunService.RenderStepped:Connect(function(dt)

    -- ── Cache por frame ──────────────────────────────────────────
    -- Calculado uma vez aqui e reutilizado por scoreCandidate,
    -- findBestTarget, hasLineOfSight — sem repetir operações de câmara
    currentCamCF = camera.CFrame
    local halfVFOV       = math.rad(camera.FieldOfView / 2)
    local pixelsPerRad   = camera.ViewportSize.Y / (2 * math.tan(halfVFOV))
    currentMaxAngle      = CONFIG.FOV_RADIUS  / pixelsPerRad
    currentHystAngle     = CONFIG.HYSTERESIS  / pixelsPerRad

    -- ── FOV Circle ───────────────────────────────────────────────
    local center = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
    fovCircle.Position = center
    fovCircle.Radius   = CONFIG.FOV_RADIUS
    fovCircle.Visible  = State.enabled and State.showFOV

    -- ── UI ───────────────────────────────────────────────────────
    uiTimer = uiTimer + dt
    if uiDirty or uiTimer >= CONFIG.UI_UPDATE_RATE then
        updateUI()
        uiTimer = 0
    end

    -- ── Targeting + Câmara ───────────────────────────────────────
    if not State.enabled or not State.holding then
        if not State.holding then graceTimer = 0 end
        return
    end

    updateTarget(dt)

    if not lockedTarget or not lockedTarget.Parent then return end

    -- ── Posição de mira suavizada ────────────────────────────────
    -- Recomputa o centróide do braço e lerpa em direção a ele.
    -- Reduz jitter causado pelas animações frame a frame.
    local _, aimBase = getArmTarget(lockedTarget.Parent)
    if not aimBase then return end

    -- Reset do smooth se o alvo mudou (já feito em updateTarget,
    -- mas pode ter sido nil — garante sempre um valor inicial válido)
    if lockedTarget ~= prevLocked or not smoothedAimPos then
        smoothedAimPos = aimBase
        prevLocked     = lockedTarget
    else
        local posAlpha = 1 - (1 - CONFIG.ARM_SMOOTH) ^ (dt * 60)
        smoothedAimPos = smoothedAimPos:Lerp(aimBase, posAlpha)
    end

    -- ── Câmara suave ─────────────────────────────────────────────
    -- Usa a posição suavizada diretamente — sem offset vertical arbitrário,
    -- pois o centróide já aponta para a zona correta do braço.
    local camPos = currentCamCF.Position
    local dir    = (smoothedAimPos - camPos).Unit
    local goal   = CFrame.new(camPos, camPos + dir)

    local alpha = 1 - (1 - CONFIG.SMOOTHNESS) ^ (dt * 60)
    camera.CFrame = camera.CFrame:Lerp(goal, alpha)
end)
