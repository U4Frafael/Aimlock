--// SERVICES
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// PLAYER
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

--// SETTINGS
local FOV_RADIUS = 150
local SMOOTHNESS = 0.95
local TOGGLE_KEY = Enum.KeyCode.Q
local UI_KEY = Enum.KeyCode.J
local AIM_KEY = Enum.UserInputType.MouseButton2

--// STATES
local enabled = false
local holding = false
local uiVisible = true
local teamCheck = true
local wallCheck = true
local showFOV = true
local invisibleCheck = true
local lockedTarget = nil

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
stroke.Color = Color3.fromRGB(70,70,70)
stroke.Thickness = 1
stroke.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 40)
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,28)
title.BackgroundTransparency = 1
title.Text = "FOCUS SYSTEM"
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(255,255,255)
title.Parent = frame

--------------------------------------------------
--// BUTTONS
--------------------------------------------------
local function createButton(text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 34)
	b.BackgroundColor3 = Color3.fromRGB(35,35,40)
	b.TextColor3 = Color3.fromRGB(255,255,255)
	b.Text = text
	b.Font = Enum.Font.Gotham
	b.TextSize = 12
	b.BorderSizePixel = 0
	b.Parent = frame
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)

	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(90,90,90)
	s.Thickness = 1
	s.Transparency = 0.25
	s.Parent = b

	b.MouseEnter:Connect(function()
		b.BackgroundColor3 = Color3.fromRGB(45,45,55)
		s.Transparency = 0
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundColor3 = Color3.fromRGB(35,35,40)
		s.Transparency = 0.25
	end)
	return b
end

local toggleBtn  = createButton("Focus: OFF")
local teamBtn    = createButton("Team Check: ON")
local wallBtn    = createButton("Wall Check: ON")
local fovBtn     = createButton("FOV: ON")
local invisBtn   = createButton("Invisible Check: ON")

--------------------------------------------------
--// FOV SLIDER
--------------------------------------------------
local fovContainer = Instance.new("Frame")
fovContainer.Size = UDim2.new(1, 0, 0, 28)
fovContainer.BackgroundColor3 = Color3.fromRGB(30,30,35)
fovContainer.BorderSizePixel = 0
fovContainer.Parent = frame
Instance.new("UICorner", fovContainer).CornerRadius = UDim.new(0, 6)

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, -10, 0, 6)
bar.Position = UDim2.new(0, 5, 0.5, -3)
bar.BackgroundColor3 = Color3.fromRGB(50,50,55)
bar.BorderSizePixel = 0
bar.Parent = fovContainer
Instance.new("UICorner", bar).CornerRadius = UDim.new(1,0)

local fill = Instance.new("Frame")
fill.BackgroundColor3 = Color3.fromRGB(255,80,80)
fill.BorderSizePixel = 0
fill.Parent = bar
Instance.new("UICorner", fill).CornerRadius = UDim.new(1,0)

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
	local x = input.Position.X
	local start = fovContainer.AbsolutePosition.X
	local size = fovContainer.AbsoluteSize.X
	local percent = math.clamp((x - start) / size, 0, 1)
	FOV_RADIUS = math.floor(1 + (399 * percent))
end)

--------------------------------------------------
--// INPUT
--------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == TOGGLE_KEY then
		enabled = not enabled
	end
	if input.KeyCode == UI_KEY then
		uiVisible = not uiVisible
		frame.Visible = uiVisible
	end
	if input.UserInputType == AIM_KEY then
		holding = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == AIM_KEY then
		holding = false
		lockedTarget = nil
	end
end)

--------------------------------------------------
--// FOV VISUAL
--------------------------------------------------
local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 2
fovCircle.Color = Color3.fromRGB(255,80,80)
fovCircle.Transparency = 0.6
fovCircle.Visible = false

--------------------------------------------------
--// TARGET SYSTEM
--------------------------------------------------
local function getLeftArm(char)
	return char:FindFirstChild("LeftHand")
		or char:FindFirstChild("LeftLowerArm")
		or char:FindFirstChild("LeftUpperArm")
		or char:FindFirstChild("Left Arm")
end

local function isInvisible(char)
	for _, part in pairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			if part.Transparency < 0.8 then return false end
		end
	end
	return true
end

