-- Matt's OOC: Out of Combat Spell Reminder

local ADDON_NAME = "MattOOC"

-- State tracking
local inCombat = false
local keystoneActive = false
local ConfigFrame = nil
local MythicPlusNotificationFrame = nil
local spellRows = {}
local spellFrames = {} 
local isUnlocked = false

-- Initialize saved variables
local function InitDB()
    MattOOCDB = MattOOCDB or {}
    MattOOCDB.trackedSpells = MattOOCDB.trackedSpells or {}
    MattOOCDB.minimap = MattOOCDB.minimap or { hide = false }
    if MattOOCDB.hideMPlusBuffWarning == nil then
        MattOOCDB.hideMPlusBuffWarning = false
    end
    
    -- Migrate old entries
    local yOffset = 0
    for spellID, data in pairs(MattOOCDB.trackedSpells) do
        if data.customMessage == nil then data.customMessage = "" end
        if data.showWhenResting == nil then data.showWhenResting = false end
        if data.showIcon == nil then data.showIcon = false end
        -- Migrate flashText to effect
        if data.effect == nil then
            if data.flashText then
                data.effect = "flash"
            else
                data.effect = "none"
            end
            data.flashText = nil
        end
        if data.textColor == nil then data.textColor = "red" end
        if data.scale == nil then data.scale = 1.0 end
        if data.pos == nil then 
            data.pos = { point = "CENTER", x = 0, y = 150 - yOffset }
            yOffset = yOffset + 50
        end
    end
end

-- Color definitions
local TEXT_COLORS = {
    { value = "red", text = "Red", r = 1, g = 0.2, b = 0.2 },
    { value = "orange", text = "Orange", r = 1, g = 0.5, b = 0 },
    { value = "yellow", text = "Yellow", r = 1, g = 1, b = 0 },
    { value = "green", text = "Green", r = 0.2, g = 1, b = 0.2 },
    { value = "cyan", text = "Cyan", r = 0, g = 1, b = 1 },
    { value = "blue", text = "Blue", r = 0.3, g = 0.5, b = 1 },
    { value = "purple", text = "Purple", r = 0.8, g = 0.3, b = 1 },
    { value = "pink", text = "Pink", r = 1, g = 0.4, b = 0.7 },
    { value = "white", text = "White", r = 1, g = 1, b = 1 },
}

local function GetColorRGB(colorName)
    for _, c in ipairs(TEXT_COLORS) do
        if c.value == colorName then
            return c.r, c.g, c.b
        end
    end
    return 1, 0.2, 0.2 -- default red
end

-- Default colors for known spells (by spell ID and name patterns)
local SPELL_DEFAULT_COLORS = {
    -- Mage
    [31687] = "green",      -- Summon Water Elemental
    [1459] = "blue",        -- Arcane Intellect
    [80353] = "blue",       -- Time Warp
    
    -- Priest
    [21562] = "white",      -- Power Word: Fortitude
    
    -- Paladin
    [465] = "yellow",       -- Devotion Aura
    [32223] = "yellow",     -- Crusader Aura
    [183435] = "yellow",    -- Retribution Aura
    
    -- Warlock
    [688] = "purple",       -- Summon Imp
    [697] = "purple",       -- Summon Voidwalker
    [712] = "purple",       -- Summon Succubus
    [691] = "purple",       -- Summon Felhunter
    [30146] = "purple",     -- Summon Felguard
    
    -- Hunter
    [883] = "green",        -- Call Pet 1
    [83242] = "green",      -- Call Pet 2
    
    -- Shaman
    [2825] = "orange",      -- Bloodlust
    [32182] = "cyan",       -- Heroism
    
    -- Death Knight
    [57330] = "cyan",       -- Horn of Winter
    [46585] = "purple",     -- Raise Dead
    
    -- Evoker
    [395152] = "cyan",      -- Ebon Might
    [360827] = "green",     -- Blistering Scales
    [374227] = "orange",    -- Zephyr
}

-- Pattern-based default colors (for spell names)
local SPELL_NAME_PATTERNS = {
    ["Water Elemental"] = "green",
    ["Arcane Intellect"] = "blue",
    ["Fortitude"] = "white",
    ["Blessing"] = "yellow",
    ["Aura"] = "yellow",
    ["Bloodlust"] = "orange",
    ["Heroism"] = "cyan",
    ["Time Warp"] = "blue",
    ["Summon"] = "purple",
    ["Call Pet"] = "green",
}

local function GetDefaultColorForSpell(spellID, spellName)
    -- Check by spell ID first
    if SPELL_DEFAULT_COLORS[spellID] then
        return SPELL_DEFAULT_COLORS[spellID]
    end
    
    -- Check by name patterns
    if spellName then
        for pattern, color in pairs(SPELL_NAME_PATTERNS) do
            if spellName:find(pattern) then
                return color
            end
        end
    end
    
    return "red" -- default fallback
end

-- Get spell name from ID
local function GetSpellNameByID(spellID)
    local info = C_Spell.GetSpellInfo(spellID)
    if info and info.name then
        return info.name
    end
    return "Spell " .. spellID
end

-- Get spell ID from name
local function GetSpellIDByName(spellName)
    local info = C_Spell.GetSpellInfo(spellName)
    if info and info.spellID then
        return info.spellID, info.name
    end
    return nil, nil
end

-- Check if player has a specific spell
local function HasSpell(spellID)
    local success, result = pcall(function()
        if IsSpellKnown and IsSpellKnown(spellID) then return true end
        if IsPlayerSpell and IsPlayerSpell(spellID) then return true end
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name then
            local usable = IsUsableSpell(info.name)
            if usable then return true end
        end
        return false
    end)
    return success and result
end

-- Check if pet exists
local function HasPet()
    local success, result = pcall(function()
        return UnitExists("pet") and not UnitIsDead("pet")
    end)
    return success and result
end

