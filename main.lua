--[[
    FOCUS SYSTEM — Versão Alto Impacto
    =====================================

    [MOTION PREDICTION]
      • Calcula a velocidade real do braço frame a frame: (pos - lastPos) / dt
      • Filtra a velocidade com EMA (média móvel exponencial) para eliminar
        picos causados por animações abruptas — PREDICTION_SMOOTH controla
        o quão suave é o filtro
      • Projeta a posição futura: predictedPos = smoothedAimPos + vel × travelTime
        onde travelTime = distância ao alvo / PROJECTILE_SPEED
      • A predição é usada APENAS para a câmara — o targeting (score/lock)
        continua a usar a posição real para não afetar a estabilidade do lock
      • Reset automático ao trocar de alvo ou soltar o botão

    [VELOCITY-BASED SMOOTHNESS]
      • Substitui o alpha fixo por um alpha dinâmico baseado no erro angular
        entre o LookVector atual e a direção do alvo
      • Longe do alvo (erro grande) → alpha alto → câmara responde rápido
      • Perto do alvo (erro pequeno) → alpha baixo → tracking suave e estável
      • Elimina o comportamento inconsistente de antes: demasiado lento
        em aquisições grandes e nervoso em micro-correções
      • SMOOTH_FAR / SMOOTH_CLOSE / SMOOTH_ANGLE_MAX são ajustáveis

    [AIM DRIFT CORRECTION]
      • Quando o erro angular cai abaixo de SNAP_THRESHOLD (≈0.086°),
        a câmara faz snap direto para o alvo em vez de continuar a lerpar
      • Elimina o micro-tremor persistente causado pelo lerp assintótico
        (o lerp nunca chega a 100% — oscila infinitamente perto do alvo)
      • Reutiliza o angularError já calculado para velocity-based smoothness
        sem custo adicional

    [VERSÕES ANTERIORES — mantidas]
      • 3D targeting por ângulo (independente de shift lock)
      • Centróide ponderado do braço esquerdo
      • Posição suavizada anti-jitter (ARM_SMOOTH)
      • Histerese, grace period, switch cooldown
      • RaycastParams reutilizado, cache de invisibilidade
      • UI em intervalo (UI_UPDATE_RATE)
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
    FOV_RADIUS        = 150,    -- Raio do FOV em píxeis (visual + gate de targeting)
    ARM_SMOOTH        = 0.30,   -- Suavidade da posição de mira (lerp anti-jitter)
    TOGGLE_KEY        = Enum.KeyCode.Q,
    UI_KEY            = Enum.KeyCode.J,
    AIM_KEY           = Enum.UserInputType.MouseButton2,

    -- Targeting
    HYSTERESIS        = 40,     -- Vantagem em píxeis dada ao alvo atual (convertida para ângulo)
    GRACE_PERIOD      = 0.25,   -- Segundos antes de largar um alvo que saiu do FOV
    SWITCH_COOLDOWN   = 0.3,    -- Segundos mínimos entre trocas de alvo

    -- Motion Prediction
    --   PROJECTILE_SPEED: velocidade do projétil do jogo em studs/segundo.
    --   Ajusta este valor por jogo — é o único parâmetro dependente do jogo.
    --   Exemplos: 300 (típico), 500 (rifle rápido), 150 (lançador lento)
    PROJECTILE_SPEED  = 300,
    --   PREDICTION_SMOOTH: suavidade do filtro EMA da velocidade.
    --   0.0 = velocidade raw (reagente mas ruidosa)
    --   0.2 = recomendado — filtra picos de animação sem perder resposta
    --   0.5 = muito suave (lag em alvos com mudanças bruscas de direção)
    PREDICTION_SMOOTH = 0.12,

    -- Velocity-Based Smoothness
    --   SMOOTH_FAR: alpha quando o erro angular é grande (aquisição rápida)
    --   SMOOTH_CLOSE: alpha quando o erro angular é pequeno (tracking suave)
    --   A câmara transiciona continuamente entre os dois conforme se aproxima
    SMOOTH_FAR        = 0.97,   -- usado quando longe do alvo
    SMOOTH_CLOSE      = 0.85,   -- usado quando perto do alvo
    SMOOTH_ANGLE_MAX  = 0.08,   -- rad (≈4.6°) — erro acima disto usa SMOOTH_FAR

    -- Aim Drift Correction
    --   Abaixo deste ângulo (rad), a câmara faz snap direto.
    --   0.0015 rad ≈ 0.086° — imperceptível ao olho, elimina o micro-tremor
    SNAP_THRESHOLD    = 0.0015,

    -- UI
    UI_UPDATE_RATE    = 0.15,   -- Intervalo de atualização da UI (segundos)
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
local lockedTarget   = nil
local graceTimer     = 0
local lastSwitchTime = 0

-- Posição de mira suavizada
local smoothedAimPos = nil
local prevLocked     = nil

-- Motion Prediction
local lastAimPos       = nil          -- posição anterior do braço (base de velocidade)
local smoothedVelocity = Vector3.zero -- velocidade filtrada com EMA

-- Cache por frame
local currentCamCF     = CFrame.new()
local currentMaxAngle  = 0
local currentHystAngle = 0

-- UI
local uiDirty = true
local uiTimer = 0

--------------------------------------------------
--// RAYCAST PARAMS
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
--// RESET — limpa todo o estado de mira
-- Chamado ao soltar o botão e ao trocar de alvo
--------------------------------------------------
local function resetAimState()
    smoothedAimPos   = nil
    prevLocked       = nil
    lastAimPos       = nil
    smoothedVelocity = Vector3.zero
end

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
        State.holding = false
        lockedTarget  = nil
        graceTimer    = 0
        resetAimState()
    end
end)

--------------------------------------------------
--// TARGETING — Funções auxiliares
--------------------------------------------------
local invisCache = {}

--[[
    Retorna (primaryPart, aimPos):
      primaryPart — Part usado para lock e LOS
      aimPos      — Vector3 centróide ponderado do braço (câmara + predição)

    Pesos R15:  LeftHand × 2  |  LeftLowerArm × 1  |  LeftUpperArm × 0.5
    R6 usa Left Arm diretamente sem centróide.
--]]
local function getArmTarget(char)
    local r6Arm = char:FindFirstChild("Left Arm")
    if r6Arm then
        return r6Arm, r6Arm.Position
    end

    local hand  = char:FindFirstChild("LeftHand")
    local lower = char:FindFirstChild("LeftLowerArm")
    local upper = char:FindFirstChild("LeftUpperArm")

    local primary = hand or lower or upper
    if not primary then return nil, nil end

    local wSum, wTotal = Vector3.zero, 0
    local weights = { [hand] = 2, [lower] = 1, [upper] = 0.5 }
    for part, w in pairs(weights) do
        if part then
            wSum   = wSum   + part.Position * w
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
        char.DescendantAdded:Connect(function()    invisCache[char] = nil end)
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
local function scoreCandidate(aimPos)
    local toArm   = aimPos - currentCamCF.Position
    local forward = toArm:Dot(currentCamCF.LookVector)

    if forward <= 0 then return nil end

    local cosAngle = forward / toArm.Magnitude
    local angle    = math.acos(math.clamp(cosAngle, -1, 1))

    if angle > currentMaxAngle then return nil end

    return angle
end

local function findBestTarget()
    local best      = nil
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

        if arm ~= lockedTarget then
            if now - lastSwitchTime < CONFIG.SWITCH_COOLDOWN then
                score = score + currentHystAngle
            else
                score = score + currentHystAngle * 0.5
            end
        end

        if score < bestScore then
            bestScore = score
            best      = arm
        end
    end

    return best
end

local function updateTarget(dt)
    local now = tick()

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
            graceTimer = graceTimer + dt
            if graceTimer < CONFIG.GRACE_PERIOD then
                return
            end
        end
        local best = findBestTarget()
        if best ~= lockedTarget then
            lastSwitchTime = now
            resetAimState()  -- Limpa predição ao trocar de alvo
        end
        lockedTarget = best
        graceTimer   = 0
    end
end

--------------------------------------------------
--// UI
--------------------------------------------------
local function updateUI()
    toggleBtn.Text = State.enabled        and "Focus: ON"           or "Focus: OFF"
    teamBtn.Text   = State.teamCheck      and "Team Check: ON"      or "Team Check: OFF"
    wallBtn.Text   = State.wallCheck      and "Wall Check: ON"      or "Wall Check: OFF"
    fovBtn.Text    = State.showFOV        and "FOV: ON"             or "FOV: OFF"
    invisBtn.Text  = State.invisibleCheck and "Invisible Check: ON" or "Invisible Check: OFF"
    fill.Size      = UDim2.new((CONFIG.FOV_RADIUS - 1) / 399, 0, 1, 0)
    uiDirty        = false
end

--------------------------------------------------
--// LOOP PRINCIPAL
--------------------------------------------------
RunService.RenderStepped:Connect(function(dt)

    -- ── Cache por frame ──────────────────────────────────────────
    currentCamCF = camera.CFrame
    local halfVFOV     = math.rad(camera.FieldOfView / 2)
    local pixelsPerRad = camera.ViewportSize.Y / (2 * math.tan(halfVFOV))
    currentMaxAngle    = CONFIG.FOV_RADIUS / pixelsPerRad
    currentHystAngle   = CONFIG.HYSTERESIS / pixelsPerRad

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

    -- ── Centróide do braço ───────────────────────────────────────
    local _, aimBase = getArmTarget(lockedTarget.Parent)
    if not aimBase then return end

    -- ── Posição suavizada (anti-jitter de animações) ─────────────
    if lockedTarget ~= prevLocked or not smoothedAimPos then
        -- Primeiro frame do lock ou troca de alvo: inicializa sem lerp
        smoothedAimPos   = aimBase
        lastAimPos       = aimBase
        smoothedVelocity = Vector3.zero
        prevLocked       = lockedTarget
    else
        local posAlpha = 1 - (1 - CONFIG.ARM_SMOOTH) ^ (dt * 60)
        smoothedAimPos = smoothedAimPos:Lerp(aimBase, posAlpha)
    end

    -- ── [1] MOTION PREDICTION ────────────────────────────────────
    --[[
        Calcula a velocidade do braço a partir da diferença entre a posição
        atual e a anterior, dividida pelo tempo. Usa EMA para suavizar picos
        causados por animações — PREDICTION_SMOOTH controla a suavidade.

        travelTime = distância da câmara ao alvo / velocidade do projétil
        predictedPos = posição suavizada + velocidade filtrada × travelTime

        Nota: usamos smoothedAimPos (não aimBase) como base da predição
        para que o filtro de jitter já esteja aplicado antes de prever.
    --]]
    local rawVel = (aimBase - lastAimPos) / math.max(dt, 0.001)
    local velAlpha = 1 - (1 - CONFIG.PREDICTION_SMOOTH) ^ (dt * 60)
    smoothedVelocity = smoothedVelocity:Lerp(rawVel, velAlpha)
    lastAimPos = aimBase

    local camPos     = currentCamCF.Position
    local dist3D     = (smoothedAimPos - camPos).Magnitude
    local travelTime = dist3D / CONFIG.PROJECTILE_SPEED
    local predictedPos = smoothedAimPos + smoothedVelocity * travelTime

    -- ── Goal da câmara ───────────────────────────────────────────
    local goalDir = (predictedPos - camPos).Unit

    -- ── Erro angular (partilhado entre [2] e [3]) ────────────────
    --[[
        Ângulo entre o LookVector atual da câmara e a direção do alvo.
        Calculado uma vez e reutilizado pelas duas mecânicas seguintes.
    --]]
    local angularError = math.acos(
        math.clamp(currentCamCF.LookVector:Dot(goalDir), -1, 1)
    )

    -- ── [3] AIM DRIFT CORRECTION ─────────────────────────────────
    --[[
        Se o erro angular for menor que SNAP_THRESHOLD (≈0.086°),
        a câmara snapa diretamente para o alvo sem lerp.
        Elimina o micro-tremor causado pelo lerp assintótico quando
        o alvo está quase perfeitamente centrado.
    --]]
    if angularError < CONFIG.SNAP_THRESHOLD then
        camera.CFrame = CFrame.new(camPos, camPos + goalDir)
        return
    end

    -- ── [2] VELOCITY-BASED SMOOTHNESS ────────────────────────────
    --[[
        Alpha dinâmico: transiciona entre SMOOTH_CLOSE (perto) e
        SMOOTH_FAR (longe) com base no erro angular.

        t = 0 → erro pequeno → usa SMOOTH_CLOSE → tracking suave
        t = 1 → erro grande → usa SMOOTH_FAR  → aquisição rápida

        A câmara deixa de ter o comportamento inconsistente de antes
        (demasiado lento em trocas, nervosa em micro-correções).
    --]]
    local t = math.clamp(angularError / CONFIG.SMOOTH_ANGLE_MAX, 0, 1)
    local dynSmooth = CONFIG.SMOOTH_CLOSE + (CONFIG.SMOOTH_FAR - CONFIG.SMOOTH_CLOSE) * t
    local alpha     = 1 - (1 - dynSmooth) ^ (dt * 60)

    camera.CFrame = camera.CFrame:Lerp(CFrame.new(camPos, camPos + goalDir), alpha)
end)
