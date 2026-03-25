local CDM = _G.Ayije_CDM
if not CDM then
    return
end

local C_Timer = C_Timer
local hooksecurefunc = hooksecurefunc
local ipairs = ipairs
local next = next
local pairs = pairs
local type = type
local unpack = unpack

local VIEWERS = CDM.CONST and CDM.CONST.VIEWERS or {}
local VIEWER_GROUPS = {
    [VIEWERS.ESSENTIAL] = "Essential",
    [VIEWERS.UTILITY] = "Utility",
    [VIEWERS.BUFF] = "Buffs",
    [VIEWERS.BUFF_BAR] = "Buff Bars",
}
local TRACKER_CONTAINERS = {
    "CDM_RacialsContainer",
    "CDM_DefensivesContainer",
    "CDM_TrinketsContainer",
}

local entriesByButton = setmetatable({}, { __mode = "k" })
local masqueGroups = {}
local masqueGroupEntries = setmetatable({}, { __mode = "k" })
local hookedViewers = {}
local queuedViewerScans = {}
local customBuffScanQueued = false

local NDuiB, NDuiC, NDuiDB
local Masque
local GetMasqueGroup

local function RefreshIntegrations()
    if not NDuiB then
        local ndui = _G.NDui
        if type(ndui) == "table" then
            NDuiB, NDuiC, _, NDuiDB = unpack(ndui)
        end
    end

    if not Masque and LibStub then
        Masque = LibStub("Masque", true)
    end
end

local function IsNDuiSkinEnabled()
    RefreshIntegrations()
    return NDuiB and NDuiC and NDuiDB
        and NDuiC.db and NDuiC.db.Skins
        and NDuiC.db.Skins.CooldownMgr
end

local function IsMasqueEnabled(entry)
    local group = entry and entry.masqueGroup
    return group and group.db and not group.db.Disabled
end

local function FindFirstTextureRegion(frame)
    if not (frame and frame.GetRegions) then
        return nil
    end

    local regions = { frame:GetRegions() }
    for i = 1, #regions do
        local region = regions[i]
        if region and region.IsObjectType and region:IsObjectType("Texture") then
            return region
        end
    end
end

local function SetInside(region, anchor, xOffset, yOffset)
    if not (region and anchor) then
        return
    end

    xOffset = xOffset or 0
    yOffset = yOffset == nil and xOffset or yOffset

    if region.SetInside then
        region:SetInside(anchor, xOffset, yOffset)
    else
        region:ClearAllPoints()
        region:SetPoint("TOPLEFT", anchor, "TOPLEFT", xOffset, -yOffset)
        region:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -xOffset, yOffset)
    end
end

local function HideRegion(region)
    if region and region.Hide then
        region:Hide()
    end
end

local function HideBorderFrame(frame)
    if not frame then
        return
    end

    HideRegion(frame.border)
    HideRegion(frame)
end

local function HidePixelStore(store)
    if store and store.pixelIconBorderFrame then
        store.pixelIconBorderFrame:Hide()
    end
end

local function HideAyijeBorders(entry)
    local frame = entry and entry.frame
    if not frame then
        return
    end

    if CDM.GetFrameData then
        local frameData = CDM.GetFrameData(frame)
        if frameData then
            HideBorderFrame(frameData.borderFrame)
            HideBorderFrame(frameData.iconBorderFrame)
            HideRegion(frameData.pixelIconBorderFrame)
            HidePixelStore(frameData.barIconPixelBorderStore)
        end
    end

    HideBorderFrame(frame.cdmBorderFrame)
    HideRegion(frame.pixelIconBorderFrame)
end

local function HideIconAuxRegions(owner, iconTexture)
    if not (owner and owner.GetRegions) then
        return
    end

    local _, second, third = owner:GetRegions()
    if second and second ~= iconTexture and (not second.IsObjectType or not second:IsObjectType("FontString")) then
        second:Hide()
    end
    if third and third ~= iconTexture and (not third.IsObjectType or not third:IsObjectType("FontString")) then
        third:Hide()
    end
