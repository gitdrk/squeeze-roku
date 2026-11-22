sub init()
    m.cfg = loadSettings()
    m.audio = m.top.findNode("audio")
    m.header = m.top.findNode("header")
    m.art = m.top.findNode("art")
    m.title = m.top.findNode("title")
    m.artist = m.top.findNode("artist")
    m.album = m.top.findNode("album")
    m.syncPill = m.top.findNode("syncPill")
    m.syncLabel = m.top.findNode("syncLabel")
    m.progress = m.top.findNode("progress")
    m.progFill = m.top.findNode("progFill")
    m.timeNow = m.top.findNode("timeNow")
    m.timeEnd = m.top.findNode("timeEnd")
    m.menu = m.top.findNode("menu")
    m.menuTitle = m.top.findNode("menuTitle")
    m.menuList = m.top.findNode("menuList")
    m.menuList.observeField("itemSelected", "onMenuSelected")
    m.menuItems = []
    m.menuKind = ""

    m.server = ""
    m.connection = "starting"
    m.status = invalid
    m.statusAt = 0
    m.players = []
    m.clock = CreateObject("roTimespan")

    m.slim = CreateObject("roSGNode", "SlimProtoTask")
    m.slim.audio = m.audio
    m.slim.mac = m.cfg.mac
    m.slim.playerName = m.cfg.name
    m.slim.formats = m.cfg.formats
    m.slim.catchUp = m.cfg.catchUp
    m.slim.startLag = m.cfg.startLag
    m.slim.observeField("connection", "onConnection")
    m.slim.observeField("startLag", "onStartLag")
    m.slim.observeField("reportedName", "onReportedName")
    m.slim.observeField("behindMs", "onBehind")
    m.slim.control = "RUN"
    m.pushedLag = -1
    m.lastResync = -100000

    m.rpc = CreateObject("roSGNode", "JsonRpcTask")
    m.rpc.mac = m.cfg.mac
    m.rpc.observeField("status", "onStatus")
    m.rpc.observeField("players", "onPlayers")
    m.rpc.control = "RUN"

    m.tick = m.top.findNode("tick")
    m.tick.observeField("fire", "onTick")
    m.tick.control = "start"
    m.retry = m.top.findNode("retry")
    m.retry.observeField("fire", "startDiscovery")
    m.prefsTimer = m.top.findNode("prefsTimer")
    m.prefsTimer.observeField("fire", "pushSyncPrefs")

    if m.cfg.serverIp <> "" then useServerText(m.cfg.serverIp) else startDiscovery()
    render()
    m.top.setFocus(true)
end sub

' ---- server ----

sub startDiscovery()
    if m.cfg.serverIp <> "" then return
    m.connection = "looking for a Lyrion server"
    updateHeader()
    m.disc = CreateObject("roSGNode", "DiscoveryTask")
    m.disc.observeField("done", "onDiscoveryDone")
    m.disc.control = "RUN"
end sub

sub onDiscoveryDone()
    if m.cfg.serverIp <> "" then return
    list = m.disc.servers
    if list <> invalid and list.Count() > 0 then
        port = Int(Val(list[0].json))
        if port <= 0 then port = 9000
        useServer(list[0].ip, port)
    else
        m.connection = "no Lyrion server found. Press * to enter its address"
        updateHeader()
        m.retry.control = "start"
    end if
end sub

' "192.168.1.5" or "192.168.1.5:9000" (the web port). Without a port, ask that server for its
' web port, since Docker installs often move it off 9000.
sub useServerText(text as string)
    parts = text.Split(":")
    if parts.Count() > 1 and Int(Val(parts[1])) > 0 then
        useServer(parts[0], Int(Val(parts[1])))
        return
    end if
    useServer(parts[0], 9000)
    m.portLookup = CreateObject("roSGNode", "DiscoveryTask")
    m.portLookup.target = parts[0]
    m.portLookup.observeField("done", "onPortLookupDone")
    m.portLookup.control = "RUN"
