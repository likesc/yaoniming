local NAME = ...
local options

-- compat
local GetContainerItemInfo = C_Container.GetContainerItemInfo -- TODO
local GetContainerNumSlots = C_Container.GetContainerNumSlots or GetContainerNumSlots
local GetItemInfo = C_Item.GetItemInfo or GetItemInfo
-- item price/level

local tip_price = {}
-- BUGBUG : 会错误地重复一次 当商人对话框的"图纸"物品 显示了 "材料需求" 时
function tip_price.routine(tooltip)
	if tooltip:IsForbidden() then
		return
	end
	local _, link = tooltip:GetItem()
	if not link then
		return
	end
	-- name, link, quality, level, min-level, type, subtype, stackcount, equiploc, texture, price
	local _, _, _, level, _, _, _, _, equip, _, price = GetItemInfo(link)

	local show_price = price and options.price          and price > 0 and not tooltip.shownMoneyFrames
	local show_level = level and options.level ~= false and level > 1 and equip

	if show_price then
		local container = GetMouseFoci()[1]
		if not container then
			return
		end
		local object = container:GetObjectType()
		local count = 1
		if object == "Button" or object == "CheckButton" then
			count = container.count or container.Count or 1
			if type(count) == "table" then
				count = tonumber(count:GetText()) or 1
			end
		end
		tooltip:AddDoubleLine(GetMoneyString(count * price), show_level and "Lv(" .. level .. ")" or "")
	elseif show_level then
		tooltip:AddLine(format(ITEM_LEVEL, level))
	end
end
function tip_price.init(self)
	if not options.price and options.level == false then
		return
	end
	if self.done then
		return
	end
	self.done = true
	-- TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, tip_price)
	GameTooltip:HookScript("OnTooltipSetItem", self.routine)
	ItemRefTooltip:HookScript("OnTooltipSetItem", self.routine)
end

-- spell id

local tip_spell = {}
function tip_spell.routine(tooltip, unit, index, filter)
	if tooltip:IsForbidden() then
		return
	end
	local state = options.spellid
	if not state or state == 1 then
		return
	end
	local id
	if unit and index then
		id = select(10, UnitAura(unit, index, filter))
	else
		local _, sid = tooltip:GetSpell()
		id = sid
	end
	if id then
		tooltip:AddLine("法术ID : " .. id)
		tooltip:Show() -- refresh
	end
end
function tip_spell.init(self)
	local state = options.spellid
	if not state or state == 1 then
		return
	end
	local routine = self.routine
	if not self.aura then
		self.aura = true
		hooksecurefunc(GameTooltip, "SetUnitAura", routine)
		hooksecurefunc(GameTooltip, "SetUnitBuff", routine) -- "HELPFUL"
		hooksecurefunc(GameTooltip, "SetUnitDebuff", function(tooltip, unit, index) routine(tooltip, unit, index, "HARMFUL") end)
	end
	if not self.spell and state == 3 then
		self.spell = true
		GameTooltip:HookScript("OnTooltipSetSpell", routine)
	end
end

-- selljunk

local selljunk = {}
function selljunk.flush(sell)
	if sell.price > 0 then
		DEFAULT_CHAT_FRAME:AddMessage("|cff17a2b8获得|r: " .. GetMoneyString(sell.price))
	end
	sell.price = nil -- clear
end
function selljunk.next()
	local sell = selljunk
	if not sell.price then
		return
	end
	local state = sell.state
	local bag, slot, snum = unpack(state)
	while true do
		if slot > snum then
			bag = bag + 1
			slot = 1
			snum = GetContainerNumSlots(bag)
			if snum == 0 then
				sell.flush(sell)
				return
			end
			state[1] = bag
			state[2] = slot
			state[3] = snum
		end
		if sell:routine(bag, slot) then
			state[2] = slot + 1
			C_Timer.After(0.02, selljunk.next)
			return
		end
		slot = slot + 1
	end
end
function selljunk.routine(sell, bag, slot)
	local info = GetContainerItemInfo(bag, slot)
	if not info or info.isLocked or info.quality > 0 then
		return
	end
	local name, _, _, _, _, _, _, _, _, _, price = GetItemInfo(info.itemID)
	if not price or price == 0 or not MerchantFrame:IsShown() then
		return
	end
	C_Container.UseContainerItem(bag, slot)
	sell.price = sell.price + price * info.stackCount
	DEFAULT_CHAT_FRAME:AddMessage("|cffbfffff卖出|r: [" .. name .. "]")
	return true
end
function selljunk.begin(sell)
	if sell.price then
		sell.flush(sell) -- prevent deadlocks
		return
	end
	sell.price = 0
	sell.state = {0, 1, GetContainerNumSlots(0)}
	sell.next() -- TODO : switch to coroutine.yield ?
