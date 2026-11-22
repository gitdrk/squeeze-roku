' Off-device tests for source/Proto.brs. Run with: npm test
' Each check prints a line; the last line says how many failed.

sub Main()
    m.fails = 0
    m.count = 0
    testIntegers()
    testHelo()
    testStat()
    testSetd()
    testFrames()
    testStrm()
    testStreamUrl()
    testDiscovery()
    testClock()
    print ""
    print m.count.ToStr() + " checks, " + m.fails.ToStr() + " failed"
    if m.fails > 0 then print "FAIL" else print "PASS"
end sub

sub check(name as string, got as dynamic, want as dynamic)
    m.count = m.count + 1
    if got = want then
        print "ok   " + name
    else
        m.fails = m.fails + 1
        print "FAIL " + name + ": got " + toText(got) + ", want " + toText(want)
    end if
end sub

function toText(v as dynamic) as string
    if v = invalid then return "invalid"
    if type(v) = "roString" or type(v) = "String" then return Chr(34) + v + Chr(34)
    if type(v) = "roBoolean" or type(v) = "Boolean" then
        if v then return "true" else return "false"
    end if
    return v.ToStr()
end function

function bytes(list as object) as object
    b = CreateObject("roByteArray")
    for each x in list
        b.Push(x)
    end for
    return b
end function

sub pushStr(b as object, s as string)
    spPushText(b, s)
end sub

' Builds a server -> player frame.
function frame(cmd as string, data as object) as object
    f = CreateObject("roByteArray")
    spPushU16(f, data.Count() + 4)
    spPushText(f, cmd)
    for i = 0 to data.Count() - 1
        f.Push(data[i])
    end for
    return f
end function

function strmData(command as string, autostart as string, fmt as string, interval as integer, port as integer, ip as object, header as string) as object
    d = CreateObject("roByteArray")
    pushStr(d, command)
    pushStr(d, autostart)
    pushStr(d, fmt)
    pushStr(d, "????")       ' pcm size, rate, channels, endianness
    d.Push(255)              ' threshold
    d.Push(0)                ' spdif
    d.Push(0)                ' transition period
    pushStr(d, "0")          ' transition type
    d.Push(0)                ' flags
    d.Push(0)                ' output threshold
    d.Push(0)                ' reserved
    spPushU32(d, interval)
    spPushU16(d, port)
    for each x in ip
        d.Push(x)
    end for
    pushStr(d, header)
    return d
end function

sub testIntegers()
    b = CreateObject("roByteArray")
    spPushU32(b, 123456789)
    check("u32 round trip", spU32(b, 0), 123456789)
    b = CreateObject("roByteArray")
    big = (&hEE << 24) or &h6B2800  ' 4000000000 as signed bits
    spPushU32(b, big)
    check("u32 high bit, first byte", b[0], &hEE)
    check("u32 high bit, round trip", spU32(b, 0), big)
    b = CreateObject("roByteArray")
    spPushU16(b, 9000)
    check("u16 round trip", spU16(b, 0), 9000)
    mac = spMacBytes("02:ab:cd:ef:01:9f")
    check("mac bytes count", mac.Count(), 6)
    check("mac byte 2", mac[1], 171)
    check("mac byte 6", mac[5], 159)
end sub

sub testHelo()
    caps = spCaps("flc,mp3")
    p = spHelo(spMacBytes("02:11:22:33:44:55"), caps, false)
    check("HELO opcode", spText(p, 0, 4), "HELO")
    check("HELO length field", spU32(p, 4), 36 + Len(caps))
    check("HELO packet size", p.Count(), 8 + 36 + Len(caps))
    check("HELO device id", p[8], 12)
    check("HELO mac first", p[10], 2)
    check("HELO mac last", p[15], &h55)
    check("HELO reconnect flag off", spU16(p, 32), 0)
    check("HELO language", spText(p, 42, 44), "en")
    check("HELO caps", spText(p, 44, p.Count()), caps)
    p = spHelo(spMacBytes("02:11:22:33:44:55"), caps, true)
    check("HELO reconnect flag on", spU16(p, 32), &h4000)
end sub

sub testStat()
    s = { bufSize: 2097152, bufFull: 1048576, bytes: 4096, jiffies: 777777, outSize: 3528000, outFull: 0, elapsedMs: 61234, serverTs: 0 }
    s.serverTs = (&hF0 << 24) or 5
    p = spStat("STMt", s)
    check("STAT payload is 53 bytes", spU32(p, 4), 53)
    check("STAT event", spText(p, 8, 12), "STMt")
    d = 8  ' payload offset
    check("STAT buffer size", spU32(p, d + 7), 2097152)
    check("STAT bytes received", spU32(p, d + 19), 4096)
    check("STAT jiffies", spU32(p, d + 25), 777777)
    check("STAT elapsed seconds", spU32(p, d + 37), 61)
    check("STAT elapsed ms", spU32(p, d + 43), 61234)
    check("STAT echoes server timestamp", spU32(p, d + 47), s.serverTs)
end sub

sub testSetd()
    p = spSetdName("Living Room")
    check("SETD opcode", spText(p, 0, 4), "SETD")
    check("SETD id", p[8], 0)
    check("SETD name", spText(p, 9, p.Count()), "Living Room")
    check("SETD ends in NUL", p[p.Count() - 1], 0)
end sub

