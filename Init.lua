--[[
    Ayije_CDM + NDui + Masque 桥接插件

    作用简述：
    1. 当启用 NDui 的 CooldownMgr 皮肤时，用 NDui 的方式重绘 CDM 的图标/冷却，并隐藏 CDM 自带边框。
    2. 当启用 Masque 时，把 CDM 的各类按钮交给 Masque 分组美化（此时会关掉 NDui 背景以不冲突）。
    3. 若两者都未按上述方式启用，则尝试恢复 CDM 默认外观。

    通过 hook CDM 创建图标、刷新布局、样式刷新等时机，扫描框体并维护「每个按钮对应一条 entry」的映射。
]]
local CDM = _G.Ayije_CDM
if not CDM then
    return
end

-- 局部引用 WoW API，略微加速且避免外部改掉全局
local C_Timer = C_Timer
local hooksecurefunc = hooksecurefunc
local ipairs = ipairs
local next = next
local pairs = pairs
local type = type
local unpack = unpack

-- CDM 内置的「监视器」全局名（Essential / Buff 等），来自 Ayije_CDM 常量
local VIEWERS = CDM.CONST and CDM.CONST.VIEWERS or {}
-- 监视器 → Masque 里显示的分组名称
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

-- button 帧 → 本插件维护的 entry（弱键：按钮销毁后表项可被 GC）
local entriesByButton = setmetatable({}, { __mode = "k" })
-- Masque 分组名 → Masque Group 对象
local masqueGroups = {}
-- Masque Group → 属于该组的 entry 集合（弱键，同上）
local masqueGroupEntries = setmetatable({}, { __mode = "k" })
local hookedViewers = {}
local queuedViewerScans = {}
-- 避免同一帧内重复排队扫描自定义 Buff
local customBuffScanQueued = false

-- NDui 解包：B=工具/皮肤函数，C=配置模块，DB=全局设置表
local NDuiB, NDuiC, NDuiDB
local Masque
local GetMasqueGroup

-- 按需拉取 NDui（全局表 NDui）与 Masque（LibStub），晚加载也能补上
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

-- NDui 是否对本插件生效：需要 Skin 里打开了 CooldownMgr
local function IsNDuiSkinEnabled()
    RefreshIntegrations()
    return NDuiB and NDuiC and NDuiDB
        and NDuiC.db and NDuiC.db.Skins
        and NDuiC.db.Skins.CooldownMgr
end

-- 该 entry 对应的 Masque 分组未被用户禁用
local function IsMasqueEnabled(entry)
    local group = entry and entry.masqueGroup
    return group and group.db and not group.db.Disabled
end

-- 有的框体没有标准 Icon 子区域，就找第一个 Texture 子层当代替
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

-- 把 region 贴在 anchor 内侧（有 SetInside 用 NDui/Elv 风格，否则手动四角对齐）
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

-- 隐藏 CDM/Ayije 自带的各类边框与像素边，避免和 NDui/Masque 叠两层
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

-- 监视器图标上有时多出一两层装饰纹理，NDui 重画前可先藏掉以免漏边
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

-- 为图标创建/复用 NDui ReskinIcon 的背景，并把图标与冷却置于其内
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

-- 三种入口形态：追踪条、普通监视器格、自定义 Buff（细节略有不同）
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

-- 关掉本插件效果时，分别调用 CDM 原版的样式应用函数复原
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

--[[
    核心分发：每个「按钮 + 元数据」entry 最终长什么样
    优先级：Masque 开启 > NDui CooldownMgr 皮肤 > 恢复 CDM 默认
]]
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

-- Masque 分组禁用/重置时，刷新该组内所有 CDM 按钮外观
local function OnMasqueGroupChanged(group)
    local groupSet = masqueGroupEntries[group]
    if not groupSet then
        return
    end

    for entry in pairs(groupSet) do
        UpdateEntryAppearance(entry)
    end
end

-- 在 Masque 里创建/缓存名为 "Ayije_CDM" 插件下的子分组，并监听禁用与重置
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

-- 把按钮加入对应 Masque 分组（regions 告诉 Masque 哪个是图标/冷却/层数等）
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

-- 合并同一按钮上多次 Build* 的字段，然后注册 Masque 并刷新外观
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

-- 种族/减伤/饰品追踪图标：根据框体命名分到不同 Masque 组
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

-- 普通冷却监视器单元格（Essential / Utility / Buff 等）
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

-- Buff 条样式：真正的「按钮」是 frame.Icon，与上面 BuildViewerEntry 结构不同
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

-- 用户自定义 Buff 列表里的单项
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

-- 遍历该监视器对象池里当前激活的所有格子并 Build*
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

-- 对已存在的三个追踪容器做一遍子控件扫描（重载/UI 已创建时）
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

-- 延迟到下一帧再扫，避免在布局中途反复 Enumerate 造成抖动或漏项
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

-- 自定义 Buff 列表更新后由 CDM 触发，同样防抖用 C_Timer.After(0)
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

-- 监视器布局刷新或池子 Acquire 新格子时再排队扫描一次
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

-- CDM 新建追踪图标时立刻包一层，保证新图标也被桥接
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

-- 每次 CDM 汇总自定义 Buff 框体列表时顺带注册
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

-- CDM 自己改样式或排队监视器后，再应用本桥接逻辑（bridgeUpdating 防止递归）
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

-- 向 CDM 注册低优先级刷新回调：统一再扫一遍并刷新所有已登记 entry
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

-- 启动时：打 hook、扫现有 UI、注册 CDM 刷新；可多次调用以应对晚加载插件
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

-- 事件驱动：登录时初始化；NDui/Masque/官方冷却监视器晚加载时再跑一次以接上库
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