end

local function EnsureNDuiBackdrop(entry, iconOwner, inset)
    if not IsNDuiSkinEnabled() or not entry.iconTexture then
        return nil
    end

    local bg = entry.nduiBackdrop or entry.iconTexture.bg or (iconOwner and iconOwner.bg)
    if not bg and NDuiB and NDuiB.ReskinIcon then
        bg = NDuiB.ReskinIcon(entry.iconTexture, true)
    end

    if bg then
        entry.nduiBackdrop = bg
        if entry.iconTexture and not entry.iconTexture.bg then
            entry.iconTexture.bg = bg
        end
        if iconOwner and not iconOwner.bg then
            iconOwner.bg = bg
        end
        bg:Show()
    end

    SetInside(entry.iconTexture, iconOwner, inset or 2, inset or 2)

    if entry.cooldown then
        if entry.cooldown.SetDrawEdge then
            entry.cooldown:SetDrawEdge(false)
        end
        if entry.cooldown.SetSwipeTexture and NDuiDB and NDuiDB.flatTex then
            entry.cooldown:SetSwipeTexture(NDuiDB.flatTex)
        end

        if bg then
            SetInside(entry.cooldown, bg, 0, 0)
        else
            SetInside(entry.cooldown, iconOwner or entry.button, 0, 0)
        end
    end

    return bg
end

local function ApplyNDuiTracker(entry)
    local bg = EnsureNDuiBackdrop(entry, entry.button, 2)
    if bg then
        bg:Show()
    end
    HideAyijeBorders(entry)
end

local function ApplyNDuiViewer(entry)
    HideIconAuxRegions(entry.button, entry.iconTexture)
    local bg = EnsureNDuiBackdrop(entry, entry.button, entry.iconInset or 2)
    if bg then
        bg:Show()
    end
    HideAyijeBorders(entry)
end

local function ApplyNDuiCustomBuff(entry)
    local bg = EnsureNDuiBackdrop(entry, entry.button, 2)
    if bg then
        bg:Show()
    end
    HideAyijeBorders(entry)
end

local function RestoreTrackerDefault(entry)
    if CDM.ApplyTrackerStyle and entry.viewerName then
        CDM:ApplyTrackerStyle(entry.frame, entry.viewerName, true)
    end
end

local function RestoreViewerDefault(entry)
    if entry.viewerName == VIEWERS.BUFF_BAR then
        if CDM.ApplyBarStyle then
            CDM:ApplyBarStyle(entry.frame, entry.viewerName, nil, entry.frame:GetWidth(), entry.frame:GetHeight())
        end
    elseif CDM.ApplyStyle then
        CDM:ApplyStyle(entry.frame, entry.viewerName, true)
    end
end

local function RestoreCustomBuffDefault(entry)
    local frame = entry.frame
    if not frame then
        return
    end

    if entry.iconTexture then
        entry.iconTexture:ClearAllPoints()
        entry.iconTexture:SetAllPoints(frame)

        local CDM_C = CDM.CONST
        if CDM_C and CDM_C.ApplyIconTexCoord and CDM_C.GetEffectiveZoomAmount then
            CDM_C.ApplyIconTexCoord(entry.iconTexture, CDM_C.GetEffectiveZoomAmount(), frame:GetWidth(), frame:GetHeight())
        end
    end

    if entry.cooldown then
        entry.cooldown:ClearAllPoints()
        entry.cooldown:SetAllPoints(frame)
    end

    if CDM.GetFrameData then
        local frameData = CDM.GetFrameData(frame)
        if frameData and frameData.borderFrame then
            frameData.borderFrame:Show()
            if frameData.borderFrame.border then
                frameData.borderFrame.border:Show()
            end
        end
    end
end

