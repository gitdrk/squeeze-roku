' The player: a SlimProto client that plays through a SceneGraph Audio node.
'
' Lyrion keeps sync. It tells each player when to start (strm u with a time in our jiffies),
' reads our elapsed time from STAT heartbeats, and nudges us with strm p (pause N ms) and
' strm a (skip N ms). The Audio node can only play a URL, so instead of a sample clock we keep a
' play clock (Proto.brs) fed by the node's position reports.
'
' Delays are Lyrion's job: MainScene stores our learned start lag as the player's startDelay
' pref and the speaker delay as playDelay, so start times arrive already adjusted and Lyrion
' allows for the speaker delay when it compares play points. This task reports raw times.
'
' Lyrion picks the player furthest ahead as the reference and asks everyone behind it to skip
' ahead. A Roku that falls behind therefore gets strm a, which catchUp decides how to handle.
'
' Modes:
'   stopped    nothing loaded
'   waitStart  track loaded, waiting for Lyrion's start time (sync groups use autostart 0)
'   starting   control = play sent, waiting for the node to report playing
'   playing    playing
'   paused     paused by the user
'   pausedFor  paused for an interval by Lyrion's sync correction
'   ending     track finished, decoder-ready sent, waiting to hear if there is a next track

sub init()
    m.top.functionName = "runTask"
end sub

sub runTask()
    m.port = CreateObject("roMessagePort")
    m.clock = CreateObject("roTimespan")
    m.clock.Mark()
    m.audio = m.top.audio
    m.audio.notificationInterval = 0.2
    m.audio.observeField("state", m.port)
    m.audio.observeField("position", m.port)
    m.top.observeField("command", m.port)

    m.sock = invalid
    m.rx = CreateObject("roByteArray")
    m.connectedIp = ""
    m.servIp = ""          ' set when Lyrion tells us to switch servers
    m.retryAtJ = 0
    m.wasPlaying = false
    resetPlayback()

    while true
        now = jiffies()
        if m.sock = invalid and now >= m.retryAtJ then connect()
        msg = wait(nextTimeout(jiffies()), m.port)
        if msg <> invalid then handleMessage(msg)
        runTimers()
    end while
end sub

function jiffies() as integer
    return m.clock.TotalMilliseconds()
end function

sub resetPlayback()
    m.mode = "stopped"
    m.cur = invalid
    m.pending = invalid
    m.pc = pcNew()
    m.sentD = false
    m.started = false
    m.startAtJ = -1
    m.resumeAtJ = -1
    m.underrunAtJ = -1
    m.playIssuedJ = -1
    m.learnLag = false
    m.lastBeatJ = 0
end sub

function isActive() as boolean
    return m.mode = "starting" or m.mode = "playing" or m.mode = "paused" or m.mode = "pausedFor"
end function

' ---- connection ----

sub connect()
    ip = m.servIp
    if ip = "" then ip = m.top.serverIp
    if ip = "" then
        setConnection("waiting for server")
        m.retryAtJ = jiffies() + 2000
        return
    end if
    setConnection("connecting to " + ip)
    addr = CreateObject("roSocketAddress")
    addr.SetAddress(ip + ":3483")
    s = CreateObject("roStreamSocket")
    s.setSendToAddress(addr)
    ' Connect before attaching the message port: with a port the socket is non-blocking, Connect()
    ' returns at once, and its status only updates as events are read, so polling never sees it connect.
    if not s.Connect() then
        s.Close()
        setConnection("can't reach Lyrion at " + ip + " port 3483")
        m.retryAtJ = jiffies() + 3000
        return
    end if
    s.setMessagePort(m.port)
    s.notifyReadable(true)
    m.sock = s
    m.connectedIp = ip
    m.rx = CreateObject("roByteArray")
    send(spHelo(spMacBytes(m.top.mac), spCaps(m.top.formats), m.wasPlaying))
    setConnection("connected")
end sub

sub disconnect(reason as string)
    if m.sock <> invalid then m.sock.Close()
    m.sock = invalid
    m.wasPlaying = (m.mode = "playing")
    setConnection(reason)
    m.retryAtJ = jiffies() + 3000
end sub

sub setConnection(text as string)
    if m.top.connection <> text then
        print "[squeeze] connection: "; text
        m.top.connection = text
    end if
end sub

sub send(pkt as object)
    if m.sock = invalid then return
    ' The socket is non-blocking once connected, so a full send buffer means "try again", not an error.
    done = 0
    tries = 0
    while done < pkt.Count()
        n = m.sock.send(pkt, done, pkt.Count() - done)
        if n > 0 then
            done = done + n
        else if m.sock.eWouldBlock() and tries < 50 then
            tries = tries + 1
            sleep(10)
        else
            disconnect("connection lost")
            return
        end if
    end while
end sub

' ---- message loop ----

