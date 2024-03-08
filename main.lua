--[[--
This is a plugin to automatically log reading progress to Beeminder.

@module koplugin.Beeminder
--]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local socket = require("socket")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")
local logger = require("logger")
local _ = require("gettext")

local Beeminder = WidgetContainer:extend{
    name = "beeminder",
    is_doc_only = false,
}

function Beeminder:init()
    self.book_data = {
        title = "",
        pages = 0,
    }
    local default_settings = {
        username = "",
        token = "",
    }
    self.settings = G_reader_settings:readSetting("beeminder", default_settings)
    self.ui.menu:registerToMainMenu(self)
end

function Beeminder:setAuthToken(token)
    self.settings.token = token ~= "" and token or nil
end

function Beeminder:setUsername(username)
    self.settings.username = username
end

function Beeminder:addToMainMenu(menu_items)
    menu_items.beeminder = {
        text = _("Beeminder"),
        -- in which menu this should be appended
        sorting_hint = "more_tools",
        -- a callback when tapping
        sub_item_table = {
            {
                text = _("Set username"),
                keep_menu_open = true,
                tap_input_func = function()
                    return {
                        title = _("Username"),
                        input = self.settings.username or "",
                        type = "text",
                        callback = function(input)
                            self:setUsername(input)
                        end,
                    }
                end,
            },
            {
                text = _("Set auth token"),
                keep_menu_open = true,
                tap_input_func = function()
                    return {
                        title = _("Auth token"),
                        input = self.settings.token or "",
                        type = "text",
                        callback = function(input)
                            self:setAuthToken(input)
                        end,
                    }
                end,
            }
        }
    }
end

-- gets goal name based on the title of the document
-- transforms the filename minus the extension into a python snake case format
-- as many words will fit into 20 chars
-- e.g. "My Goal.epub" -> "book-my_goal"
-- e.g. "My Very Long Goal Title.epub" -> "book-my_very_long_goal"
function Beeminder:getGoalName()
    -- Get the book title
    local title = self.book_data.title

    -- Remove the file extension
    title = string.gsub(title, "%.epub$", "")

    -- Convert to lowercase
    title = string.lower(title)

    -- Replace non-word characters with spaces to simplify splitting
    title = string.gsub(title, "[^%w%s]", "")

    -- Split the title into words
    local words = {}
    for word in string.gmatch(title, "%w+") do
        table.insert(words, word)
    end

    local goal_name = "book"
    local total_length = #goal_name

    -- Add words until the length exceeds 20 characters
    for i, word in ipairs(words) do
        if total_length + #word + 1 > 20 then -- +1 accounts for the underscore or initial "book-" length
            break
        end
        goal_name = goal_name .. (i == 1 and "-" or "_") .. word
        total_length = total_length + #word + 1
    end
    logger.dbg("Beeminder goal name: " .. goal_name)

    return goal_name
end

function Beeminder:getGoal()
    local goal_name = self:getGoalName()
    local url = "https://www.beeminder.com/api/v1/users/" .. self.settings.username .. "/goals/" .. goal_name .. ".json?auth_token=" .. self.settings.token
    -- Get response and status code
    local sink = {}
    local request = {}

    request.url = url
    request.sink = ltn12.sink.table(sink)
    request.method = "GET"
    request.headers = {
        ["Content-Type"] = "application/json",
    }

    local status_code, resp_headers, status = socket.skip(1, http.request(request))
    local response = table.concat(sink)
    if status_code >= 300 then
        UIManager:show(InfoMessage:new{
            text = _(string.format("Communication with Beeminder server failed with status code %d", status_code)), })
        logger.dbg("Communication with Beeminder server failed with status code " .. status_code .. ": " .. response)
    end
    local ok, json_response = pcall(json.decode, response)
    if not ok or not json_response then
        UIManager:show(InfoMessage:new{
            text = _("Failed to parse JSON response from Beeminder server"), })
        logger.dbg("Failed to parse JSON response from Beeminder server: " .. response)
    end
    return json_response
end

function Beeminder:updateDatapoint(id, value, comment)
    local goal = self:getGoalName()
    local url = "https://www.beeminder.com/api/v1/users/" .. self.settings.username .. "/goals/" .. goal .. "/datapoints/" .. id .. ".json?auth_token=" .. self.settings.token
    local data = {
        value = value,
        comment = comment,
    }
    local sink = {}
    local status_code, resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = "PUT",
        headers = {
            ["Content-Type"] = "application/json",
        },
        source = ltn12.source.string(json.encode(data)),
        sink = ltn12.sink.table(sink),
    })
    local response = table.concat(sink)
    if status_code >= 300 then
        UIManager:show(InfoMessage:new{
            text = _(string.format("Update datapoint in Beeminder server failed with status code %d", status_code)), })
        logger.dbg("Update datapoint in Beeminder server failed with status code " .. status_code .. ": " .. response)
    end
end

function Beeminder:createDatapoint(value, comment)
    local goalName = self:getGoalName()
    local url = "https://www.beeminder.com/api/v1/users/" .. self.settings.username .. "/goals/" .. goalName .. "/datapoints.json?auth_token=" .. self.settings.token
    local data = {
        value = value,
        comment = comment,
    }
    local sink = {}
    local status_code, resp_headers, status = http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
        },
        source = ltn12.source.string(json.encode(data)),
        sink = ltn12.sink.table(sink),
    }
    local response = table.concat(sink)
    if status_code >= 300 then
        UIManager:show(InfoMessage:new{
            text = _(string.format("Create datapoint in Beeminder server failed with status code %d", status_code)), })
        logger.dbg("Create datapoint in Beeminder server failed with status code " .. status_code .. ": " .. response)
    end
end

function Beeminder:onPageUpdate(pageno)
    self.book_data.pages = pageno
end

function Beeminder:onReaderReady()
    self.book_data.title = self.ui.doc_props.display_title
end

-- When document is closed, attempt to log a new datapoint to the goal
function Beeminder:onCloseDocument()
    local page_count = self.book_data.pages
    NetworkMgr:goOnlineToRun(function()
        local goal = self:getGoal()

        -- If the most recent datapoint has not changed, do not log a new datapoint
        if goal and goal.last_datapoint and goal.last_datapoint.value == page_count then
            return
        end

        -- If the page count is different, report an error
        if goal and goal.goalval and goal.goalval ~= self.document:getPageCount() then
            UIManager:show(InfoMessage:new{
                text = _("The page count in the document does not match the page count in Beeminder. Please scale the goal accordingly."), })
            return
        end

        -- Otherwise, if the most recent datapoint is from today, then update it.
        -- If it is from yesterday or before, then create a new datapoint.
        local today = os.date("*t")
        local datapoint_date = os.date("*t", goal.last_datapoint.timestamp)

        if datapoint_date.year == today.year and datapoint_date.month == today.month and datapoint_date.day == today.day then
            self:updateDatapoint(goal.last_datapoint.id, page_count, "Logged from KOReader")
        else
            self:createDatapoint(page_count, "Logged from KOReader")
        end
    end)
end

return Beeminder