end
function selljunk.init()
	local button = CreateFrame("Button", nil, MerchantBuyBackItem)
	button:SetSize(32, 32)
	button:SetPoint("TOPRIGHT", MerchantFrame, -8, -26)
	local backdrop = button:CreateTexture(nil, "BACKGROUND")
	backdrop:SetAllPoints()
	backdrop:SetTexture("Interface/Icons/inv_misc_coin_06")

	button:SetPushedTexture("Interface/Buttons/UI-Quickslot-Depress");
	button:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square", "ADD")

	button:SetScript("OnLeave", GameTooltip_Hide)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("点击卖出背包内的垃圾物品")
		-- SetCursor("TODO")/ResetCursor()
	end)
	button:SetScript("OnMouseUp", function(_, _, inside)
		if not inside then
			return
		end
		selljunk:begin()
	end)
	selljunk.owner = button
end
function selljunk.destory()
	local button = selljunk.owner
	if not button then
		return
	end
	selljunk.owner = nil
	button:SetParent(nil)
	button:SetScript("OnLeave", nil)
	button:SetScript("OnEnter", nil)
	button:SetScript("OnMouseUp", nil)
end

-- cheapest (Stolen from https://github.com/ketho-wow/FlashCheapestGrey)

local cheapest = {}
function cheapest.light(bag, slot)
	local item
	for i = 1, NUM_CONTAINER_FRAMES, 1 do
		local frame = _G["ContainerFrame"..i]
		if frame:GetID() == bag and frame:IsShown() then
			item = _G["ContainerFrame"..i.."Item"..(GetContainerNumSlots(bag) + 1 - slot)]
		end
	end
	if item then
		item.NewItemTexture:SetAtlas("bags-glow-orange")
		item.NewItemTexture:Show()
		item.flashAnim:Play()
		item.newitemglowAnim:Play()
	end
end
function cheapest.mark(key, state)
	if not (key =="LCTRL" and state == 1) then
		return
	end
	local min = 2147483647 -- 0x7fffffff
	local x
	local y
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, GetContainerNumSlots(bag) do
			local info = GetContainerItemInfo(bag, slot)
			if info then
				local _, _, quality, _, _, _, _, _, _, _, price = GetItemInfo(info.itemID)
				if quality == 0 and price > 0 then
					local sum = price * info.stackCount
					if min > sum then
						min = sum
						x = bag
						y = slot
					end
				end
			end
		end
	end
	if x and IsBagOpen(x) then
		cheapest.light(x, y)
	end
end

-- fastloot (Stolen from https://github.com/Xarano-GIT/Faster-Loot)

local fastloot = {
	epoch = 0.,
	DELAY = 0.3,
}
function fastloot.run(self, checked)
	local now = GetTime()
	if checked == IsModifiedClick("AUTOLOOTTOGGLE") or now - self.epoch < self.DELAY then
		return
	end
	self.epoch = now
	for i = GetNumLootItems(), 1, -1 do
		LootSlot(i)
	end
end

-- health/mana status text

local health = {}
function health.init(self)
	if not options.health or self.done then
		return
	end
	local frame = TargetFrame
	local healbar = getglobal(frame:GetName() .. "HealthBar")
	local manabar = getglobal(frame:GetName() .. "ManaBar")
	if (not healbar) or healbar.TextString or (not manabar) or manabar.TextString then
		return
	end

	local function mk(parent, rel, x, y)
		local font = parent:CreateFontString(nil, "BORDER", "TextStatusBarText")
		font:SetPoint(rel, x, y)
		return font
	end
	local anchor = frame.textureFrame
	-- health
	self.ShouldKnowUnitHealth = ShouldKnowUnitHealth
	ShouldKnowUnitHealth = function(unit) return true end -- HOOK
	healbar.LeftText = mk(anchor, "LEFT", 6, 3) -- Warth/TargetFrame.xml
	healbar.RightText = mk(anchor, "RIGHT", -110, 3)
	healbar.TextString = mk(anchor, "CENTER", -50, 3)
	-- manabar
	manabar.LeftText = mk(anchor, "LEFT", 6, -8)
	manabar.RightText = mk(anchor, "RIGHT", -110, -8)
	manabar.TextString = mk(anchor, "CENTER", -50, -8)

	self.done = true

	if UnitExists("target") then
		UnitFrame_Update(frame)
	end
end

function health.destory(self)
	if not self.done then
		return
	end
	local function cleanup(bar)
		for _, key in ipairs({"LeftText", "RightText", "TextString"}) do
			bar[key]:SetParent(nil)
			bar[key] = nil
		end
	end

	ShouldKnowUnitHealth = self.ShouldKnowUnitHealth or ShouldKnowUnitHealth

	local name = TargetFrame:GetName()
	cleanup(getglobal(name .. "HealthBar"))
	cleanup(getglobal(name .. "ManaBar"))

	self.done = nil
end

-- global

local frame = CreateFrame("Frame")

local function PF(key) return NAME .. "-" .. key end
local function UNPF(key)
	local p = NAME .. "-"
	local w = #p
	return strsub(key, 1, w) == p and strsub(key, w + 1) or key
end

local function opt_changed(_, setting, value)
	local key = UNPF(setting:GetVariable())
	if key == "selljunk" then
		selljunk.destory()
		if value then
			selljunk.init()
		end
	elseif key == "cheapest" then
		frame:UnregisterEvent("MODIFIER_STATE_CHANGED")
		if value then
			frame:RegisterEvent("MODIFIER_STATE_CHANGED")
		end
	elseif key == "fastloot" then
		frame:UnregisterEvent("LOOT_READY")
		if value then
			frame:RegisterEvent("LOOT_READY")
		end
	elseif key == "spellid" then
		tip_spell:init()
	elseif key == "level" or key == "price" then
		tip_price:init()
	elseif key == "health" then
		health:destory()
		health:init()
	end
end

local function init(frame)
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then
		return
	end

	local category, layout = Settings.RegisterVerticalLayoutCategory(GetAddOnMetadata(NAME, "Title"))
	local booltype = type(true)
	do -- item level
		local key = "level"
		local label = "显示物品等级"
		local tooltip = "在鼠标提示中显示物品等级"
		local setting = Settings.RegisterAddOnSetting(category, PF(key), key, options, booltype, label, false)
		Settings.CreateCheckbox(category, setting, tooltip)
		Settings.SetOnValueChangedCallback(setting.variable, opt_changed)
	end
	do -- item price
		-- local has = Auctionator and Auctionator.Config.Get(Auctionator.Config.Options.VENDOR_TOOLTIPS)
		local key = "price"
		local label = "显示物品价格"
		local tooltip = "在鼠标提示中显示物品价格"
		local setting = Settings.RegisterAddOnSetting(category, PF(key), key, options, booltype, label, false)
		Settings.CreateCheckbox(category, setting, tooltip)
		Settings.SetOnValueChangedCallback(setting.variable, opt_changed)
	end
	tip_price:init()

	do -- spell id
		local key = "spellid"
		local label = "显示法术ID值"
		local tooltip = "在鼠标提示中显示法术的 ID 值"
		local get_options = function()
			local container = Settings.CreateControlTextContainer()
			container:Add(1, "不显示")
			container:Add(2, "仅增益")
			container:Add(3, "所有")
			return container:GetData()
		end
		local setting = Settings.RegisterAddOnSetting(category, PF(key), key, options, "number", label, 1)
		if options[key] and options[key] > 1 then
			tip_spell:init()
		end
		Settings.CreateDropdown(category, setting, get_options, tooltip)
		Settings.SetOnValueChangedCallback(setting.variable, opt_changed)
	end

	do -- cheapest
		local key = "cheapest"
		local label = "高亮背包垃圾"
		local tooltip = "按下 Ctrl 时高亮背包内最便宜的垃圾物品"
		local setting = Settings.RegisterAddOnSetting(category, PF(key), key, options, booltype, label, false)
		if options[key] then
			frame:RegisterEvent("MODIFIER_STATE_CHANGED")
		end
		Settings.CreateCheckbox(category, setting, tooltip)
		Settings.SetOnValueChangedCallback(setting.variable, opt_changed)
	end
	do -- selljunk
		local key = "selljunk"
		local label = "垃圾出售按钮"
		local tooltip = "在商人对话框的右上角添加一个垃圾出售的图标按钮"
		local setting = Settings.RegisterAddOnSetting(category, PF(key), key, options, booltype, label, false)
		if options[key] then
			selljunk.init()
		end
		Settings.CreateCheckbox(category, setting, tooltip)
		Settings.SetOnValueChangedCallback(setting.variable, opt_changed)
	end
	do -- fastloot
		local key = "fastloot"
		local label = "自动拾取加速"
		local tooltip = "不打开拾取框直接拾取"
		local setting = Settings.RegisterAddOnSetting(category, PF(key), key, options, booltype, label, false)
		if options[key] then
			frame:RegisterEvent("LOOT_READY")
		end
		Settings.CreateCheckbox(category, setting, tooltip)
		Settings.SetOnValueChangedCallback(setting.variable, opt_changed)
	end
	do -- health
		local key = "health"
		local label = "目标生命数值"
		local tooltip = "显示目标的生命和法力数值, (对玩家无效)"
		local setting = Settings.RegisterAddOnSetting(category, PF(key), key, options, booltype, label, false)
		if options[key] then
			health:init()
		end
		Settings.CreateCheckbox(category, setting, tooltip)
		Settings.SetOnValueChangedCallback(setting.variable, opt_changed)
	end

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("关于"))
	do
		local version = CreateFromMixins(SettingsListElementInitializer) -- copied from Settings.CreateElementInitializer
		version:Init("yaoniming-version", {})
		layout:AddInitializer(version)

		local report = CreateFromMixins(SettingsListElementInitializer)
		report:Init("yaoniming-report", {})
		layout:AddInitializer(report)
	end
	Settings.RegisterAddOnCategory(category)
end

local function onevent(self, event, arg1, arg2)
	if event == "LOOT_READY" then
		fastloot:run(arg1)
	elseif event == "MODIFIER_STATE_CHANGED" then
		cheapest.mark(arg1, arg2)
	end
end

local function main()
	frame:RegisterEvent("PLAYER_LOGIN")
	frame:SetScript("OnEvent", function(self)
		if not yaoniming_3000_options then
			yaoniming_3000_options = {}
		end
		options = yaoniming_3000_options
		init(self)
		self:SetScript("OnEvent", onevent)
	end)
end

local _ = main()