local function UpdateEntryAppearance(entry)
    if not (entry and entry.button and entry.button.GetObjectType) then
        return
    end
    if entry.bridgeUpdating then
        return
    end

    if IsMasqueEnabled(entry) then
        if entry.nduiBackdrop then
            entry.nduiBackdrop:Hide()
        end
        HideAyijeBorders(entry)
        return
    end

    if IsNDuiSkinEnabled() then
        if entry.kind == "tracker" then
            ApplyNDuiTracker(entry)
        elseif entry.kind == "custom_buff" then
            ApplyNDuiCustomBuff(entry)
        else
            ApplyNDuiViewer(entry)
        end
        return
    end

    if entry.nduiBackdrop then
        entry.nduiBackdrop:Hide()
    end

    if entry.restoreDefault then
        entry.bridgeUpdating = true
        entry.restoreDefault(entry)
        entry.bridgeUpdating = false
    end
end

local function OnMasqueGroupChanged(group)
    local groupSet = masqueGroupEntries[group]
    if not groupSet then
        return
    end

    for entry in pairs(groupSet) do
        UpdateEntryAppearance(entry)
    end
end

GetMasqueGroup = function(groupName)
    RefreshIntegrations()
    if not Masque then
        return nil
    end

    local group = masqueGroups[groupName]
    if group then
        return group
    end

    group = Masque:Group("Ayije_CDM", groupName)
    group:RegisterCallback(OnMasqueGroupChanged, "Disabled", "Reset")
    masqueGroups[groupName] = group
    masqueGroupEntries[group] = setmetatable({}, { __mode = "k" })

    return group
end

local function RegisterMasqueEntry(entry)
    local group = GetMasqueGroup(entry.groupName)
    if not group then
        return
    end

    entry.masqueGroup = group
    masqueGroupEntries[group][entry] = true

    if entry.masqueAdded then
        return
    end

    group:AddButton(entry.button, entry.regions, entry.masqueType, true)
    entry.masqueAdded = true
end

local function RegisterEntry(button, entry)
    if not button then
        return
    end

    local existing = entriesByButton[button]
    if existing then
        for key, value in pairs(entry) do
            existing[key] = value
        end
        entry = existing
    else
        entriesByButton[button] = entry
    end

    RegisterMasqueEntry(entry)
    UpdateEntryAppearance(entry)
end

local function BuildTrackerEntry(frame)
    if not (frame and frame.Icon) then
        return
    end

    local name = frame.GetName and frame:GetName() or ""
    local groupName = "Trackers"
    local viewerName = nil

    if name:find("^CDM_Racial_") then
        groupName = "Racials"
        viewerName = "CDM_Racials"
    elseif name:find("^CDM_Defensive_") then
        groupName = "Defensives"
        viewerName = "CDM_Defensives"
    elseif name:find("^CDM_Trinket_") then
        groupName = "Trinkets"
        viewerName = "CDM_Trinkets"
    end

    RegisterEntry(frame, {
        kind = "tracker",
        frame = frame,
        button = frame,
        iconTexture = frame.Icon,
        cooldown = frame.Cooldown,
        groupName = groupName,
        masqueType = "Action",
        viewerName = viewerName,
        restoreDefault = RestoreTrackerDefault,
        regions = {
            Icon = frame.Icon,
            Cooldown = frame.Cooldown,
            Count = frame.ChargeCount and frame.ChargeCount.Current or nil,
        },
    })
end

local function BuildViewerEntry(frame, viewerName)
    if not frame then
        return
    end

    local iconTexture = frame.Icon
    if not (iconTexture and iconTexture.IsObjectType and iconTexture:IsObjectType("Texture")) then
        iconTexture = FindFirstTextureRegion(frame)
    end
    if not iconTexture then
        return
    end

    RegisterEntry(frame, {
        kind = "viewer",
        frame = frame,
        button = frame,
        iconTexture = iconTexture,
        cooldown = frame.Cooldown,
        groupName = VIEWER_GROUPS[viewerName] or "Cooldown Viewer",
        masqueType = viewerName == VIEWERS.BUFF and "Aura" or "Action",
        viewerName = viewerName,
        iconInset = 2,
        restoreDefault = RestoreViewerDefault,
        regions = {
            Icon = iconTexture,
            Cooldown = frame.Cooldown,
            Count = frame.Applications and frame.Applications.Applications or frame.Count,
            Duration = frame.Duration,
            Border = frame.DebuffBorder,
        },
    })