end sub

sub onPortLookupDone()
    list = m.portLookup.servers
    if list = invalid or list.Count() = 0 then return
    port = Int(Val(list[0].json))
    if port > 0 and port <> m.rpc.port then m.rpc.port = port
end sub

sub useServer(ip as string, port as integer)
    m.server = ip
    m.rpc.port = port
    m.rpc.server = ip
    m.slim.serverIp = ip
    m.slim.command = "reconnect"
    updateHeader()
end sub

sub onConnection()
    m.connection = m.slim.connection
    updateHeader()
    ' Lyrion creates the player on HELO; give it a moment, then hand over our sync settings.
    if m.connection = "connected" then m.prefsTimer.control = "start"
end sub

' Lyrion's own per-player sync settings do the delay work:
'   startDelay    how long this TV takes from "play" to sound (learned), so Lyrion starts it early
'   playDelay     how late the TV's speakers are (speaker delay), allowed for in every comparison
'   minSyncAdjust the smallest drift Lyrion bothers to correct (sync tolerance)
' Changing them in Lyrion's web settings works too, but this app sets them again on each connect.
sub pushSyncPrefs()
    setPlayerPref("startDelay", m.cfg.startLag)
    setPlayerPref("playDelay", m.cfg.delay)
    setPlayerPref("minSyncAdjust", m.cfg.tolerance)
    m.pushedLag = m.cfg.startLag
end sub

sub setPlayerPref(name as string, value as integer)
    sendCmd(["playerpref", name, value.ToStr()])
end sub

sub onStartLag()
    lag = m.slim.startLag
    if lag <> m.cfg.startLag then
        m.cfg.startLag = lag
        saveSetting("startLag", lag.ToStr())
    end if
    if m.pushedLag >= 0 and Abs(lag - m.pushedLag) >= 25 then
        setPlayerPref("startDelay", lag)
        m.pushedLag = lag
    end if
end sub

' Lyrion asked this TV to skip ahead and the Audio node can't do that reliably, so restart the
' whole group at its current position. Lyrion then starts every player together. At most twice a minute.
sub onBehind()
    if groupNames().Count() = 0 then return
    now = m.clock.TotalMilliseconds()
    if now - m.lastResync < 30000 then return
    m.lastResync = now
    sendCmd(["time", "+0"])
end sub

sub onReportedName()
    n = m.slim.reportedName
    if n <> "" and n <> m.cfg.name then
        m.cfg.name = n
        saveSetting("name", n)
        m.slim.playerName = n
        updateHeader()
    end if
end sub

sub updateHeader()
    text = m.cfg.name + "   ·   "
    if m.connection = "connected" then
        text = text + "Lyrion at " + m.server
    else
        text = text + m.connection
    end if
    m.header.text = text
end sub

' ---- now playing ----

sub onStatus()
    m.status = m.rpc.status
    m.statusAt = m.clock.TotalMilliseconds()
    render()
end sub

sub onPlayers()
    m.players = m.rpc.players
    render()
end sub

sub render()
    s = m.status
    playing = s <> invalid and s.ok = true and s.mode <> "stop" and s.title <> ""
    if playing then
        m.title.text = s.title
        m.artist.text = s.artist
        m.album.text = s.album
        if m.art.uri <> s.art then m.art.uri = s.art
        m.progress.visible = true
    else
        m.title.text = "Ready"
        m.artist.text = "Choose music for " + m.cfg.name
        m.album.text = "in any Lyrion app"
        m.art.uri = ""
        m.progress.visible = false
    end if
    renderSync()
    onTick()
end sub

sub renderSync()
    others = groupNames()
    if others.Count() = 0 then
        m.syncPill.visible = false
        return
    end if
    m.syncLabel.text = "Synced with " + others.Join(", ")
    w = m.syncLabel.boundingRect().width
    m.syncPill.width = w + 84
    m.syncPill.visible = true
end sub