function nextTimeout(now as integer) as integer
    t = 1000
    for each at in [m.startAtJ, m.resumeAtJ, m.underrunAtJ]
        if at >= 0 and at - now < t then t = at - now
    end for
    if m.sock <> invalid and isActive() and m.lastBeatJ + 1000 - now < t then t = m.lastBeatJ + 1000 - now
    if m.sock = invalid and m.retryAtJ - now < t then t = m.retryAtJ - now
    if t < 1 then t = 1
    return t
end function

sub handleMessage(msg as object)
    t = type(msg)
    if t = "roSocketEvent" then
        if m.sock <> invalid and msg.getSocketID() = m.sock.getID() then readSocket()
    else if t = "roSGNodeEvent" then
        f = msg.getField()
        if f = "state" then
            onAudioState(msg.getData())
        else if f = "position" then
            onPosition(msg.getData())
        else if f = "command" then
            onCommand(msg.getData())
        end if
    end if
end sub

sub runTimers()
    now = jiffies()
    if m.startAtJ >= 0 and now >= m.startAtJ then playNow()
    if m.resumeAtJ >= 0 and now >= m.resumeAtJ then resumeNow()
    if m.underrunAtJ >= 0 and now >= m.underrunAtJ then endPlayback()
    if m.sock <> invalid and isActive() and now - m.lastBeatJ >= 1000 then
        m.lastBeatJ = now
        sendStat("STMt", 0)
    end if
end sub

sub onCommand(cmd as string)
    if cmd = "reconnect" then
        m.servIp = ""
        disconnect("reconnecting")
        m.retryAtJ = 0
    else if cmd = "stop" then
        stopAudio()
    end if
end sub

sub readSocket()
    if not m.sock.isReadable() then return
    buf = CreateObject("roByteArray")
    buf[8191] = 0
    n = m.sock.receive(buf, 0, 8192)
    if n = 0 then
        disconnect("Lyrion closed the connection")
        return
    end if
    if n < 0 then
        if not m.sock.eWouldBlock() then disconnect("connection lost")
        return
    end if
    for i = 0 to n - 1
        m.rx.Push(buf[i])
    end for
    r = spTakeFrames(m.rx)
    m.rx = r.rest
    for each f in r.frames
        handleFrame(f.cmd, f.data)
    end for
end sub

sub handleFrame(cmd as string, d as object)
    if cmd = "strm" then
        onStrm(spParseStrm(d))
    else if cmd = "aude" then
        ' both outputs off means the player was switched off
        if d.Count() >= 2 and d[0] = 0 and d[1] = 0 then stopAudio()
    else if cmd = "setd" then
        onSetd(d)
    else if cmd = "serv" then
        if d.Count() >= 4 then
            m.servIp = d[0].ToStr() + "." + d[1].ToStr() + "." + d[2].ToStr() + "." + d[3].ToStr()
            disconnect("switching server")
            m.retryAtJ = 0
        end if
    end if
    ' audg (volume) is ignored: a Roku app can't change the TV's volume. vers and display commands don't apply.
end sub

sub onSetd(d as object)
    if d.Count() = 0 or d[0] <> 0 then return
    if d.Count() = 1 then
        send(spSetdName(m.top.playerName))
    else
        m.top.reportedName = spText(d, 1, d.Count())
    end if
end sub

' ---- strm commands ----

sub onStrm(s as object)
    c = s.command
    if c <> "t" then print "[squeeze] strm "; c; " autostart="; s.autostart; " interval="; s.interval
    if c = "t" then
        sendStat("STMt", s.interval)
    else if c = "s" then
        onStart(s)
    else if c = "p" then
        onPause(s.interval)
    else if c = "u" then
        onUnpause(s.interval)
    else if c = "q" or c = "f" then
        stopAudio()
        sendStat("STMf", 0)
    else if c = "a" then
        onSkip(s.interval)
    end if
end sub

sub onStart(s as object)
    t = { url: spStreamUrl(s, m.connectedIp), format: spStreamFormat(s.format), autostart: s.autostart }
    ' A new track while this one still plays after decoder-ready: queue it. (STMd is only sent once
    ' a track has finished, so this is a safety net rather than the normal path.)
    if isActive() and m.sentD then
        m.pending = t
        return
    end if
    loadTrack(t)
end sub

sub loadTrack(t as object)
    m.cur = t
    m.pending = invalid
    m.pc = pcNew()
    m.sentD = false
    m.started = false
    m.startAtJ = -1
    m.resumeAtJ = -1
    m.underrunAtJ = -1
    c = CreateObject("roSGNode", "ContentNode")
    c.url = t.url
    print "[squeeze] load "; t.url; " format="; t.format
    if t.format <> "" then c.streamFormat = t.format
    m.audio.control = "stop"
    m.audio.content = c
    sendStat("STMc", 0)
    if t.autostart = "0" or t.autostart = "2" then
        ' Lyrion holds the start until every member says its buffer is ready. The Audio node can't
        ' buffer without playing, so we say ready now and press play at Lyrion's start time, which
        ' it has already moved earlier by our startDelay.
        m.mode = "waitStart"
        sendStat("STMl", 0)
    else
        playNow()
    end if