local function isValid(plr)
	if plr == player then return false end
	local char = plr.Character
	if not char then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end
	if invisibleCheck and isInvisible(char) then return false end
	if not teamCheck then return true end
	if player.Team and plr.Team then
		return player.Team ~= plr.Team
	end
	return true
end

local function hasLineOfSight(part)
	if not wallCheck then return true end
	local origin = camera.CFrame.Position
	local dir = (part.Position - origin)
	local params = RaycastParams.new()

	-- Filtra todos os personagens para que jogadores
	-- a passar à frente não quebrem o lock
	local filtered = {}
	for _, plr in pairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(filtered, plr.Character)
		end
	end

	params.FilterDescendantsInstances = filtered
	params.FilterType = Enum.RaycastFilterType.Blacklist

	local result = Workspace:Raycast(origin, dir, params)
	if result then
		return result.Instance:IsDescendantOf(part.Parent)
	end
	return true
end

-- Verifica se o alvo atual ainda é válido e está no FOV
local function isTargetStillValid(target)
	if not target or not target.Parent then return false end
	local char = target.Parent
	local plr = Players:GetPlayerFromCharacter(char)
	if not plr or not isValid(plr) then return false end
	if wallCheck and not hasLineOfSight(target) then return false end
	local pos, vis = camera:WorldToViewportPoint(target.Position)
	if not vis then return false end
	local dist = (Vector2.new(pos.X, pos.Y) - fovCircle.Position).Magnitude
	return dist <= FOV_RADIUS
end

-- Só procura novo alvo se o atual for inválido
local function getClosestTarget()
	-- Mantém o alvo bloqueado se ainda for válido
	if lockedTarget and isTargetStillValid(lockedTarget) then
		return lockedTarget
	end

	-- Procura novo alvo
	local closest = nil
	local bestScore = math.huge
	for _, plr in pairs(Players:GetPlayers()) do
		if plr.Character and isValid(plr) then
			local char = plr.Character
			local arm = getLeftArm(char)
			if arm and (not wallCheck or hasLineOfSight(arm)) then
				local pos, vis = camera:WorldToViewportPoint(arm.Position)
				if vis then
					local dist = (Vector2.new(pos.X, pos.Y) - fovCircle.Position).Magnitude
					if dist <= FOV_RADIUS then
						local score = dist
						if invisibleCheck and isInvisible(char) then score = score + 500 end
						if score < bestScore then
							bestScore = score
							closest = arm
						end
					end
				end
			end
		end
	end

	lockedTarget = closest
	return lockedTarget
end

--------------------------------------------------
--// BUTTON EVENTS
--------------------------------------------------
toggleBtn.MouseButton1Click:Connect(function()
	enabled = not enabled
end)
teamBtn.MouseButton1Click:Connect(function()
	teamCheck = not teamCheck
end)
wallBtn.MouseButton1Click:Connect(function()
	wallCheck = not wallCheck
end)
fovBtn.MouseButton1Click:Connect(function()
	showFOV = not showFOV
end)
invisBtn.MouseButton1Click:Connect(function()
	invisibleCheck = not invisibleCheck
end)

--------------------------------------------------
--// LOOP
--------------------------------------------------
RunService.RenderStepped:Connect(function()
	fovCircle.Visible = enabled and showFOV
	fovCircle.Radius = FOV_RADIUS
	fovCircle.Position = Vector2.new(camera.ViewportSize.X/2, camera.ViewportSize.Y/2)

	toggleBtn.Text  = enabled          and "Focus: ON"           or "Focus: OFF"
	teamBtn.Text    = teamCheck        and "Team Check: ON"       or "Team Check: OFF"
	wallBtn.Text    = wallCheck        and "Wall Check: ON"       or "Wall Check: OFF"
	fovBtn.Text     = showFOV          and "FOV: ON"              or "FOV: OFF"
	invisBtn.Text   = invisibleCheck   and "Invisible Check: ON"  or "Invisible Check: OFF"

	fill.Size = UDim2.new((FOV_RADIUS - 1) / 399, 0, 1, 0)

	if not enabled or not holding then return end

	local target = getClosestTarget()
	if not target then return end

	local camPos = camera.CFrame.Position
	local targetPos = target.Position + Vector3.new(0, 0.15, 0)
	local dir = (targetPos - camPos).Unit
	local goal = CFrame.new(camPos, camPos + dir)
	camera.CFrame = camera.CFrame:Lerp(goal, SMOOTHNESS)
end)