-- Check if a specific spell is missing
local function IsSpellMissing(spellID, data, checkRestingOverride)
    -- Never check auras during combat to avoid protected function errors
    if InCombatLockdown() then return false end
    
    if not data.enabled then return false end
    
    local isResting = IsResting()
    if isResting and not data.showWhenResting and not checkRestingOverride then
        return false
    end
    
    if not HasSpell(spellID) then return false end
    
    if data.isPet then
        return not HasPet()
    else
        local hasBuff = false
        
        -- METHOD 1: Primary method - GetPlayerAuraBySpellID (most reliable in instances)
        local success, auraData = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
        if success and auraData then
            hasBuff = true
        end
        
        -- METHOD 2: Backup - Use AuraUtil.ForEachAura for broader compatibility
        if not hasBuff and AuraUtil and AuraUtil.ForEachAura then
            local function checkAura(auraData)
                -- Check by spell ID first (most accurate)
                if auraData.spellId and auraData.spellId == spellID then
                    hasBuff = true
                    return true -- stop iteration
                end
                -- Check by name as fallback (case-insensitive)
                if auraData.name and data.name then
                    local auraName = auraData.name:lower()
                    local dataName = data.name:lower()
                    if auraName == dataName or auraName:find(dataName, 1, true) or dataName:find(auraName, 1, true) then
                        hasBuff = true
                        return true -- stop iteration
                    end
                end
                return false
            end
            
            -- Use pcall to handle any API errors in instances
            pcall(function()
                AuraUtil.ForEachAura("player", "HELPFUL", nil, checkAura, true)
            end)
        end
        
        -- METHOD 3: Final fallback - GetAuraDataBySpellName
        if not hasBuff and data.name and data.name ~= "" then
            local success2, auraData2 = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", data.name, "HELPFUL")
            if success2 and auraData2 then
                hasBuff = true
            end
        end
        
        return not hasBuff
    end
end

-- Create individual frame for a spell
local function CreateSpellFrame(spellID)
    if spellFrames[spellID] then return spellFrames[spellID] end
    
    local data = MattOOCDB.trackedSpells[spellID]
    if not data then return nil end
    
    local frame = CreateFrame("Frame", "MattOOCFrame_" .. spellID, UIParent)
    frame:SetSize(400, 50)
    frame:SetFrameStrata("HIGH")
    frame:Hide()
    
    -- Load saved position
    local pos = data.pos or { point = "CENTER", x = 0, y = 150 }
    frame:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
    
    -- Background (invisible by default, green when unlocked)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0)
    frame.bg = bg
    
    -- Icon
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("LEFT", frame, "LEFT", 5, 0)
    icon:Hide()
    frame.icon = icon
    
    -- Text
    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
    text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    text:SetTextColor(1, 0.2, 0.2, 1)
    text:SetShadowOffset(2, -2)
    text:SetShadowColor(0, 0, 0, 1)
    frame.text = text
    
    -- Pulse/Flash animation
    local pulseAG = frame:CreateAnimationGroup()
    local fadeOut = pulseAG:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0.4)
    fadeOut:SetDuration(0.6)
    fadeOut:SetOrder(1)
    local fadeIn = pulseAG:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.4)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.6)
    fadeIn:SetOrder(2)
    pulseAG:SetLooping("REPEAT")
    frame.pulseAnim = pulseAG
    
    -- Bounce animation
    local bounceAG = frame:CreateAnimationGroup()
    local bounceUp = bounceAG:CreateAnimation("Translation")
    bounceUp:SetOffset(0, 10)
    bounceUp:SetDuration(0.3)
    bounceUp:SetOrder(1)
    bounceUp:SetSmoothing("OUT")
    local bounceDown = bounceAG:CreateAnimation("Translation")
    bounceDown:SetOffset(0, -10)
    bounceDown:SetDuration(0.3)
    bounceDown:SetOrder(2)
    bounceDown:SetSmoothing("IN")
    bounceAG:SetLooping("REPEAT")
    frame.bounceAnim = bounceAG
    
    -- Glow animation (scale pulse)
    local glowAG = frame:CreateAnimationGroup()
    local scaleUp = glowAG:CreateAnimation("Scale")
    scaleUp:SetScaleFrom(1, 1)
    scaleUp:SetScaleTo(1.1, 1.1)
    scaleUp:SetDuration(0.5)
    scaleUp:SetOrder(1)
    scaleUp:SetSmoothing("IN_OUT")
    local scaleDown = glowAG:CreateAnimation("Scale")
    scaleDown:SetScaleFrom(1.1, 1.1)
    scaleDown:SetScaleTo(1, 1)
    scaleDown:SetDuration(0.5)
    scaleDown:SetOrder(2)
    scaleDown:SetSmoothing("IN_OUT")
    glowAG:SetLooping("REPEAT")
    frame.glowAnim = glowAG
    
    -- Shake animation
    local shakeAG = frame:CreateAnimationGroup()
    local shakeL = shakeAG:CreateAnimation("Translation")
    shakeL:SetOffset(-3, 0)
    shakeL:SetDuration(0.05)
    shakeL:SetOrder(1)
    local shakeR = shakeAG:CreateAnimation("Translation")
    shakeR:SetOffset(6, 0)
    shakeR:SetDuration(0.05)
    shakeR:SetOrder(2)
    local shakeBack = shakeAG:CreateAnimation("Translation")
    shakeBack:SetOffset(-3, 0)
    shakeBack:SetDuration(0.05)
    shakeBack:SetOrder(3)
    shakeAG:SetLooping("REPEAT")
    frame.shakeAnim = shakeAG
    
    frame:SetScript("OnShow", function(self)
        local spellData = MattOOCDB.trackedSpells[spellID]
        if not isUnlocked and spellData then
            self:StopAllAnimations()
            if spellData.effect == "flash" and self.pulseAnim then
                self.pulseAnim:Play()
            elseif spellData.effect == "bounce" and self.bounceAnim then
                self.bounceAnim:Play()
            elseif spellData.effect == "glow" and self.glowAnim then
                self.glowAnim:Play()
            elseif spellData.effect == "shake" and self.shakeAnim then
                self.shakeAnim:Play()
            end
        end
    end)
    
    frame.StopAllAnimations = function(self)
        if self.pulseAnim then self.pulseAnim:Stop() end
        if self.bounceAnim then self.bounceAnim:Stop() end
        if self.glowAnim then self.glowAnim:Stop() end
        if self.shakeAnim then self.shakeAnim:Stop() end
        self:SetAlpha(1)
    end
    
    frame:SetScript("OnHide", function(self)
        self:StopAllAnimations()
    end)
    
    -- Drag functionality
    frame:SetScript("OnDragStart", function(self)
        if isUnlocked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        if MattOOCDB.trackedSpells[spellID] then
            MattOOCDB.trackedSpells[spellID].pos = { point = point, x = x, y = y }
        end
    end)
    
    frame.spellID = spellID
    spellFrames[spellID] = frame
    return frame