end sub

sub playNow()
    m.startAtJ = -1
    m.audio.control = "play"
    m.mode = "starting"
    m.playIssuedJ = jiffies()
    m.learnLag = true
end sub

sub onUnpause(at as integer)
    now = jiffies()
    if m.mode = "waitStart" then
        if at = 0 then
            playNow()
        else
            m.startAtJ = at
            if m.startAtJ <= now then playNow()
        end if
    else if m.mode = "paused" or m.mode = "pausedFor" then
        if at = 0 then
            resumeNow()
        else
            m.resumeAtJ = at
            if m.resumeAtJ <= now then resumeNow()
        end if
    end if
    sendStat("STMr", 0)
end sub

sub resumeNow()
    m.resumeAtJ = -1
    if not m.started then
        ' paused before it ever started (e.g. while waiting for a sync start)
        playNow()
        return
    end if
    m.audio.control = "resume"
    pcThaw(m.pc, jiffies())
    m.mode = "playing"
end sub

sub onPause(interval as integer)
    if interval > 0 then
        ' sync correction: we're ahead, so hold for the interval and carry on
        if m.mode <> "playing" then return
        m.audio.control = "pause"
        pcFreeze(m.pc, jiffies())
        m.mode = "pausedFor"
        m.resumeAtJ = jiffies() + interval
        return
    end if
    if m.mode = "waitStart" then m.startAtJ = -1
    if isActive() or m.mode = "waitStart" then
        m.audio.control = "pause"
        pcFreeze(m.pc, jiffies())
        m.mode = "paused"
        m.resumeAtJ = -1
    end if
    sendStat("STMp", 0)
end sub

sub onSkip(ms as integer)
    ' sync correction: we're behind by ms.
    if m.mode <> "playing" or ms <= 0 then return
    how = m.top.catchUp
    if how = "seek" then
        ' Whether the Audio node can seek forward in a Lyrion stream is unproven, so this is opt-in.
        m.audio.seek = m.audio.position + ms / 1000.0
        pcSkip(m.pc, ms)
    else if how = "resync" then
        m.top.behindMs = ms
    end if
end sub

sub stopAudio()
    if m.cur <> invalid or m.mode <> "stopped" then m.audio.control = "stop"
    resetPlayback()
end sub

sub endPlayback()
    m.underrunAtJ = -1
    sendStat("STMu", 0)
    stopAudio()
end sub

' ---- Audio node events ----

sub onAudioState(state as string)
    print "[squeeze] audio state: "; state; " mode="; m.mode
    if m.cur = invalid then return
    if state = "playing" then
        if m.mode = "starting" then m.mode = "playing"
        if not m.started then
            m.started = true
            sendStat("STMs", 0)
        end if
    else if state = "finished" then
        if m.pending <> invalid then
            loadTrack(m.pending)
        else if not m.sentD then
            m.sentD = true
            m.mode = "ending"
            sendStat("STMd", 0)
            m.underrunAtJ = jiffies() + 2500
        else
            endPlayback()
        end if
    else if state = "error" then
        m.top.lastError = m.audio.errorMsg
        print "[squeeze] audio error: "; m.audio.errorMsg
        stopAudio()
        sendStat("STMn", 0)
    end if
end sub

sub onPosition(posSec as dynamic)
    if m.mode <> "playing" then return
    posMs = Int(posSec * 1000)
    if posMs <= 0 then return
    now = jiffies()
    pcFix(m.pc, now, posMs)
    if m.learnLag then
        m.learnLag = false
        m.top.startLag = pcLearnLag(m.top.startLag, m.pc.startJ - m.playIssuedJ)
    end if
    ' Decoder-ready (STMd) waits until the track has finished: sent while Lyrion is still streaming
    ' the track to us, it makes Lyrion drop that stream and move on to the next track.
end sub

' ---- STAT ----

sub sendStat(ev as string, serverTs as integer)
    if m.sock = invalid then return
    now = jiffies()
    el = 0
    if m.cur <> invalid then el = pcElapsed(m.pc, now)
    full = 0
    if isActive() then full = 1048576
    s = {
        bufSize: 2097152,
        bufFull: full,
        bytes: el * 16,       ' no byte count from the Audio node; a 128 kbit/s estimate
        jiffies: now,
        outSize: 3528000,
        outFull: 0,           ' 0 keeps Lyrion from adding an output-buffer offset to our time
        elapsedMs: el,
        serverTs: serverTs
    }
    send(spStat(ev, s))
end sub