end

local function BuildBuffBarEntry(frame, viewerName)
    if not (frame and frame.Icon and frame.Icon.GetRegions) then
        return
    end

    local button = frame.Icon
    local iconTexture = button.Icon
    if not (iconTexture and iconTexture.IsObjectType and iconTexture:IsObjectType("Texture")) then
        iconTexture = FindFirstTextureRegion(button)
    end
    if not iconTexture then
        return
    end

    RegisterEntry(button, {
        kind = "viewer",
        frame = frame,
        button = button,
        iconTexture = iconTexture,
        cooldown = frame.Cooldown,
        groupName = VIEWER_GROUPS[viewerName] or "Buff Bars",
        masqueType = "Aura",
        viewerName = viewerName,
        iconInset = 5,
        restoreDefault = RestoreViewerDefault,
        regions = {
            Icon = iconTexture,
            Cooldown = frame.Cooldown,
            Border = frame.DebuffBorder,
        },
    })
end

local function BuildCustomBuffEntry(frame)
    if not (frame and frame.Icon) then
        return
    end

    RegisterEntry(frame, {
        kind = "custom_buff",
        frame = frame,
        button = frame,
        iconTexture = frame.Icon,
        cooldown = frame.Cooldown,
        groupName = "Custom Buffs",
        masqueType = "Aura",
        restoreDefault = RestoreCustomBuffDefault,
        regions = {
            Icon = frame.Icon,
            Cooldown = frame.Cooldown,
        },
    })
end

local function ProcessViewer(viewerName)
    local viewer = _G[viewerName]
    if not (viewer and viewer.itemFramePool) then
        return
    end

    for frame in viewer.itemFramePool:EnumerateActive() do
        if viewerName == VIEWERS.BUFF_BAR then
            BuildBuffBarEntry(frame, viewerName)
        else
            BuildViewerEntry(frame, viewerName)
        end
    end
end

local function ScanTrackerContainers()
    for _, containerName in ipairs(TRACKER_CONTAINERS) do
        local container = _G[containerName]
        if container and container.GetChildren then
            local children = { container:GetChildren() }
            for i = 1, #children do
                BuildTrackerEntry(children[i])
            end
        end
    end
end

local function QueueViewerScan(viewerName)
    if queuedViewerScans[viewerName] then
        return
    end

    queuedViewerScans[viewerName] = true
    C_Timer.After(0, function()
        queuedViewerScans[viewerName] = nil
        ProcessViewer(viewerName)
    end)
end

local function QueueCustomBuffScan()
    if customBuffScanQueued then
        return
    end

    customBuffScanQueued = true
    C_Timer.After(0, function()
        customBuffScanQueued = false

        if not CDM.GetSortedCustomBuffFrames then
            return
        end

        local frames = CDM:GetSortedCustomBuffFrames()
        if not frames then
            return
        end

        for _, frame in ipairs(frames) do
            BuildCustomBuffEntry(frame)
        end
    end)
end

local function HookViewer(viewerName)
    if not viewerName or hookedViewers[viewerName] then
        return
    end

    local viewer = _G[viewerName]
    if not viewer then
        return
    end

    hookedViewers[viewerName] = true

    if viewer.RefreshLayout then
        hooksecurefunc(viewer, "RefreshLayout", function()
            QueueViewerScan(viewerName)
        end)
    end

    if viewer.itemFramePool and viewer.itemFramePool.Acquire then
        hooksecurefunc(viewer.itemFramePool, "Acquire", function()
            QueueViewerScan(viewerName)
        end)
    end

    QueueViewerScan(viewerName)
end

local function HookViewers()
    HookViewer(VIEWERS.ESSENTIAL)
    HookViewer(VIEWERS.UTILITY)
    HookViewer(VIEWERS.BUFF)
    HookViewer(VIEWERS.BUFF_BAR)