end

-- Update a single spell frame
local function UpdateSpellFrame(spellID)
    local data = MattOOCDB.trackedSpells[spellID]
    if not data then
        if spellFrames[spellID] then
            spellFrames[spellID]:Hide()
        end
        return
    end
    
    local frame = CreateSpellFrame(spellID)
    if not frame then return end
    
    -- Don't update while unlocked
    if isUnlocked then return end
    
    -- Hide during active mythic+ keystone
    if keystoneActive then
        frame:Hide()
        return
    end
    
    -- Hide in combat
    if inCombat then
        frame:Hide()
        return
    end
    
    local inInstance, instanceType = IsInInstance()
    local inValidInstance = inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario")
    
    -- Use Blizzard's official API to detect Mythic+ dungeons
    local isMythicPlus = false
    -- ONLY check for M+ in party dungeons, NEVER in raids
    if inInstance and instanceType == "party" then
        -- Primary check: GetActiveChallengeMapID returns mapID if in active M+, nil otherwise
        if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
            local activeChallengeMapID = C_ChallengeMode.GetActiveChallengeMapID()
            isMythicPlus = (activeChallengeMapID ~= nil)
        else
            -- Fallback: Check keystone info
            if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
                local activeKeystoneLevel = C_ChallengeMode.GetActiveKeystoneInfo()
                isMythicPlus = (activeKeystoneLevel and activeKeystoneLevel > 0)
            else
                -- Final fallback for older clients
                local _, _, difficulty = GetInstanceInfo()
                isMythicPlus = (difficulty == 8 or difficulty == 23) -- Mythic/Mythic+
            end
        end
    end
    -- Explicit safety check: NEVER consider raids as M+
    if instanceType == "raid" then
        isMythicPlus = false
    end
    
    if IsSpellMissing(spellID, data, inValidInstance or isMythicPlus) then
        local scale = data.scale or 1.0
        local fontSize = math.floor(28 * scale)
        local iconSize = math.floor(32 * scale)
        
        frame.text:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
        frame.icon:SetSize(iconSize, iconSize)
        
        -- Apply text color
        local r, g, b = GetColorRGB(data.textColor or "red")
        frame.text:SetTextColor(r, g, b, 1)
        
        local displayText = (data.customMessage ~= "") and data.customMessage or ("Missing: " .. data.name)
        frame.text:SetText(displayText)
        
        if data.showIcon then
            local spellInfo = C_Spell.GetSpellInfo(spellID)
            if spellInfo and spellInfo.iconID then
                frame.icon:SetTexture(spellInfo.iconID)
            end
            frame.icon:Show()
            frame.text:SetPoint("LEFT", frame.icon, "RIGHT", 8, 0)
        else
            frame.icon:Hide()
            frame.text:SetPoint("LEFT", frame, "LEFT", 5, 0)
        end
        
        -- Resize frame to fit content
        local textWidth = frame.text:GetStringWidth() or 200
        local totalWidth = textWidth + 20
        if data.showIcon then
            totalWidth = totalWidth + iconSize + 8
        end
        frame:SetSize(totalWidth, fontSize + 20)
        frame:Show()
        
        -- Handle animation based on effect setting
        frame:StopAllAnimations()
        local effect = data.effect or "none"
        if effect == "flash" and frame.pulseAnim then
            frame.pulseAnim:Play()
        elseif effect == "bounce" and frame.bounceAnim then
            frame.bounceAnim:Play()
        elseif effect == "glow" and frame.glowAnim then
            frame.glowAnim:Play()
        elseif effect == "shake" and frame.shakeAnim then
            frame.shakeAnim:Play()
        end
    else
        frame:Hide()
    end
end

-- Update M+ notification visibility
local function UpdateMythicPlusNotification()
    local inInstance, instanceType = IsInInstance()
    local frame = CreateMythicPlusNotificationFrame()
    
    -- Only show in dungeons (party instances)
    if inInstance and instanceType == "party" and not keystoneActive then
        frame:Show()
    else
        frame:Hide()
    end
end

-- Create M+ notification frame
local function CreateMythicPlusNotificationFrame()
    if MythicPlusNotificationFrame then return MythicPlusNotificationFrame end
    
    local frame = CreateFrame("Frame", "MattOOCMythicPlusNotification", UIParent, "BackdropTemplate")
    frame:SetSize(500, 70)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -80)
    frame:SetFrameStrata("HIGH")
    frame:Hide()
    
    -- Professional backdrop
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
    frame:SetBackdropBorderColor(0.3, 0.4, 0.6, 1)
    
    -- Icon
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -12)
    icon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    icon:SetVertexColor(0.4, 0.6, 1, 1)
    
    -- Text
    local text = frame:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    text:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 0)
    text:SetPoint("RIGHT", frame, "RIGHT", -35, 0)
    text:SetTextColor(0.9, 0.9, 1, 1)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    text:SetNonSpaceWrap(false)
    text:SetText("Matt's OOC: Buff tracking will be disabled when M+ keystone starts due to WoW API limitations.")
    
    -- "Never show this again" checkbox
    local check = CreateFrame("CheckButton", nil, frame, "ChatConfigCheckButtonTemplate")
    check:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 8)
    check:SetHitRectInsets(0, -100, 0, 0)
    local label = check.text or check:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if not check.text then
        label:SetPoint("LEFT", check, "RIGHT", 4, 0)
        check.text = label
    end
    label:SetText("Never show this again")
    label:SetTextColor(0.85, 0.85, 0.9, 1)
    frame.neverShowAgainCheck = check
    check:SetScript("OnClick", function(self)
        if self:GetChecked() then
            StaticPopupDialogs["MATTOOC_HIDE_MPLUS_WARNING"] = {
                text = "Hide this M+ notification for this character? You will not see it again when entering Mythic+ dungeons. You can turn it back on later from addon settings if you change your mind.",
                button1 = "Yes, hide it",
                button2 = "Cancel",
                OnAccept = function()
                    MattOOCDB.hideMPlusBuffWarning = true
                    frame:Hide()
                end,
                OnCancel = function()
                    self:SetChecked(false)
                    MattOOCDB.hideMPlusBuffWarning = false
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            StaticPopup_Show("MATTOOC_HIDE_MPLUS_WARNING")
        else
            MattOOCDB.hideMPlusBuffWarning = false
        end
    end)
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -12)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
    closeBtn:GetHighlightTexture():SetAlpha(0.4)
    closeBtn:SetScript("OnClick", function()
        frame:Hide()
    end)
    closeBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Dismiss notification", 1, 1, 1)
        GameTooltip:Show()
    end)
    closeBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    MythicPlusNotificationFrame = frame
    return frame
