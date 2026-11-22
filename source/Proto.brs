' SlimProto packets, server discovery and the play clock.
' Nothing in this file touches SceneGraph, so tests/proto_test.brs runs it off-device with brs.
'
' Wire format, from the Lyrion server's point of view:
'   player -> server: 4-byte opcode, 4-byte big-endian length, payload
'   server -> player: 2-byte big-endian length (covers opcode + payload), 4-byte opcode, payload
' 32-bit fields are held in BrightScript's signed Integer. Bit operations keep the bits intact,
' so values above 2^31 (server timestamps) come back out exactly as they went in.

function spVersion() as string
    return "0.1.0"
end function

' ---- byte helpers ----

function spU16(ba as object, off as integer) as integer
    return (ba[off] << 8) or ba[off + 1]
end function

function spU32(ba as object, off as integer) as integer
    return (ba[off] << 24) or (ba[off + 1] << 16) or (ba[off + 2] << 8) or ba[off + 3]
end function

sub spPushU16(ba as object, v as integer)
    ba.Push((v >> 8) and 255)
    ba.Push(v and 255)
end sub

sub spPushU32(ba as object, v as integer)
    ba.Push((v >> 24) and 255)
    ba.Push((v >> 16) and 255)
    ba.Push((v >> 8) and 255)
    ba.Push(v and 255)
end sub

' Appends the UTF-8 bytes of a string.
sub spPushText(ba as object, s as string)
    tmp = CreateObject("roByteArray")
    tmp.FromAsciiString(s)
    for i = 0 to tmp.Count() - 1
        ba.Push(tmp[i])
    end for
end sub

' Bytes [first, last) as a string, skipping NULs.
function spText(ba as object, first as integer, last as integer) as string
    tmp = CreateObject("roByteArray")
    for i = first to last - 1
        if ba[i] <> 0 then tmp.Push(ba[i])
    end for
    return tmp.ToAsciiString()
end function

function spMacBytes(mac as string) as object
    out = []
    for each part in mac.Split(":")
        out.Push(Val(part, 16))
    end for
    while out.Count() < 6
        out.Push(0)
    end while
    return out
end function

function spPacket(op as string, data as object) as object
    p = CreateObject("roByteArray")
    spPushText(p, op)
    spPushU32(p, data.Count())
    for i = 0 to data.Count() - 1
        p.Push(data[i])
    end for
    return p
end function

' ---- player -> server ----

' Capabilities sent in HELO. "formats" is the comma list Lyrion may stream to us, e.g. "flc,mp3".
function spCaps(formats as string) as string
    return "Model=squeezelite,ModelName=Roku SqueezePlayer,Firmware=" + spVersion() + ",MaxSampleRate=48000," + formats
end function

function spHelo(mac as object, caps as string, reconnect as boolean) as object
    d = CreateObject("roByteArray")
    d.Push(12)  ' device id 12: the SqueezePlay family, which squeezelite also reports
    d.Push(0)   ' revision
    for each b in mac
        d.Push(b)
    end for
    for i = 1 to 16
        d.Push(0)  ' uuid, unused
    end for
    if reconnect then spPushU16(d, &h4000) else spPushU16(d, 0)
    spPushU32(d, 0)  ' bytes received, high word
    spPushU32(d, 0)  ' bytes received, low word
    spPushText(d, "en")
    spPushText(d, caps)
    return spPacket("HELO", d)
end function

' s: {bufSize, bufFull, bytes, jiffies, outSize, outFull, elapsedMs, serverTs}
function spStat(ev as string, s as object) as object
    d = CreateObject("roByteArray")
    spPushText(d, ev)
    d.Push(0)  ' num_crlf
    d.Push(0)  ' mas_initialized
    d.Push(0)  ' mas_mode
    spPushU32(d, s.bufSize)
    spPushU32(d, s.bufFull)
    spPushU32(d, 0)        ' bytes received, high word
    spPushU32(d, s.bytes)  ' bytes received, low word
    spPushU16(d, &hFFFF)   ' signal strength: wired
    spPushU32(d, s.jiffies)
    spPushU32(d, s.outSize)
    spPushU32(d, s.outFull)
    spPushU32(d, s.elapsedMs \ 1000)
    spPushU16(d, 0)        ' voltage
    spPushU32(d, s.elapsedMs)
    spPushU32(d, s.serverTs)
    spPushU16(d, 0)        ' error code
    return spPacket("STAT", d)
end function

function spSetdName(name as string) as object
    d = CreateObject("roByteArray")
    d.Push(0)  ' setting id 0: player name
    spPushText(d, name)
    d.Push(0)
    return spPacket("SETD", d)
end function

' ---- server -> player ----

' Pulls every complete frame off the front of rx.
' Returns {frames: [{cmd, data}], rest: roByteArray of leftover bytes}.
function spTakeFrames(rx as object) as object
    frames = []
    i = 0
    n = rx.Count()
    while n - i >= 2
        size = spU16(rx, i)
        if n - i - 2 < size then exit while
        if size >= 4 then
            cmd = Chr(rx[i + 2]) + Chr(rx[i + 3]) + Chr(rx[i + 4]) + Chr(rx[i + 5])
            data = CreateObject("roByteArray")
            for k = i + 6 to i + 1 + size
                data.Push(rx[k])
            end for
            frames.Push({ cmd: cmd, data: data })
        end if
        i = i + 2 + size
    end while
    rest = CreateObject("roByteArray")
    for k = i to n - 1
        rest.Push(rx[k])
    end for
    return { frames: frames, rest: rest }
