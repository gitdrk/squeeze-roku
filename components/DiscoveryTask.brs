sub init()
    m.top.functionName = "runTask"
end sub

sub runTask()
    port = CreateObject("roMessagePort")
    sock = CreateObject("roDatagramSocket")
    sock.setMessagePort(port)
    sock.setBroadcast(true)
    sock.notifyReadable(true)
    addr = CreateObject("roSocketAddress")
    addr.SetAddress(m.top.target + ":3483")
    sock.setSendToAddress(addr)
    pkt = spDiscoveryPacket()
    found = []
    seen = {}

    for attempt = 1 to 3
        sock.send(pkt, 0, pkt.Count())
        timer = CreateObject("roTimespan")
        while timer.TotalMilliseconds() < 1500
            left = 1500 - timer.TotalMilliseconds()
            if left < 1 then exit while
            msg = wait(left, port)
            if type(msg) = "roSocketEvent" and sock.isReadable() then
                buf = CreateObject("roByteArray")
                buf[1499] = 0
                n = sock.receive(buf, 0, 1500)
                info = invalid
                if n > 0 then info = spParseDiscovery(buf, n)
                if info <> invalid then
                    ip = ""
                    if info.DoesExist("IPAD") then ip = info.IPAD
                    if ip = "" then ip = sock.getReceivedFromAddress().getAddress().Split(":")[0]
                    if not seen.DoesExist(ip) then
                        seen[ip] = true
                        name = "Lyrion"
                        if info.DoesExist("NAME") then name = info.NAME
                        json = "9000"
                        if info.DoesExist("JSON") then json = info.JSON
                        found.Push({ ip: ip, name: name, json: json })
                    end if
                end if
            end if
        end while
        if found.Count() > 0 then exit for
    end for

    sock.Close()
    m.top.servers = found
    m.top.done = true
end sub