end

-- Update M+ notification visibility (call after changing hideMPlusBuffWarning to apply on the fly)
local function UpdateMythicPlusNotification()
    if MattOOCDB.hideMPlusBuffWarning then
        if MythicPlusNotificationFrame then
            MythicPlusNotificationFrame:Hide()
        end
        return
    end
    local inInstance, instanceType = IsInInstance()
    local frame = CreateMythicPlusNotificationFrame()
    if frame.neverShowAgainCheck then
        frame.neverShowAgainCheck:SetChecked(false)
    end
    -- Only show in Mythic/Mythic+ dungeons
    if inInstance and instanceType == "party" then
        local _, _, difficulty = GetInstanceInfo()
        -- Difficulty 8 = Mythic, 23 = Mythic+
        if (difficulty == 8 or difficulty == 23) and not keystoneActive then
            frame:Show()
        else
            frame:Hide()
        end
    else
        frame:Hide()
    end
end

-- Update all spell frames
local function UpdateWarningDisplay()
    -- Double-check we're not in combat before updating
    if InCombatLockdown() then return end
    
    for spellID, _ in pairs(MattOOCDB.trackedSpells) do
        UpdateSpellFrame(spellID)
    end
end

-- Toggle unlock state for ALL frames
local function ToggleUnlock()
    isUnlocked = not isUnlocked
    
    for spellID, data in pairs(MattOOCDB.trackedSpells) do
        local frame = CreateSpellFrame(spellID)
        if frame then
            if isUnlocked then
                frame.bg:SetColorTexture(0, 0.5, 0, 0.4)
                frame:EnableMouse(true)
                frame:SetMovable(true)
                frame:RegisterForDrag("LeftButton")
                
                -- Show frame with sample text for positioning
                local scale = data.scale or 1.0
                local fontSize = math.floor(28 * scale)
                local iconSize = math.floor(32 * scale)
                
                frame.text:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
                frame.icon:SetSize(iconSize, iconSize)
                
                -- Apply text color
                local r, g, b = GetColorRGB(data.textColor or "red")
                frame.text:SetTextColor(r, g, b, 1)
                
                local displayText = (data.customMessage ~= "") and data.customMessage or ("Missing: " .. data.name)
                frame.text:SetText(displayText)
                
                if data.showIcon then
                    local spellInfo = C_Spell.GetSpellInfo(spellID)
                    if spellInfo and spellInfo.iconID then
                        frame.icon:SetTexture(spellInfo.iconID)
                    end
                    frame.icon:Show()
                    frame.text:SetPoint("LEFT", frame.icon, "RIGHT", 8, 0)
                else
                    frame.icon:Hide()
                    frame.text:SetPoint("LEFT", frame, "LEFT", 5, 0)
                end
                
                -- Resize frame to fit content
                local textWidth = frame.text:GetStringWidth() or 200
                local totalWidth = textWidth + 20
                if data.showIcon then
                    totalWidth = totalWidth + iconSize + 8
                end
                frame:SetSize(totalWidth, fontSize + 20)
                
                if frame.pulseAnim then frame.pulseAnim:Stop() end
                frame:SetAlpha(1)
                frame:Show()
            else
                frame.bg:SetColorTexture(0, 0, 0, 0)
                frame:EnableMouse(false)
                frame:SetMovable(false)
                
                -- Save position
                local point, _, _, x, y = frame:GetPoint()
                data.pos = { point = point, x = x, y = y }
            end
        end
    end
    
    if isUnlocked then
        print("|cff00ff00Matt's OOC:|r All frames UNLOCKED - drag each to position")
    else
        print("|cff00ff00Matt's OOC:|r All frames LOCKED - positions saved")
        UpdateWarningDisplay()
    end
end

