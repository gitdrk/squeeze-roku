sub init()
    m.top.functionName = "runTask"
end sub

sub runTask()
    m.port = CreateObject("roMessagePort")
    m.top.observeField("cmd", m.port)
    m.top.observeField("server", m.port)
    m.top.observeField("port", m.port)
    clock = CreateObject("roTimespan")
    lastStatus = -100000
    lastPlayers = -100000

    while true
        now = clock.TotalMilliseconds()
        if m.top.server <> "" and m.top.mac <> "" then
            if now - lastPlayers >= 15000 then
                pollPlayers()
                lastPlayers = now
            end if
            if now - lastStatus >= 2000 then
                pollStatus()
                lastStatus = now
            end if
        end if
        msg = wait(500, m.port)
        if type(msg) = "roSGNodeEvent" then
            if msg.getField() = "cmd" then
                a = msg.getData()
                if a <> invalid and a.Count() = 2 then rpc(a[0], a[1])
                ' see the effect right away; a sync change also changes the player list
                lastStatus = -100000
                if a <> invalid and a.Count() = 2 and a[1].Count() > 0 and a[1][0] = "sync" then lastPlayers = -100000
            else
                lastStatus = -100000
                lastPlayers = -100000
            end if
        end if
    end while
end sub

function baseUrl() as string
    return "http://" + m.top.server + ":" + m.top.port.ToStr()
end function

' Runs one slim.request and returns its result, or invalid.
function rpc(player as string, args as object) as dynamic
    body = FormatJson({ id: 1, method: "slim.request", params: [player, args] })
    x = CreateObject("roUrlTransfer")
    p = CreateObject("roMessagePort")
    x.SetMessagePort(p)
    x.SetUrl(baseUrl() + "/jsonrpc.js")
    x.AddHeader("Content-Type", "application/json")
    if not x.AsyncPostFromString(body) then return invalid
    msg = wait(4000, p)
    if type(msg) <> "roUrlEvent" then
        x.AsyncCancel()
        return invalid
    end if
    if msg.GetResponseCode() <> 200 then return invalid
    j = ParseJson(msg.GetString())
    if j = invalid then return invalid
    return j.result
end function

sub pollStatus()
    r = rpc(m.top.mac, ["status", "-", "1", "tags:alcKNdj"])
    if r = invalid then
        m.top.status = { ok: false }
        return
    end if
    st = {
        ok: true,
        mode: textOf(r, "mode", "stop"),
        time: numOf(r, "time"),
        duration: numOf(r, "duration"),
        title: "",
        artist: "",
        album: "",
        art: "",
        syncMaster: textOf(r, "sync_master", ""),
        syncSlaves: textOf(r, "sync_slaves", "")
    }
    items = r.playlist_loop
    if items <> invalid and items.Count() > 0 then
        item = items[0]
        st.title = textOf(item, "title", "")
        st.artist = textOf(item, "artist", "")
        st.album = textOf(item, "album", "")
        st.art = artUrl(item)
        ' radio: the station is the "title" of the item, the song is in current_title
        station = textOf(item, "remote_title", "")
        cur = textOf(r, "current_title", "")
        if cur <> "" and cur <> st.title then
            if st.artist = "" then st.artist = st.title
            st.title = cur
        else if station <> "" and st.album = "" then
            st.album = station
        end if
    end if
    m.top.status = st
end sub

sub pollPlayers()
    r = rpc("", ["players", "0", "99"])
    if r = invalid or r.players_loop = invalid then return
    out = []
    for each p in r.players_loop
        ' virtual players from the Group Players plugin can't be joined with sync
        isGroup = LCase(textOf(p, "model", "")) = "group" or LCase(textOf(p, "modelname", "")) = "group"
        out.Push({ id: textOf(p, "playerid", ""), name: textOf(p, "name", "Player"), connected: numOf(p, "connected") = 1, isGroup: isGroup })
    end for
    m.top.players = out
end sub

function artUrl(item as object) as string
    a = textOf(item, "artwork_url", "")
    if a <> "" then
        if LCase(Left(a, 4)) = "http" then return a
        if Left(a, 1) <> "/" then a = "/" + a
        return baseUrl() + a
    end if
    c = textOf(item, "coverid", "")
    if c <> "" then return baseUrl() + "/music/" + c + "/cover_500x500"
    return ""
end function

' Lyrion returns numbers as strings or numbers depending on the field, so read both.
function textOf(aa as object, key as string, fallback as string) as string
    v = aa.Lookup(key)
    if v = invalid then return fallback
    t = type(v)
    if t = "roString" or t = "String" then return v
    return v.ToStr()
end function

function numOf(aa as object, key as string) as float
    v = aa.Lookup(key)
    if v = invalid then return 0
    t = type(v)
    if t = "roString" or t = "String" then return Val(v)
    return v
end function