end function

' strm payload: 24 fixed bytes, then the HTTP request the player should send.
function spParseStrm(d as object) as object
    s = { command: "", autostart: "0", format: "", interval: 0, port: 0, ip: "0.0.0.0", header: "" }
    if d.Count() < 24 then
        if d.Count() > 0 then s.command = Chr(d[0])
        return s
    end if
    s.command = Chr(d[0])
    s.autostart = Chr(d[1])
    s.format = Chr(d[2])
    s.threshold = d[7]
    s.flags = d[11]
    ' Lyrion reuses the replay-gain field: start time for 'u', interval for 'p' and 'a', timestamp for 't'.
    s.interval = spU32(d, 14)
    s.port = spU16(d, 18)
    s.ip = d[20].ToStr() + "." + d[21].ToStr() + "." + d[22].ToStr() + "." + d[23].ToStr()
    s.header = spText(d, 24, d.Count())
    return s
end function

' The URL the Audio node should fetch. Server IP 0 means "the server you're connected to".
' A Host header (sent for direct streams from the internet) wins over the IP.
function spStreamUrl(s as object, controlIp as string) as string
    ip = s.ip
    if ip = "0.0.0.0" then ip = controlIp
    crlf = Chr(13) + Chr(10)
    hdr = s.header
    lineEnd = Instr(1, hdr, crlf)
    first = hdr
    if lineEnd > 0 then first = Left(hdr, lineEnd - 1)
    path = "/"
    sp1 = Instr(1, first, " ")
    if sp1 > 0 then
        rest = Mid(first, sp1 + 1)
        sp2 = Instr(1, rest, " ")
        if sp2 > 0 then path = Left(rest, sp2 - 1) else path = rest
    end if
    host = ""
    if lineEnd > 0 then
        at = lineEnd + 2
        while at <= Len(hdr)
            e = Instr(at, hdr, crlf)
            if e = 0 then e = Len(hdr) + 1
            line = Mid(hdr, at, e - at)
            if LCase(Left(line, 5)) = "host:" then host = Mid(line, 6).Trim()
            at = e + 2
        end while
    end if
    if host = "" then
        host = ip
        if s.port <> 80 then host = host + ":" + s.port.ToStr()
    end if
    return "http://" + host + path
end function

function spStreamFormat(c as string) as string
    if c = "f" then return "flac"
    if c = "m" then return "mp3"
    if c = "a" then return "aac"
    return ""
end function

' ---- discovery (UDP 3483 broadcast) ----

function spDiscoveryPacket() as object
    p = CreateObject("roByteArray")
    spPushText(p, "e")
    for each tag in ["IPAD", "NAME", "JSON", "VERS"]
        spPushText(p, tag)
        p.Push(0)
    end for
    return p
end function

' Reply: 'E', then tag (4 bytes), length (1 byte), value. Returns invalid if it isn't a reply.
function spParseDiscovery(ba as object, n as integer) as object
    if n < 1 then return invalid
    if ba[0] <> Asc("E") then return invalid
    out = {}
    i = 1
    while i + 5 <= n
        tag = Chr(ba[i]) + Chr(ba[i + 1]) + Chr(ba[i + 2]) + Chr(ba[i + 3])
        size = ba[i + 4]
        if i + 5 + size > n then exit while
        out[tag] = spText(ba, i + 5, i + 5 + size)
        i = i + 5 + size
    end while
    return out
end function

' ---- play clock ----
' Tracks when the current track's sample 0 played, in jiffies. The Audio node's position only
' updates a few times a second and jitters, so small differences are folded in slowly and only
' a big jump (a stall or a seek) re-anchors the clock at once.

function pcNew() as object
    return { startJ: invalid, frozen: invalid }
end function

sub pcFix(pc as object, nowJ as integer, posMs as integer)
    if pc.frozen <> invalid then return
    est = nowJ - posMs
    if pc.startJ = invalid then
        pc.startJ = est
        return
    end if
    diff = est - pc.startJ
    if Abs(diff) > 250 then
        pc.startJ = est
    else
        pc.startJ = pc.startJ + Int(diff * 0.2)
    end if
end sub

function pcElapsed(pc as object, nowJ as integer) as integer
    if pc.frozen <> invalid then return pc.frozen
    if pc.startJ = invalid then return 0
    e = nowJ - pc.startJ
    if e < 0 then return 0
    return e
end function

sub pcFreeze(pc as object, nowJ as integer)
    if pc.frozen = invalid then pc.frozen = pcElapsed(pc, nowJ)
end sub

sub pcThaw(pc as object, nowJ as integer)
    if pc.frozen = invalid then return
    if pc.startJ <> invalid then pc.startJ = nowJ - pc.frozen
    pc.frozen = invalid
end sub

sub pcSkip(pc as object, ms as integer)
    if pc.startJ <> invalid then pc.startJ = pc.startJ - ms
    if pc.frozen <> invalid then pc.frozen = pc.frozen + ms
end sub

' New start-lag estimate: a slow moving average, ignoring readings that can't be real.
function pcLearnLag(oldLag as integer, measured as integer) as integer
    if measured <= 0 or measured > 5000 then return oldLag
    return Int(oldLag * 0.7 + measured * 0.3 + 0.5)
end function