-- Refresh spell list in config
local function RefreshSpellList()
    if not ConfigFrame then return end
    
    for _, row in ipairs(spellRows) do
        row:Hide()
    end
    wipe(spellRows)
    
    local yOffset = -5
    local scrollChild = ConfigFrame.scrollChild
    
    for spellID, data in pairs(MattOOCDB.trackedSpells) do
        local row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
        row:SetSize(525, 125)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 5, yOffset)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        row:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
        row:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        
        -- Row 1: Enable + Icon + Name + ID + Reset + Delete
        local enableCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        enableCheck:SetSize(24, 24)
        enableCheck:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -8)
        enableCheck:SetChecked(data.enabled)
        enableCheck:SetScript("OnClick", function(self)
            MattOOCDB.trackedSpells[spellID].enabled = self:GetChecked()
            UpdateSpellFrame(spellID)
        end)
        
        -- Spell icon in GUI
        local spellIcon = row:CreateTexture(nil, "ARTWORK")
        spellIcon:SetSize(22, 22)
        spellIcon:SetPoint("LEFT", enableCheck, "RIGHT", 5, 0)
        local spellInfo = C_Spell.GetSpellInfo(spellID)
        if spellInfo and spellInfo.iconID then
            spellIcon:SetTexture(spellInfo.iconID)
        else
            spellIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
        
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT", spellIcon, "RIGHT", 6, 0)
        nameText:SetText(data.name)
        nameText:SetTextColor(1, 0.82, 0)
        
        local idText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        idText:SetPoint("LEFT", nameText, "RIGHT", 8, 0)
        idText:SetText("|cff666666(" .. spellID .. ")|r")
        
        local deleteBtn = CreateFrame("Button", nil, row)
        deleteBtn:SetSize(18, 18)
        deleteBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -8)
        deleteBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
        deleteBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
        deleteBtn:GetHighlightTexture():SetVertexColor(1, 0.3, 0.3)
        deleteBtn:SetScript("OnClick", function()
            StaticPopupDialogs["MATTOOC_DELETE_CONFIRM"] = {
                text = "Delete |cffffd700" .. data.name .. "|r from tracking?",
                button1 = "Yes",
                button2 = "No",
                OnAccept = function()
                    MattOOCDB.trackedSpells[spellID] = nil
                    if spellFrames[spellID] then
                        spellFrames[spellID]:Hide()
                        spellFrames[spellID] = nil
                    end
                    RefreshSpellList()
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            StaticPopup_Show("MATTOOC_DELETE_CONFIRM")
        end)
        
        -- Reset position button
        local resetBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        resetBtn:SetSize(50, 18)
        resetBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -8, 0)
        resetBtn:SetText("Reset")
        resetBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10)
        resetBtn:SetScript("OnClick", function()
            -- Calculate default Y based on spell index
            local idx = 0
            for id, _ in pairs(MattOOCDB.trackedSpells) do
                if id == spellID then break end
                idx = idx + 1
            end
            local defaultPos = { point = "CENTER", x = 0, y = 150 - (idx * 50) }
            MattOOCDB.trackedSpells[spellID].pos = defaultPos
            if spellFrames[spellID] then
                spellFrames[spellID]:ClearAllPoints()
                spellFrames[spellID]:SetPoint(defaultPos.point, UIParent, defaultPos.point, defaultPos.x, defaultPos.y)
            end
            print("|cff00ff00Matt's OOC:|r Reset position for " .. data.name)
        end)
        
        -- Row 2: Checkboxes with spacing
        local row2Y = -35
        
        local petCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        petCheck:SetSize(22, 22)
        petCheck:SetPoint("TOPLEFT", row, "TOPLEFT", 12, row2Y)
        petCheck:SetChecked(data.isPet)
        petCheck:SetScript("OnClick", function(self)
            MattOOCDB.trackedSpells[spellID].isPet = self:GetChecked()
            UpdateSpellFrame(spellID)
        end)
        local petLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        petLabel:SetPoint("LEFT", petCheck, "RIGHT", 2, 0)
        petLabel:SetText("Pet")
        
        local cityCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        cityCheck:SetSize(22, 22)
        cityCheck:SetPoint("LEFT", petLabel, "RIGHT", 20, 0)
        cityCheck:SetChecked(data.showWhenResting)
        cityCheck:SetScript("OnClick", function(self)
            MattOOCDB.trackedSpells[spellID].showWhenResting = self:GetChecked()
            UpdateSpellFrame(spellID)
        end)
        local cityLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cityLabel:SetPoint("LEFT", cityCheck, "RIGHT", 2, 0)
        cityLabel:SetText("Show in Cities")
        
        local iconCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        iconCheck:SetSize(22, 22)
        iconCheck:SetPoint("LEFT", cityLabel, "RIGHT", 20, 0)
        iconCheck:SetChecked(data.showIcon)
        iconCheck:SetScript("OnClick", function(self)
            MattOOCDB.trackedSpells[spellID].showIcon = self:GetChecked()
            UpdateSpellFrame(spellID)
        end)
        local iconLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        iconLabel:SetPoint("LEFT", iconCheck, "RIGHT", 2, 0)
        iconLabel:SetText("Show Icon")
        
        -- Row 3: Dropdowns + Scale
        local row3Y = -62
        
        -- Effect dropdown
        local effectLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        effectLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 12, row3Y)
        effectLabel:SetText("Effect:")
        
        local effectDropdown = CreateFrame("Frame", "MattOOCEffectDropdown" .. spellID, row, "UIDropDownMenuTemplate")
        effectDropdown:SetPoint("LEFT", effectLabel, "RIGHT", -5, -2)
        UIDropDownMenu_SetWidth(effectDropdown, 75)
        
        local effects = {
            { value = "none", text = "None" },
            { value = "flash", text = "Flash" },
            { value = "bounce", text = "Bounce" },
            { value = "glow", text = "Glow" },
            { value = "shake", text = "Shake" },
        }
        
        local currentEffect = data.effect or "none"
        for _, e in ipairs(effects) do
            if e.value == currentEffect then
                UIDropDownMenu_SetText(effectDropdown, e.text)
                break
            end
        end
        
        UIDropDownMenu_Initialize(effectDropdown, function(self, level)
            for _, e in ipairs(effects) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = e.text
                info.value = e.value
                info.checked = (data.effect == e.value)
                info.func = function()
                    MattOOCDB.trackedSpells[spellID].effect = e.value
                    UIDropDownMenu_SetText(effectDropdown, e.text)
                    UpdateSpellFrame(spellID)
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        
        -- Color dropdown
        local colorLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        colorLabel:SetPoint("LEFT", effectDropdown, "RIGHT", 10, 2)
        colorLabel:SetText("Color:")
        
        local colorDropdown = CreateFrame("Frame", "MattOOCColorDropdown" .. spellID, row, "UIDropDownMenuTemplate")
        colorDropdown:SetPoint("LEFT", colorLabel, "RIGHT", -5, -2)
        UIDropDownMenu_SetWidth(colorDropdown, 70)
        
        local currentColor = data.textColor or "red"
        for _, c in ipairs(TEXT_COLORS) do
            if c.value == currentColor then
                UIDropDownMenu_SetText(colorDropdown, c.text)
                break
            end
        end
        
        UIDropDownMenu_Initialize(colorDropdown, function(self, level)
            for _, c in ipairs(TEXT_COLORS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = c.text
                info.value = c.value
                info.colorCode = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
                info.checked = (data.textColor == c.value)
                info.func = function()
                    MattOOCDB.trackedSpells[spellID].textColor = c.value
                    UIDropDownMenu_SetText(colorDropdown, c.text)
                    UpdateSpellFrame(spellID)
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        
        -- Scale input
        local scaleLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        scaleLabel:SetPoint("LEFT", colorDropdown, "RIGHT", 10, 2)
        scaleLabel:SetText("Scale:")
        
        local scaleBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        scaleBox:SetSize(40, 20)
        scaleBox:SetPoint("LEFT", scaleLabel, "RIGHT", 8, 0)
        scaleBox:SetAutoFocus(false)
        scaleBox:SetText(string.format("%.1f", data.scale or 1.0))
        scaleBox:SetScript("OnEnterPressed", function(self)
            local val = tonumber(self:GetText()) or 1.0
            val = math.max(0.5, math.min(3.0, val))
            MattOOCDB.trackedSpells[spellID].scale = val
            self:SetText(string.format("%.1f", val))
            self:ClearFocus()
            UpdateSpellFrame(spellID)
        end)
        scaleBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        
        -- Row 4: Custom text
        local row4Y = -90
        local msgLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        msgLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 12, row4Y)
        msgLabel:SetText("Custom Text:")
        
        local msgInput = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        msgInput:SetSize(420, 20)
        msgInput:SetPoint("LEFT", msgLabel, "RIGHT", 8, 0)
        msgInput:SetAutoFocus(false)
        msgInput:SetText(data.customMessage or "")
        msgInput:SetScript("OnEnterPressed", function(self)
            MattOOCDB.trackedSpells[spellID].customMessage = self:GetText()
            self:ClearFocus()
            UpdateSpellFrame(spellID)
        end)
        msgInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        
        table.insert(spellRows, row)
        yOffset = yOffset - 132
    end
    scrollChild:SetHeight(math.max(200, math.abs(yOffset) + 10))
end

-- Create config GUI
local function CreateConfigFrame()
    if ConfigFrame then
        ConfigFrame:Show()
        RefreshSpellList()
        if ConfigFrame.mplusWarningCheck then
            ConfigFrame.mplusWarningCheck:SetChecked(not MattOOCDB.hideMPlusBuffWarning)
        end
        return
    end
    
    ConfigFrame = CreateFrame("Frame", "MattOOCConfig", UIParent, "BackdropTemplate")
    ConfigFrame:SetSize(560, 480)
    ConfigFrame:SetPoint("CENTER")
    ConfigFrame:SetMovable(true)
    ConfigFrame:EnableMouse(true)
    ConfigFrame:RegisterForDrag("LeftButton")
    ConfigFrame:SetScript("OnDragStart", ConfigFrame.StartMoving)
    ConfigFrame:SetScript("OnDragStop", ConfigFrame.StopMovingOrSizing)
    ConfigFrame:SetFrameStrata("DIALOG")
    ConfigFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2
    })
    ConfigFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    ConfigFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    
    -- Title bar
    local titleBar = CreateFrame("Frame", nil, ConfigFrame, "BackdropTemplate")
    titleBar:SetSize(560, 28)
    titleBar:SetPoint("TOP", ConfigFrame, "TOP", 0, 0)
    titleBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    titleBar:SetBackdropColor(0.15, 0.15, 0.15, 1)
    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    local playerName = UnitName("player") or "Unknown"
    local _, playerClass = UnitClass("player")
    local classColor = RAID_CLASS_COLORS[playerClass] or { r = 1, g = 1, b = 1 }
    local colorHex = string.format("|cff%02x%02x%02x", classColor.r * 255, classColor.g * 255, classColor.b * 255)
    title:SetText("|cffffff00Matt's OOC|r - " .. colorHex .. playerName .. "|r")
    
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
    closeBtn:GetHighlightTexture():SetVertexColor(1, 0.3, 0.3)
    closeBtn:SetScript("OnClick", function() ConfigFrame:Hide() end)
    
    -- Description bar
    local descBar = CreateFrame("Frame", nil, ConfigFrame, "BackdropTemplate")
    descBar:SetSize(560, 22)
    descBar:SetPoint("TOP", titleBar, "BOTTOM", 0, 0)
    descBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    descBar:SetBackdropColor(0.1, 0.1, 0.1, 1)
    
    local descText = descBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    descText:SetPoint("CENTER", descBar, "CENTER", 0, -4)
    descText:SetText("|cffffffffTrack missing buffs & pets.|r |cffffffffReminders only show |cff00ff00OUT OF COMBAT|r|cffffffff.|r")
    
    -- Options section (vertical stack: Move Reminders, Minimap, M+ warning)
    local optionsSection = CreateFrame("Frame", nil, ConfigFrame, "BackdropTemplate")
    optionsSection:SetSize(540, 82)
    optionsSection:SetPoint("TOP", descBar, "BOTTOM", 0, -5)
    optionsSection:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    optionsSection:SetBackdropColor(0.15, 0.15, 0.15, 0.8)
    
    local rowHeight = 26
    local leftPad = 10
    
    -- Row 1: Move Reminders
    local unlockCheck = CreateFrame("CheckButton", nil, optionsSection, "UICheckButtonTemplate")
    unlockCheck:SetSize(20, 20)
    unlockCheck:SetPoint("TOPLEFT", optionsSection, "TOPLEFT", leftPad, -8)
    unlockCheck:SetChecked(isUnlocked)
    unlockCheck:SetScript("OnClick", function(self)
        ToggleUnlock()
        self:SetChecked(isUnlocked)
    end)
    local unlockLabel = optionsSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    unlockLabel:SetPoint("LEFT", unlockCheck, "RIGHT", 4, 0)
    unlockLabel:SetText("Move Reminders")
    ConfigFrame.unlockCheck = unlockCheck
    
    -- Row 2: Show Minimap Icon
    local minimapCheck = CreateFrame("CheckButton", nil, optionsSection, "UICheckButtonTemplate")
    minimapCheck:SetSize(20, 20)
    minimapCheck:SetPoint("TOPLEFT", optionsSection, "TOPLEFT", leftPad, -8 - rowHeight)
    MattOOCDB.minimap = MattOOCDB.minimap or { hide = false }
    minimapCheck:SetChecked(not MattOOCDB.minimap.hide)
    minimapCheck:SetScript("OnClick", function(self)
        MattOOCDB.minimap.hide = not self:GetChecked()
        local LDBIcon = LibStub("LibDBIcon-1.0", true)
        if LDBIcon then
            if MattOOCDB.minimap.hide then
                LDBIcon:Hide("MattOOC")
            else
                LDBIcon:Show("MattOOC")
            end
        end
    end)
    local minimapLabel = optionsSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    minimapLabel:SetPoint("LEFT", minimapCheck, "RIGHT", 4, 0)
    minimapLabel:SetText("Show Minimap Icon")
    
    -- Row 3: Show M+ warning notification
    local mplusWarningCheck = CreateFrame("CheckButton", nil, optionsSection, "UICheckButtonTemplate")
    mplusWarningCheck:SetSize(20, 20)
    mplusWarningCheck:SetPoint("TOPLEFT", optionsSection, "TOPLEFT", leftPad, -8 - rowHeight * 2)
    mplusWarningCheck:SetChecked(not MattOOCDB.hideMPlusBuffWarning)
    mplusWarningCheck:SetScript("OnClick", function(self)
        MattOOCDB.hideMPlusBuffWarning = not self:GetChecked()
        if not MattOOCDB.hideMPlusBuffWarning and MythicPlusNotificationFrame and MythicPlusNotificationFrame.neverShowAgainCheck then
            MythicPlusNotificationFrame.neverShowAgainCheck:SetChecked(false)
        end
        UpdateMythicPlusNotification()
    end)
    local mplusWarningLabel = optionsSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mplusWarningLabel:SetPoint("LEFT", mplusWarningCheck, "RIGHT", 4, 0)
    mplusWarningLabel:SetText("Show M+ warning notification")
    ConfigFrame.mplusWarningCheck = mplusWarningCheck
    
    -- Add section
    local addSection = CreateFrame("Frame", nil, ConfigFrame, "BackdropTemplate")
    addSection:SetSize(540, 35)
    addSection:SetPoint("TOP", optionsSection, "BOTTOM", 0, -5)
    addSection:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    addSection:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    
    local addLabel = addSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLabel:SetPoint("LEFT", addSection, "LEFT", 10, 0)
    addLabel:SetText("Add Spell:")
    
    local inputBox = CreateFrame("EditBox", nil, addSection, "InputBoxTemplate")
    inputBox:SetSize(120, 20)
    inputBox:SetPoint("LEFT", addLabel, "RIGHT", 5, 0)
    inputBox:SetAutoFocus(false)
    
    local petCheckAdd = CreateFrame("CheckButton", nil, addSection, "UICheckButtonTemplate")
    petCheckAdd:SetSize(20, 20)
    petCheckAdd:SetPoint("LEFT", inputBox, "RIGHT", 10, 0)
    petCheckAdd:SetChecked(false)
    local petLabelAdd = addSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    petLabelAdd:SetPoint("LEFT", petCheckAdd, "RIGHT", 0, 0)
    petLabelAdd:SetText("Pet")
    
    local addBtn = CreateFrame("Button", nil, addSection, "UIPanelButtonTemplate")
    addBtn:SetSize(50, 22)
    addBtn:SetPoint("LEFT", petLabelAdd, "RIGHT", 10, 0)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", function()
        local inputText = inputBox:GetText():trim()
        if inputText == "" then return end
        
        local spellID, spellName
        
        -- Check if input is a number (spell ID)
        local numericID = tonumber(inputText)
        if numericID and numericID > 0 then
            spellID = numericID
            spellName = GetSpellNameByID(spellID)
        else
            -- Try to look up by name
            spellID, spellName = GetSpellIDByName(inputText)
            if not spellID then
                print("|cffff0000Matt's OOC:|r Could not find spell: " .. inputText)
                return
            end
        end
        
        if spellID and spellID > 0 then
            -- Calculate default position based on existing spells
            local yOffset = 150
            for _, data in pairs(MattOOCDB.trackedSpells) do
                if data.pos and data.pos.y then
                    yOffset = math.min(yOffset, data.pos.y - 50)
                end
            end
            MattOOCDB.trackedSpells[spellID] = {
                name = spellName,
                enabled = true,
                isPet = petCheckAdd:GetChecked(),
                customMessage = "",
                showWhenResting = false,
                showIcon = true,
                effect = "none",
                textColor = GetDefaultColorForSpell(spellID, spellName),
                scale = 1.0,
                pos = { point = "CENTER", x = 0, y = yOffset }
            }
            inputBox:SetText("")
            petCheckAdd:SetChecked(false)
            RefreshSpellList()
            UpdateSpellFrame(spellID)
            print("|cff00ff00Matt's OOC:|r Added " .. spellName)
        end
    end)
    inputBox:SetScript("OnEnterPressed", function() addBtn:Click() end)
    
    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, ConfigFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(535, 330)
    scrollFrame:SetPoint("TOP", addSection, "BOTTOM", -10, -10)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(525, 330)
    scrollFrame:SetScrollChild(scrollChild)
    ConfigFrame.scrollChild = scrollChild
    
    RefreshSpellList()
    ConfigFrame:Show()