' Names of the other players in our sync group.
function groupNames() as object
    out = []
    s = m.status
    if s = invalid or s.ok <> true then return out
    ids = []
    for each part in (s.syncMaster + "," + s.syncSlaves).Split(",")
        if part <> "" and LCase(part) <> LCase(m.cfg.mac) then ids.Push(LCase(part))
    end for
    for each id in ids
        name = id
        for each p in m.players
            if LCase(p.id) = id then name = p.name
        end for
        out.Push(name)
    end for
    return out
end function

function inGroup(id as string) as boolean
    s = m.status
    if s = invalid or s.ok <> true then return false
    all = LCase("," + s.syncMaster + "," + s.syncSlaves + ",")
    return Instr(1, all, "," + LCase(id) + ",") > 0 and Instr(1, all, "," + LCase(m.cfg.mac) + ",") > 0
end function

sub onTick()
    s = m.status
    if s = invalid or s.ok <> true or not m.progress.visible then return
    t = s.time
    if s.mode = "play" then t = t + (m.clock.TotalMilliseconds() - m.statusAt) / 1000.0
    d = s.duration
    if d > 0 then
        if t > d then t = d
        m.progFill.width = Int(920 * t / d)
        m.timeEnd.text = clockText(d)
    else
        m.progFill.width = 0
        m.timeEnd.text = ""
    end if
    m.timeNow.text = clockText(t)
end sub

function clockText(sec as float) as string
    total = Int(sec)
    mins = total \ 60
    secs = total mod 60
    s = secs.ToStr()
    if secs < 10 then s = "0" + s
    return mins.ToStr() + ":" + s
end function

' ---- remote ----

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if m.menu.visible then
        if key = "back" or key = "options" then
            closeMenu()
            return true
        end if
        return false
    end if
    if key = "OK" or key = "play" then
        sendCmd(["pause"])
        return true
    else if key = "right" or key = "fastforward" then
        sendCmd(["playlist", "index", "+1"])
        return true
    else if key = "left" or key = "rewind" then
        sendCmd(["playlist", "index", "-1"])
        return true
    else if key = "options" then
        openMainMenu(0)
        return true
    end if
    return false
end function

sub sendCmd(args as object)
    if m.server = "" then return
    m.rpc.cmd = [m.cfg.mac, args]
end sub

' ---- menus ----

sub openMenu(title as string, items as object, focusIndex as integer)
    m.menuTitle.text = title
    m.menuItems = items
    c = CreateObject("roSGNode", "ContentNode")
    for each it in items
        row = c.createChild("ContentNode")
        row.title = it.label
    end for
    m.menuList.content = c
    if focusIndex > 0 and focusIndex < items.Count() then m.menuList.jumpToItem = focusIndex
    m.menu.visible = true
    m.menuList.setFocus(true)
end sub

sub closeMenu()
    m.menu.visible = false
    m.top.setFocus(true)
end sub

sub openMainMenu(focusIndex as integer)
    m.menuKind = "main"
    srv = m.cfg.serverIp
    if srv = "" then
        srv = "find automatically"
        if m.server <> "" then srv = srv + " (" + m.server + ")"
    end if
    items = [
        { label: "Sync group", act: "sync" },
        { label: "Server: " + srv, act: "server" },
        { label: "Player name: " + m.cfg.name, act: "name" },
        { label: "Speaker delay: " + m.cfg.delay.ToStr() + " ms", act: "delay" },
        { label: "Sync tolerance: " + m.cfg.tolerance.ToStr() + " ms", act: "tolerance" },
        { label: "When behind: " + choiceLabel(catchUpChoices(), m.cfg.catchUp), act: "catchup" },
        { label: "Stream format: " + choiceLabel(formatChoices(), m.cfg.formats), act: "formats" },
        { label: "Start lag: " + m.cfg.startLag.ToStr() + " ms (select to reset)", act: "lag" }
    ]
    openMenu("Squeeze settings", items, focusIndex)
end sub

