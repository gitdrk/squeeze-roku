' Settings kept in the Roku registry, which survives app restarts and updates.

function loadSettings() as object
    sec = CreateObject("roRegistrySection", "SqueezeRoku")
    cfg = {}
    cfg.mac = sec.Read("mac")
    if cfg.mac = "" then
        cfg.mac = makeMac()
        sec.Write("mac", cfg.mac)
        sec.Flush()
    end if
    cfg.serverIp = sec.Read("serverIp")
    cfg.name = sec.Read("name")
    if cfg.name = "" then cfg.name = defaultName()
    cfg.delay = readInt(sec, "delay", 0)
    cfg.formats = sec.Read("formats")
    if cfg.formats = "" then cfg.formats = "flc,mp3"
    cfg.catchUp = sec.Read("catchUp")
    if cfg.catchUp = "" then cfg.catchUp = "resync"
    cfg.tolerance = readInt(sec, "tolerance", 40)
    cfg.startLag = readInt(sec, "startLag", 400)
    return cfg
end function

sub saveSetting(key as string, value as string)
    sec = CreateObject("roRegistrySection", "SqueezeRoku")
    sec.Write(key, value)
    sec.Flush()
end sub

function readInt(sec as object, key as string, fallback as integer) as integer
    v = sec.Read(key)
    if v = "" then return fallback
    return Int(Val(v))
end function

' A stable, locally administered MAC address made from this device's channel client id.
' Lyrion knows players by MAC, so it must not change between runs.
function makeMac() as string
    di = CreateObject("roDeviceInfo")
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(di.GetChannelClientId())
    d = CreateObject("roEVPDigest")
    d.Setup("md5")
    h = LCase(d.Process(ba))
    mac = "02"
    for i = 0 to 4
        mac = mac + ":" + Mid(h, i * 2 + 1, 2)
    end for
    return mac
end function

function defaultName() as string
    di = CreateObject("roDeviceInfo")
    n = di.GetFriendlyName()
    if n = invalid or n = "" then n = "Roku TV"
    return n
end function

' Stream format choices, in the order the settings menu cycles through them.
function formatChoices() as object
    return [
        { value: "flc,mp3", label: "FLAC, MP3 fallback" },
        { value: "mp3", label: "MP3 only" },
        { value: "flc,mp3,aac", label: "FLAC, MP3 and AAC" }
    ]
end function


' What to do when Lyrion says this TV is behind the group.
function catchUpChoices() as object
    return [
        { value: "resync", label: "restart the group in step" },
        { value: "seek", label: "seek ahead (experimental)" },
        { value: "off", label: "do nothing" }
    ]
end function

' Sync tolerance in ms: Lyrion only corrects this TV when it is further out than this.
function toleranceChoices() as object
    return [20, 40, 80, 150]
end function

function choiceLabel(list as object, value as string) as string
    for each c in list
        if c.value = value then return c.label
    end for
    return value
end function

function nextChoice(list as object, value as string) as string
    for i = 0 to list.Count() - 1
        if list[i].value = value then return list[(i + 1) mod list.Count()].value
    end for
    return list[0].value
end function

function nextTolerance(value as integer) as integer
    list = toleranceChoices()
    for i = 0 to list.Count() - 1
        if list[i] = value then return list[(i + 1) mod list.Count()]
    end for
    return list[1]
end function