end

local function HookTrackerFactory()
    if CDM._AyijeNDuiMasqueCreateTrackerHooked or not CDM.CreateTrackerIcon then
        return
    end

    CDM._AyijeNDuiMasqueCreateTrackerHooked = true
    local original = CDM.CreateTrackerIcon

    CDM.CreateTrackerIcon = function(parent, namePrefix, id, opts)
        local frame = original(parent, namePrefix, id, opts)
        BuildTrackerEntry(frame)
        return frame
    end
end

local function HookCustomBuffFrames()
    if CDM._AyijeNDuiMasqueCustomBuffHooked or not CDM.GetSortedCustomBuffFrames then
        return
    end

    CDM._AyijeNDuiMasqueCustomBuffHooked = true
    local original = CDM.GetSortedCustomBuffFrames

    CDM.GetSortedCustomBuffFrames = function(self, ...)
        local frames = original(self, ...)
        if frames then
            for _, frame in ipairs(frames) do
                BuildCustomBuffEntry(frame)
            end
        end
        return frames
    end
end

local function HookStyleRefreshes()
    if CDM._AyijeNDuiMasqueStyleHooks then
        return
    end

    CDM._AyijeNDuiMasqueStyleHooks = true

    if CDM.ApplyTrackerStyle then
        hooksecurefunc(CDM, "ApplyTrackerStyle", function(_, frame)
            local entry = frame and entriesByButton[frame]
            if entry and not entry.bridgeUpdating then
                UpdateEntryAppearance(entry)
            end
        end)
    end

    if CDM.ApplyStyle then
        hooksecurefunc(CDM, "ApplyStyle", function(_, frame)
            local entry = frame and entriesByButton[frame]
            if entry and not entry.bridgeUpdating then
                UpdateEntryAppearance(entry)
            end
        end)
    end

    if CDM.ApplyBarStyle then
        hooksecurefunc(CDM, "ApplyBarStyle", function(_, frame)
            local button = frame and frame.Icon
            local entry = button and entriesByButton[button]
            if entry and not entry.bridgeUpdating then
                UpdateEntryAppearance(entry)
            end
        end)
    end

    if CDM.QueueViewer then
        hooksecurefunc(CDM, "QueueViewer", function(_, viewerName)
            if viewerName == VIEWERS.BUFF then
                QueueCustomBuffScan()
            elseif viewerName == VIEWERS.BUFF_BAR
                or viewerName == VIEWERS.ESSENTIAL
                or viewerName == VIEWERS.UTILITY then
                QueueViewerScan(viewerName)
            end
        end)
    end
end

local function RegisterRefreshCallback()
    if CDM._AyijeNDuiMasqueRefreshRegistered or not CDM.RegisterRefreshCallback then
        return
    end

    CDM._AyijeNDuiMasqueRefreshRegistered = true
    CDM:RegisterRefreshCallback("ayije_ndui_masque_bridge", function()
        HookViewers()
        ScanTrackerContainers()
        QueueCustomBuffScan()

        for _, viewerName in pairs(VIEWERS) do
            if viewerName then
                QueueViewerScan(viewerName)
            end
        end

        for _, entry in pairs(entriesByButton) do
            UpdateEntryAppearance(entry)
        end
    end, 200)
end

local function Bootstrap()
    RefreshIntegrations()
    HookTrackerFactory()
    HookCustomBuffFrames()
    HookStyleRefreshes()
    HookViewers()
    ScanTrackerContainers()
    QueueCustomBuffScan()
    RegisterRefreshCallback()
end

local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("ADDON_LOADED")
driver:SetScript("OnEvent", function(_, event, addonName)
    if event == "PLAYER_LOGIN" then
        Bootstrap()
        return
    end

    if addonName == "NDui" or addonName == "Masque" or addonName == "Blizzard_CooldownViewer" then
        RefreshIntegrations()
        Bootstrap()
    end
end)