end

-- Initialize
InitDB()

-- Slash command
SLASH_MATTOOC1 = "/mattooc"
SLASH_MATTOOC2 = "/mooc"
SlashCmdList["MATTOOC"] = function(msg)
    if msg == "config" or msg == "" then
        CreateConfigFrame()
    elseif msg == "unlock" then
        ToggleUnlock()
        if ConfigFrame and ConfigFrame.unlockCheck then
            ConfigFrame.unlockCheck:SetChecked(isUnlocked)
        end
        if ConfigFrame and ConfigFrame.mplusWarningCheck then
            ConfigFrame.mplusWarningCheck:SetChecked(not MattOOCDB.hideMPlusBuffWarning)
        end
    elseif msg == "test" then
        print("|cff00ff00Matt's OOC Debug:|r")
        print("  inCombat: " .. tostring(inCombat))
        print("  IsResting: " .. tostring(IsResting()))
        print("  HasPet: " .. tostring(HasPet()))
        
        -- Mythic+ debugging
        local inInstance, instanceType = IsInInstance()
        print("  InInstance: " .. tostring(inInstance) .. ", Type: " .. tostring(instanceType))
        if inInstance then
            local name, instanceType2, difficulty, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceID, instanceGroupSize, LfgDungeonID = GetInstanceInfo()
            print("  Instance: " .. tostring(name) .. ", Difficulty: " .. tostring(difficulty) .. " (" .. tostring(difficultyName) .. ")")
            
            if C_MythicPlus and C_MythicPlus.IsMythicPlusActive then
                local isMythicPlusActive = C_MythicPlus.IsMythicPlusActive()
                print("  IsMythicPlusActive: " .. tostring(isMythicPlusActive))
            else
                print("  IsMythicPlusActive: API not available")
            end
            
            -- Check for active challenge mode (most reliable for M+)
            if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
                local activeChallengeMapID = C_ChallengeMode.GetActiveChallengeMapID()
                print("  ActiveChallengeMapID: " .. tostring(activeChallengeMapID))
            else
                print("  ActiveChallengeMapID API: not available")
            end
            
            -- Check keystone info
            if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
                local activeKeystoneLevel, activeAffixIDs, wasActiveKeystoneCharged = C_ChallengeMode.GetActiveKeystoneInfo()
                print("  Keystone Level: " .. tostring(activeKeystoneLevel))
                print("  Keystone Charged: " .. tostring(wasActiveKeystoneCharged))
                if activeAffixIDs and #activeAffixIDs > 0 then
                    print("  Active Affixes: " .. #activeAffixIDs .. " affixes")
                end
            else
                print("  Keystone API: not available")
            end
            
            -- Final mythic+ determination
            local isMythicPlus = false
            if instanceType == "party" then
                if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
                    local activeChallengeMapID = C_ChallengeMode.GetActiveChallengeMapID()
                    isMythicPlus = (activeChallengeMapID ~= nil)
                else
                    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
                        local activeKeystoneLevel = C_ChallengeMode.GetActiveKeystoneInfo()
                        isMythicPlus = (activeKeystoneLevel and activeKeystoneLevel > 0)
                    end
                end
            end
            print("  Final M+ Detection: " .. tostring(isMythicPlus))
        end
        
        for spellID, data in pairs(MattOOCDB.trackedSpells) do
            local posStr = data.pos and string.format("(%s, %.0f, %.0f)", data.pos.point, data.pos.x, data.pos.y) or "default"
            print("  " .. data.name .. " (" .. spellID .. "): pos=" .. posStr)
        end
    elseif msg == "show" then
        for spellID, _ in pairs(MattOOCDB.trackedSpells) do
            local frame = CreateSpellFrame(spellID)
            if frame then frame:Show() end
        end
    end
end

-- Event frame
local EventFrame = CreateFrame("Frame")

EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- Create frames for all tracked spells
        for spellID, _ in pairs(MattOOCDB.trackedSpells) do
            CreateSpellFrame(spellID)
        end
        inCombat = InCombatLockdown()
        C_Timer.After(3, UpdateWarningDisplay)
    elseif event == "PLAYER_ENTERING_WORLD" then
        inCombat = InCombatLockdown()
        C_Timer.After(2, UpdateWarningDisplay)
        C_Timer.After(2, UpdateMythicPlusNotification)
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        for _, frame in pairs(spellFrames) do
            if not isUnlocked then frame:Hide() end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        -- Give extra time in instances for auras to properly register
        local inInstance, instanceType = IsInInstance()
        local delay = (inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario")) and 2.0 or 0.5
        C_Timer.After(delay, UpdateWarningDisplay)
    elseif event == "UNIT_PET" then
        local unit = ...
        if unit == "player" then
            C_Timer.After(0.2, UpdateWarningDisplay)
        end
    elseif event == "UNIT_AURA" then
        local unit = ...
        -- Only process aura updates outside of combat
        if unit == "player" and not InCombatLockdown() then
            -- Throttle updates in instances to avoid spam
            local inInstance, instanceType = IsInInstance()
            local delay = (inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario")) and 0.5 or 0.1
            C_Timer.After(delay, UpdateWarningDisplay)
        end
    elseif event == "CHALLENGE_MODE_START" then
        keystoneActive = true
        -- Hide all frames during keystone
        for _, frame in pairs(spellFrames) do
            frame:Hide()
        end
        UpdateMythicPlusNotification()
        print("|cff00ff00Matt's OOC:|r Keystone started - reminders disabled")
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        keystoneActive = false
        -- Re-enable after keystone ends
        if not InCombatLockdown() then
            C_Timer.After(2.0, UpdateWarningDisplay)
        end
        UpdateMythicPlusNotification()
        print("|cff00ff00Matt's OOC:|r Keystone completed - reminders re-enabled")
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_UPDATE_RESTING" then
        C_Timer.After(1.0, UpdateWarningDisplay)
        C_Timer.After(1.0, UpdateMythicPlusNotification)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Update when group composition changes (important for raids/M+)
        if not InCombatLockdown() then
            C_Timer.After(1.0, UpdateWarningDisplay)
        end
    elseif event == "CHALLENGE_MODE_START" or event == "CHALLENGE_MODE_COMPLETED" then
        -- Mythic+ challenge mode events - update display since M+ state changed
        if not InCombatLockdown() then
            C_Timer.After(1.0, UpdateWarningDisplay)
        end
    end
end)

EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterEvent("UNIT_PET")
EventFrame:RegisterEvent("UNIT_AURA")
EventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
EventFrame:RegisterEvent("PLAYER_UPDATE_RESTING")
EventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
-- Mythic+ specific events
EventFrame:RegisterEvent("CHALLENGE_MODE_START")
EventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")

-- Minimap Icon using LibDBIcon
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

local MattOOCLDB = LDB:NewDataObject("Matt's OOC", {
    type = "launcher",
    text = "Matt's OOC",
    icon = "Interface\\AddOns\\MattOOC\\Media\\oocicon.png",
    OnClick = function(self, button)
        if button == "LeftButton" then
            CreateConfigFrame()
        elseif button == "RightButton" then
            ToggleUnlock()
            if ConfigFrame and ConfigFrame.unlockBtn then
                ConfigFrame.unlockBtn:SetText(isUnlocked and "Lock" or "Unlock")
            end
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("|cff00ff00Matt's OOC|r")
        tooltip:AddLine("Out of Combat Spell Reminder")
        tooltip:AddLine(" ")
        tooltip:AddLine("|cffffffffLeft-Click:|r Open Config")
        tooltip:AddLine("|cffffffffRight-Click:|r Toggle Unlock")
    end,
})

-- Register minimap icon after PLAYER_LOGIN
local minimapFrame = CreateFrame("Frame")
minimapFrame:RegisterEvent("PLAYER_LOGIN")
minimapFrame:SetScript("OnEvent", function()
    MattOOCDB.minimap = MattOOCDB.minimap or { hide = false }
    LDBIcon:Register("Matt's OOC", MattOOCLDB, MattOOCDB.minimap)
end)

print("|cff00ff00Matt's OOC|r loaded - /mattooc to configure")