sub openSyncMenu()
    m.menuKind = "sync"
    items = [{ label: "Play on its own", act: "unsync" }]
    for each p in m.players
        if LCase(p.id) <> LCase(m.cfg.mac) and p.connected and p.isGroup <> true then
            label = "Join " + p.name
            if inGroup(p.id) then label = label + "   (in group)"
            items.Push({ label: label, act: "join", id: p.id })
        end if
    end for
    if items.Count() = 1 then items.Push({ label: "No other players are connected", act: "none" })
    openMenu("Sync group", items, 0)
end sub

sub onMenuSelected()
    idx = m.menuList.itemSelected
    if idx < 0 or idx >= m.menuItems.Count() then return
    it = m.menuItems[idx]
    act = it.act
    if act = "sync" then
        openSyncMenu()
    else if act = "unsync" then
        sendCmd(["sync", "-"])
        closeMenu()
    else if act = "join" then
        ' "<other> sync <us>" adds us to the other player's group, so we play what it plays
        m.rpc.cmd = [it.id, ["sync", m.cfg.mac]]
        closeMenu()
    else if act = "server" then
        askText("server", "Lyrion server", ["Its IP address, such as 192.168.1.20. Leave blank to find it automatically."], m.cfg.serverIp)
    else if act = "name" then
        askText("name", "Player name", ["How this TV shows up in Lyrion."], m.cfg.name)
    else if act = "delay" then
        askText("delay", "Speaker delay (ms)", ["Raise this if this TV plays behind your other speakers.", "Try 50 to 150 for TV speakers, more for a soundbar."], m.cfg.delay.ToStr())
    else if act = "formats" then
        m.cfg.formats = nextChoice(formatChoices(), m.cfg.formats)
        saveSetting("formats", m.cfg.formats)
        m.slim.formats = m.cfg.formats
        m.slim.command = "reconnect"
        openMainMenu(idx)
    else if act = "tolerance" then
        m.cfg.tolerance = nextTolerance(m.cfg.tolerance)
        saveSetting("tolerance", m.cfg.tolerance.ToStr())
        setPlayerPref("minSyncAdjust", m.cfg.tolerance)
        openMainMenu(idx)
    else if act = "catchup" then
        m.cfg.catchUp = nextChoice(catchUpChoices(), m.cfg.catchUp)
        saveSetting("catchUp", m.cfg.catchUp)
        m.slim.catchUp = m.cfg.catchUp
        openMainMenu(idx)
    else if act = "lag" then
        m.cfg.startLag = 400
        saveSetting("startLag", "400")
        m.slim.startLag = 400
        setPlayerPref("startDelay", 400)
        m.pushedLag = 400
        openMainMenu(idx)
    end if
end sub

sub askText(key as string, title as string, message as object, text as string)
    d = CreateObject("roSGNode", "StandardKeyboardDialog")
    d.title = title
    d.message = message
    d.text = text
    d.buttons = ["OK", "Cancel"]
    d.observeField("buttonSelected", "onKeyboardButton")
    m.askKey = key
    m.top.dialog = d
end sub

sub onKeyboardButton()
    d = m.top.dialog
    if d = invalid then return
    ok = (d.buttonSelected = 0)
    text = d.text.Trim()
    d.close = true
    if ok then applyText(m.askKey, text)
    if m.menuKind = "main" then openMainMenu(0)
end sub

sub applyText(key as string, text as string)
    if key = "server" then
        m.cfg.serverIp = text
        saveSetting("serverIp", text)
        if text = "" then
            m.server = ""
            startDiscovery()
        else
            useServerText(text)
        end if
    else if key = "name" then
        if text = "" then return
        m.cfg.name = text
        saveSetting("name", text)
        m.slim.playerName = text
        sendCmd(["name", text])
        updateHeader()
    else if key = "delay" then
        v = Int(Val(text))
        if v < 0 then v = 0
        if v > 2000 then v = 2000
        m.cfg.delay = v
        saveSetting("delay", v.ToStr())
        setPlayerPref("playDelay", v)
    end if
end sub