sub testFrames()
    a = frame("vers", bytes([55, 46, 57]))
    b = frame("audg", bytes([1, 2, 3, 4]))
    rx = CreateObject("roByteArray")
    for i = 0 to a.Count() - 1
        rx.Push(a[i])
    end for
    for i = 0 to 4
        rx.Push(b[i])  ' only part of the second frame
    end for
    r = spTakeFrames(rx)
    check("frames: one complete", r.frames.Count(), 1)
    check("frames: command", r.frames[0].cmd, "vers")
    check("frames: payload", r.frames[0].data.ToAsciiString(), "7.9")
    check("frames: partial kept", r.rest.Count(), 5)
    for i = 5 to b.Count() - 1
        r.rest.Push(b[i])
    end for
    r2 = spTakeFrames(r.rest)
    check("frames: second completes", r2.frames.Count(), 1)
    check("frames: second command", r2.frames[0].cmd, "audg")
    check("frames: second payload size", r2.frames[0].data.Count(), 4)
    check("frames: nothing left", r2.rest.Count(), 0)
end sub

sub testStrm()
    crlf = Chr(13) + Chr(10)
    hdr = "GET /stream.mp3?player=02:aa:bb:cc:dd:ee HTTP/1.0" + crlf + crlf
    s = spParseStrm(strmData("s", "1", "f", 0, 9000, [0, 0, 0, 0], hdr))
    check("strm command", s.command, "s")
    check("strm autostart", s.autostart, "1")
    check("strm format", spStreamFormat(s.format), "flac")
    check("strm port", s.port, 9000)
    check("strm ip", s.ip, "0.0.0.0")
    check("strm header", s.header, hdr)
    u = spParseStrm(strmData("u", "0", "?", 123456, 0, [0, 0, 0, 0], ""))
    check("strm u start time", u.interval, 123456)
    t = spParseStrm(strmData("t", "0", "?", (&hC0 << 24) or 77, 0, [0, 0, 0, 0], ""))
    check("strm t timestamp keeps high bit", t.interval, (&hC0 << 24) or 77)
    short = spParseStrm(bytes([Asc("q")]))
    check("strm short packet still gives command", short.command, "q")
end sub

sub testStreamUrl()
    crlf = Chr(13) + Chr(10)
    s = spParseStrm(strmData("s", "1", "m", 0, 9000, [0, 0, 0, 0], "GET /stream.mp3?player=02:aa HTTP/1.0" + crlf + crlf))
    check("url from control server", spStreamUrl(s, "192.168.1.5"), "http://192.168.1.5:9000/stream.mp3?player=02:aa")
    s = spParseStrm(strmData("s", "1", "m", 0, 9000, [10, 0, 0, 7], "GET /stream.mp3?player=02:aa HTTP/1.0" + crlf + crlf))
    check("url from given ip", spStreamUrl(s, "192.168.1.5"), "http://10.0.0.7:9000/stream.mp3?player=02:aa")
    hdr = "GET /live/radio.mp3 HTTP/1.0" + crlf + "Host: radio.example.org:8000" + crlf + "Icy-MetaData: 1" + crlf + crlf
    s = spParseStrm(strmData("s", "3", "m", 0, 8000, [93, 184, 216, 34], hdr))
    check("direct stream uses Host header", spStreamUrl(s, "192.168.1.5"), "http://radio.example.org:8000/live/radio.mp3")
    s = spParseStrm(strmData("s", "1", "m", 0, 80, [10, 0, 0, 7], "GET /a.mp3 HTTP/1.0" + crlf + crlf))
    check("port 80 left off", spStreamUrl(s, "x"), "http://10.0.0.7/a.mp3")
    check("format mp3", spStreamFormat("m"), "mp3")
    check("format aac", spStreamFormat("a"), "aac")
    check("format unknown", spStreamFormat("p"), "")
end sub

sub testDiscovery()
    p = spDiscoveryPacket()
    check("discovery starts with e", Chr(p[0]), "e")
    check("discovery size", p.Count(), 21)
    r = CreateObject("roByteArray")
    pushStr(r, "E")
    pushStr(r, "NAME") : r.Push(6) : pushStr(r, "Lyrion")
    pushStr(r, "JSON") : r.Push(4) : pushStr(r, "9000")
    pushStr(r, "IPAD") : r.Push(11) : pushStr(r, "192.168.1.5")
    info = spParseDiscovery(r, r.Count())
    check("discovery name", info.NAME, "Lyrion")
    check("discovery json port", info.JSON, "9000")
    check("discovery ip", info.IPAD, "192.168.1.5")
    check("discovery ignores other packets", spParseDiscovery(bytes([Asc("x")]), 1), invalid)
end sub

sub testClock()
    pc = pcNew()
    check("clock empty elapsed", pcElapsed(pc, 5000), 0)
    pcFix(pc, 10200, 200)
    check("clock first fix anchors", pc.startJ, 10000)
    check("clock elapsed", pcElapsed(pc, 11000), 1000)
    pcFix(pc, 10450, 400)  ' report says start was 10050: small jitter, moved 20%
    check("clock smooths jitter", pc.startJ, 10010)
    pcFix(pc, 20000, 5000)  ' 5 s jump: re-anchor at once
    check("clock re-anchors on a jump", pc.startJ, 15000)
    pcFreeze(pc, 16000)
    check("clock frozen while paused", pcElapsed(pc, 19000), 1000)
    pcFix(pc, 19000, 9999)
    check("clock ignores reports while frozen", pcElapsed(pc, 19000), 1000)
    pcThaw(pc, 20000)
    check("clock resumes where it paused", pcElapsed(pc, 20500), 1500)
    pcSkip(pc, 120)
    check("clock skip ahead", pcElapsed(pc, 20500), 1620)
    check("lag learns slowly", pcLearnLag(400, 600), 460)
    check("lag ignores nonsense", pcLearnLag(400, 9000), 400)
end sub
