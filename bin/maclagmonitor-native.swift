import Foundation
import SQLite3
import Dispatch
import CoreGraphics
import SystemConfiguration

typealias Row = [String: Any]
let null = NSNull()
let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let plainISO = ISO8601DateFormatter()
let calendar = Calendar.current
let legacyTimestamp: DateFormatter = {
    let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.dateFormat="yyyy-MM-dd'T'HH:mm:ssZ"; return f
}()
func stamp(_ t: Double) -> String { iso.string(from: Date(timeIntervalSince1970: t)) }
func number(_ x: Any?) -> Double? {
    if let n = x as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
    if let s = x as? String, let d = Double(s), d.isFinite { return d }
    return nil
}
func numeric(_ x: Double?) -> Any { if let x = x, x.isFinite { return x }; return null }
func str(_ x: Any?) -> String { x as? String ?? "" }
func time(_ x: Any?) -> Double? {
    if let n = number(x) { return n }
    guard let s = x as? String else { return nil }
    if let d = iso.date(from: s) ?? plainISO.date(from: s) { return d.timeIntervalSince1970 }
    return legacyTimestamp.date(from:s)?.timeIntervalSince1970
}
struct QueryError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func readText(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func files(_ dir: URL) -> [URL] { (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [] }
func writeJSON(_ value: Any, pretty: Bool = false) throws {
    let bytes = try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data([10]))
}
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data(("maclagmonitor: " + message + "\n").utf8)); exit(2) }
func displayState() -> String {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return "unknown" }
    if count == 0 { return "off" }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return "unknown" }
    return displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 } ? "on" : "off"
}
func waitForEvent(_ seconds: Double, memory: Int) -> Never {
    // Replaces the routine sleep child; no additional resident helper or periodic timer.
    let queue = DispatchQueue.main
    var pressure: DispatchSourceMemoryPressure?
    if memory == 1 || memory == 2 {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: memory == 1 ? [.critical] : [.normal], queue: queue)
        source.setEventHandler { exit(memory == 1 ? 10 : 12) }; source.resume(); pressure = source
    }
    let store = SCDynamicStoreCreate(nil, "MacLagMonitor" as CFString, { _, _, _ in exit(11) }, nil)
    if let store = store {
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
        if SCDynamicStoreSetNotificationKeys(store, keys, nil) {
            _ = SCDynamicStoreSetDispatchQueue(store, queue)
        }
    }
    // Keep sources alive until an event or the original sampling deadline.
    queue.asyncAfter(deadline: .now() + seconds) { _ = pressure; _ = store; exit(0) }
    dispatchMain()
}
struct Range {
    let start: Double; let end: Double
    var seconds: Double { end - start }
    func overlap(_ a: Double, _ b: Double) -> Double { max(0, min(end,b) - max(start,a)) }
    var json: Row { ["from": stamp(start), "to": stamp(end), "seconds": seconds] }
}
struct Options {
    let topic: String; let range: Range; let group: String?; let limit: Int; let json: Bool
    init(_ arguments: [String], now: Double = Date().timeIntervalSince1970) throws {
        guard let topic = arguments.first else { throw QueryError("query requires a topic; see help") }
        self.topic = topic
        var start: Double?, end: Double?, duration: Double?, group: String?, limit: Int?, json = false
        var i = 1
        while i < arguments.count {
            let key = arguments[i]; i += 1
            if key == "--json" { json = true; continue }
            guard i < arguments.count else { throw QueryError("missing value for " + key) }
            let v = arguments[i]; i += 1
            switch key {
            case "--last":
                guard v.count > 1, let n = Double(v.dropLast()), n.isFinite, n > 0,
                      let multiplier = ["s":1.0,"m":60,"h":3600,"d":86400][String(v.suffix(1))] else { throw QueryError("use --last 24h or --last 7d") }
                duration = n * multiplier
            case "--from": guard let d = time(v) else { throw QueryError("invalid --from; use ISO 8601 with timezone") }; start = d
            case "--to": guard let d = time(v) else { throw QueryError("invalid --to; use ISO 8601 with timezone") }; end = d
            case "--group-by": guard ["hour","day"].contains(v) else { throw QueryError("group must be hour or day") }; group = v
            case "--limit": guard let n = Int(v), n > 0 else { throw QueryError("limit must be positive") }; limit = n
            default: throw QueryError("unknown option " + key)
            }
        }
        guard duration == nil || (start == nil && end == nil) else { throw QueryError("use --last or --from/--to, not both") }
        let b = end ?? now, a = start ?? (b - (duration ?? (topic == "sources" ? 604800 : 86400)))
        guard a.isFinite, b.isFinite, a < b else { throw QueryError("invalid time range") }
        if group != nil && !["power","sleep","timeline"].contains(topic) { throw QueryError("--group-by is supported for power, sleep, timeline") }
        self.range = Range(start:a,end:b); self.group = group; self.limit = limit ?? (group == nil ? 20 : 100); self.json = json
    }
}
final class Database {
    let name: String; private var handle: OpaquePointer?
    init(_ url: URL, archived: Bool, name: String) throws {
        self.name = name
        // Archived files are closed SQLite snapshots. Never use immutable on the live DB.
        let p = archived ? url.absoluteString + "?immutable=1" : url.path
        let rc = sqlite3_open_v2(p, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle); handle = nil; throw QueryError(msg)
        }
    }
    deinit { sqlite3_close(handle) }
    func select(_ sql: String, _ args: [Double] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { throw QueryError(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(s) }
        for (i,v) in args.enumerated() { sqlite3_bind_double(s, Int32(i+1), v) }
        var result: [Row] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return result }
            guard rc == SQLITE_ROW else { throw QueryError(String(cString: sqlite3_errmsg(handle))) }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(s) {
                let key = String(cString: sqlite3_column_name(s,c))
                switch sqlite3_column_type(s,c) {
                case SQLITE_INTEGER: row[key] = sqlite3_column_int64(s,c)
                case SQLITE_FLOAT: row[key] = sqlite3_column_double(s,c)
                case SQLITE_TEXT: row[key] = sqlite3_column_text(s,c).map { String(cString:$0) } as Any? ?? null
                default: row[key] = null
                }
            }
            result.append(row)
        }
    }
    func columns(_ table: String) throws -> Set<String> {
        Set(try select("PRAGMA table_info(\"\(table)\")").map { str($0["name"]) })
    }
}
let powerTable = "PLBatteryAgent_EventBackward_Adapter"
let batteryTable = "PLBatteryAgent_EventBackward_Battery"
let sleepTable = "PLSleepWakeAgent_EventForward_PowerState"
let idleTable = "PLSleepWakeAgent_EventForward_UserIdle"
let cpuTable = "PLCoalitionAgent_EventInterval_CoalitionInterval"
let memoryTable = "PLPerformanceAgent_EventPoint_SystemMemory"
let networkTable = "PLProcessNetworkAgent_EventInterval_UsageDiff"
let dataTables = [powerTable,batteryTable,sleepTable,idleTable,cpuTable,memoryTable,networkTable]
struct Series {
    var rows: [Row] = []; var issues: [String] = []; var files: [String] = []
    var info: Row {
        let timestamps = rows.compactMap { number($0["timestamp"]) }
        let ends = rows.compactMap { number($0["timestampEnd"]) }
        return ["status": rows.isEmpty ? "unavailable" : issues.isEmpty ? "ok" : "partial",
                "rows": rows.count, "first_observed": timestamps.min().map(stamp) as Any? ?? null,
                "last_observed": (timestamps + ends).max().map(stamp) as Any? ?? null, "files":files, "issues":issues]
    }
}
final class PowerLog {
    let root: URL; let range: Range; private var dbs: [Database] = []; private var scratch: URL?; var issues: [String] = []
    init(root: URL, range: Range) {
        self.root = root; self.range = range
        let day = DateFormatter(); day.locale = Locale(identifier:"en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let first = day.string(from: Date(timeIntervalSince1970: range.start - 86400))
        let last = day.string(from: Date(timeIntervalSince1970: range.end + 86400))
        let archives = files(root.appendingPathComponent("Archives")).filter { u in
            let name = u.lastPathComponent
            guard name.hasSuffix(".PLSQL") || name.hasSuffix(".PLSQL.gz") else { return false }
            let d = String(name.dropFirst("powerlog_".count).prefix(10))
            return !name.hasPrefix("powerlog_") || d < "2000-01-01" || (d >= first && d <= last)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in archives + [root.appendingPathComponent("CurrentPowerlog.PLSQL")] {
            let archived = url.lastPathComponent != "CurrentPowerlog.PLSQL"
            do {
                var opened = url
                if url.pathExtension == "gz" {
                    if scratch == nil {
                        let s = fm.temporaryDirectory.appendingPathComponent("maclagmonitor-query-" + UUID().uuidString, isDirectory:true)
                        try fm.createDirectory(at:s, withIntermediateDirectories:false, attributes:[.posixPermissions:0o700])
                        scratch = s
                    }
                    opened = scratch!.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                    guard fm.createFile(atPath:opened.path, contents:nil, attributes:[.posixPermissions:0o600]) else { throw QueryError("temporary file creation failed") }
                    let out = try FileHandle(forWritingTo:opened)
                    defer { try? out.close() }
                    let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/gzip"); p.arguments = ["-dc",url.path]
                    p.standardOutput = out; p.standardError = FileHandle.nullDevice
                    try p.run(); p.waitUntilExit()
                    guard p.terminationStatus == 0 else { throw QueryError("archive decompression failed") }
                }
                dbs.append(try Database(opened, archived:archived, name:url.lastPathComponent))
            } catch { issues.append(url.lastPathComponent + ": " + String(describing:error)) }
        }
    }
    deinit { dbs.removeAll(); if let s = scratch { try? fm.removeItem(at:s) } }
    func series(_ table: String, required: [String], optional: [String] = [], interval: Bool = false, boundaries: Bool = false, condition: String = "1") -> Series {
        var result = Series(issues:issues)
        var seen = Set<Data>()
        for db in dbs {
            do {
                let columns = try db.columns(table)
                guard Set(["timestamp"] + required + (interval ? ["timestampEnd"] : [])).isSubset(of:columns) else { throw QueryError("table or required columns unavailable") }
                let fields = (["timestamp"] + (interval ? ["timestampEnd"] : []) + required + optional.filter{columns.contains($0)}).map{"\"\($0)\""}.joined(separator:",")
                let select = "SELECT \(fields) FROM \"\(table)\""
                let predicate = interval ? "timestampEnd > ? AND timestamp < ?" : "timestamp >= ? AND timestamp <= ?"
                var rows = try db.select(select + " WHERE (" + predicate + ") AND (" + condition + ")", [range.start,range.end])
                if boundaries && !interval {
                    rows += try db.select(select + " WHERE timestamp < ? AND (" + condition + ") ORDER BY timestamp DESC LIMIT 1", [range.start])
                    rows += try db.select(select + " WHERE timestamp > ? AND (" + condition + ") ORDER BY timestamp ASC LIMIT 1", [range.end])
                }
                result.files.append(db.name)
                for row in rows {
                    // Drop archive-boundary copies, not distinct events sharing a time.
                    if let data = try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]), seen.insert(data).inserted { result.rows.append(row) }
                }
            } catch { result.issues.append(db.name + " / " + table + ": " + String(describing:error)) }
        }
        result.rows.sort { (number($0["timestamp"]) ?? 0) < (number($1["timestamp"]) ?? 0) }
        return result
    }
    func sources() -> [Row] {
        dataTables.map { table in
            var first:Double?,last:Double?,count=0,errors=issues
            for db in dbs {
                do {
                    let cols = try db.columns(table)
                    guard cols.contains("timestamp") else { throw QueryError("table unavailable") }
                    if let row = try db.select("SELECT count(*) AS n,min(timestamp) AS first,max(timestamp) AS last FROM \"\(table)\"").first {
                        count += Int(number(row["n"]) ?? 0)
                        if let a=number(row["first"]) { first=min(first ?? a,a) }
                        if let b=number(row["last"]) { last=max(last ?? b,b) }
                    }
                } catch { errors.append(db.name + ": " + String(describing:error)) }
            }
            return ["table":table,"rows_in_selected_files":count,"first_observed":first.map(stamp) as Any? ?? null,
                    "last_observed":last.map(stamp) as Any? ?? null,"status":count == 0 ? "unavailable" : errors.isEmpty ? "ok" : "partial","issues":errors]
        }
    }
}
func powerRows(_ log: PowerLog) -> Series {
    log.series(powerTable,required:["SystemLoad","AccumulatedSystemLoad","SystemLoadAccumulatorCount"],
               optional:["SystemPowerIn","AccumulatedSystemPowerIn","SystemPowerInAccumulatorCount","SystemInputVoltage","SystemInputCurrent","PowerTelemetryErrorCount"],boundaries:true)
}
func batteryRows(_ log: PowerLog) -> Series {
    log.series(batteryTable,required:["ExternalConnected","IsCharging","Level"],
               optional:["Voltage","InstantAmperage","AverageAmperage","AppleRawCurrentCapacity","AppleRawMaxCapacity","Temperature","CycleCount"],boundaries:true)
}
func sleepRows(_ log: PowerLog) -> Series {
    log.series(sleepTable,required:["State","Event"],optional:["Capabilities","WakeType"],boundaries:true,condition:"(State=1 AND Event IN (1,4,6)) OR (State=5 AND Event IN (0,6)) OR (State=0 AND Event=6)")
}
func idleRows(_ log: PowerLog) -> Series { log.series(idleTable,required:["Idle"],boundaries:true) }
struct Span { let a:Double; let b:Double; let state:String }
func states(_ sleep:Series,_ idle:Series,_ r:Range) -> [Span] {
    // Private PowerLog mapping observed on current macOS: State 1 = sleep,
    // State 5 = maintenance/dark wake, State 0/Event 6 = full wake.
    // Ignore other transitional events rather than guessing.
    var events:[(Double,String,String)] = []
    for row in sleep.rows {
        guard let t=number(row["timestamp"]),let state=number(row["State"]),let event=number(row["Event"]) else { continue }
        if state == 1 && (event == 1 || event == 4 || event == 6) { events.append((t,"sleep","sleep")) }
        else if state == 5 && (event == 0 || event == 6) { events.append((t,"sleep","dark_wake")) }
        else if state == 0 && event == 6 { events.append((t,"sleep","awake")) }
    }
    for row in idle.rows {
        if let t=number(row["timestamp"]),let v=number(row["Idle"]) { events.append((t,"idle",v == 1 ? "idle" : "active")) }
    }
    events.sort{$0.0 < $1.0}
    var power="unknown", user="unknown", cursor=r.start, spans:[Span]=[]
    func label()->String { if power=="sleep" || power=="dark_wake" { return power }; if power=="awake" { return user=="unknown" ? "awake_unknown" : "awake_"+user }; return "unknown" }
    for (t,kind,value) in events where t <= r.end {
        if t > cursor { spans.append(Span(a:cursor,b:t,state:label())); cursor=t }
        if kind=="sleep" { power=value } else { user=value }
    }
    if cursor<r.end { spans.append(Span(a:cursor,b:r.end,state:label())) }
    var merged:[Span]=[]
    for s in spans {
        if let old=merged.last,old.state==s.state,old.b==s.a { merged[merged.count-1]=Span(a:old.a,b:s.b,state:s.state) }
        else { merged.append(s) }
    }
    return merged
}
struct PowerInterval { let a:Double;let b:Double;let load:Double?;let input:Double?;let battery:Double? }
func counterPower(_ a:Row,_ b:Row,_ sum:String,_ count:String,_ elapsed:Double) -> Double? {
    guard let x=number(a[sum]),let y=number(b[sum]),let c=number(a[count]),let d=number(b[count]),
          d>c,y>=x,elapsed>0 else { return nil }
    // Counters represent sampled mW. Require time-consistent coverage; skip resets
    // and sparse/unsigned input accumulators instead of treating them as energy.
    if let e1=number(a["PowerTelemetryErrorCount"]),let e2=number(b["PowerTelemetryErrorCount"]),e1 != e2 { return nil }
    let rate=(d-c)/elapsed, w=(y-x)/(d-c)/1000
    guard rate >= 0.8, rate <= 1.2, w >= 0, w < 1000 else { return nil }
    return w
}
func powerIntervals(_ power:Series,_ battery:Series,_ r:Range)->[PowerInterval] {
    let b = battery.rows
    var i=0
    func nearest(_ t:Double)->Row? {
        while i+1<b.count && (number(b[i+1]["timestamp"]) ?? 0)<=t { i += 1 }
        guard i<b.count,let a=number(b[i]["timestamp"]) else { return nil }
        if i+1<b.count,let next=number(b[i+1]["timestamp"]),abs(next-t)<abs(a-t),abs(next-t)<=2 { return b[i+1] }
        return abs(a-t)<=2 ? b[i] : nil
    }
    var result:[PowerInterval]=[]
    // Keep one observation per timestamp, choosing the most complete row.
    let sorted=power.rows
    for (a,z) in zip(sorted,sorted.dropFirst()) {
        guard let t=number(a["timestamp"]),let u=number(z["timestamp"]),u>t,r.overlap(t,u)>0 else { continue }
        let elapsed=u-t, ba=nearest(t),bz=nearest(u)
        let load=counterPower(a,z,"AccumulatedSystemLoad","SystemLoadAccumulatorCount",elapsed)
        var input:Double?, batt:Double?
        if let ba=ba,let bz=bz,let ac1=number(ba["ExternalConnected"]),let ac2=number(bz["ExternalConnected"]),ac1==ac2 {
            if ac1==0 { input=0 } else if ac1==1 {
                input=counterPower(a,z,"AccumulatedSystemPowerIn","SystemPowerInAccumulatorCount",elapsed)
            }
            if elapsed<=120,let v1=number(ba["Voltage"]),let v2=number(bz["Voltage"]),
               let c1=number(ba["InstantAmperage"]),let c2=number(bz["InstantAmperage"]),
               v1>0,v2>0,abs(c1)<100000,abs(c2)<100000 {
                // Positive = charge, negative = discharge; point samples, not counters.
                batt=(v1*c1+v2*c2)/2e6
            }
        }
        result.append(PowerInterval(a:t,b:u,load:load,input:input,battery:batt))
    }
    return result
}
struct Energy {
    var seconds=0.0,wh=0.0,peak:Double?
    mutating func add(_ w:Double?,_ t:Double) { guard let w=w,t>0 else{return};seconds+=t;wh+=w*t/3600;peak=max(peak ?? w,w) }
    func json(_ duration:Double)->Row { ["covered_seconds":seconds,"coverage_pct":duration>0 ? min(100,seconds/duration*100):0,
        "energy_wh":numeric(seconds>0 ? wh:nil),"energy_kwh":numeric(seconds>0 ? wh/1000:nil),
        "average_power_w":numeric(seconds>0 ? wh*3600/seconds:nil),"max_interval_average_w":numeric(peak)] }
}
func gaps(_ intervals:[PowerInterval],_ r:Range,_ value:KeyPath<PowerInterval,Double?>,_ limit:Int)->Row {
    var cursor=r.start, missing:[Range]=[]
    for p in intervals where p[keyPath:value] != nil {
        let a=max(r.start,p.a), b=min(r.end,p.b);guard b>a else{continue}
        if a>cursor {missing.append(Range(start:cursor,end:a))}
        cursor=max(cursor,b)
    }
    if cursor<r.end{missing.append(Range(start:cursor,end:r.end))}
    return ["count":missing.count,"missing_seconds":missing.reduce(0){$0+$1.seconds},"recent_ranges":missing.suffix(limit).map{$0.json}]
}
func powerSummary(_ intervals:[PowerInterval],_ r:Range)->Row {
    var system=Energy(),input=Energy(),charge=Energy(),discharge=Energy()
    for p in intervals {
        let d=r.overlap(p.a,p.b);guard d>0 else{continue}
        system.add(p.load,d);input.add(p.input,d)
        if let w=p.battery { charge.add(max(0,w),d);discharge.add(max(0,-w),d) }
    }
    return ["system_load":system.json(r.seconds),"external_dc_input":input.json(r.seconds),"battery_charge_estimate":charge.json(r.seconds),"battery_discharge_estimate":discharge.json(r.seconds)]
}
func buckets(_ r:Range,_ group:String)->[Range] {
    let unit:Calendar.Component = group=="day" ? .day:.hour
    var result:[Range]=[],cursor=r.start
    while cursor<r.end {
        guard let di=calendar.dateInterval(of:unit,for:Date(timeIntervalSince1970:cursor)) else{break}
        let end=min(r.end,di.end.timeIntervalSince1970);guard end>cursor else{break}
        result.append(Range(start:cursor,end:end));cursor=end
    }
    return result
}
func aggregateStates(_ spans:[Span],_ intervals:[PowerInterval],_ r:Range)->[Row] {
    var totals:[String:(Double,Energy)]=[:]
    for s in spans {
        let a=max(s.a,r.start), b=min(s.b,r.end);guard b>a else{continue}
        var (duration,energy)=totals[s.state] ?? (0,Energy())
        duration+=b-a
        let sub=Range(start:a,end:b)
        for i in intervals where i.b>a && i.a<b { energy.add(i.load,sub.overlap(i.a,i.b)) }
        totals[s.state]=(duration,energy)
    }
    return totals.keys.sorted().map { k in
        let (duration,energy)=totals[k]!
        return ["state":k,"duration_seconds":duration,"system_load":energy.json(duration)]
    }
}
func statusFor(_ series:[Series],usable:Bool)->String { !usable ? "unavailable" : series.contains{ !$0.issues.isEmpty } ? "partial":"ok" }
func powerResult(_ log:PowerLog,_ o:Options,_ isSleep:Bool=false)->Row {
    let p=powerRows(log),b=batteryRows(log),s=sleepRows(log),i=idleRows(log)
    let intervals=powerIntervals(p,b,o.range),spans=states(s,i,o.range)
    let summary=powerSummary(intervals,o.range)
    let covered=number((summary["system_load"] as? Row)?["covered_seconds"]) ?? 0
    let stateRows=aggregateStates(spans,intervals,o.range)
    let knownState = spans.contains{$0.state != "unknown"}
    let points=p.rows.filter{ let t=number($0["timestamp"]) ?? 0; return t>=o.range.start && t<=o.range.end }
    let observed=points.compactMap{number($0["SystemLoad"])}.filter{$0>=0 && $0<1000000}.map{$0/1000}
    var pointSummary:Row=["max_observed_system_load_w":numeric(observed.max()),"sample_count":observed.count]
    if let last=points.last,let t=number(last["timestamp"]) {
        pointSummary["last_sample_at"]=stamp(t)
        pointSummary["last_observed_system_load_w"]=numeric(number(last["SystemLoad"]).flatMap{$0>=0 && $0<1000000 ? $0/1000:nil})
    }
    var result:Row=["status":statusFor(isSleep ? [s,i]:[p,b],usable:isSleep ? knownState : covered>0),
        "sources":["power":p.info,"battery":b.info,"sleep":s.info,"idle":i.info],
        "summary":summary,"point_samples":pointSummary,"states":stateRows,"estimated":true,
        "coverage_gaps":["system_load":gaps(intervals,o.range,\.load,o.limit),
                         "external_dc_input":gaps(intervals,o.range,\.input,o.limit),
                         "battery_estimate":gaps(intervals,o.range,\.battery,o.limit)],
        "notes":["PowerLog is an undocumented, version-dependent source. System load is not wall-socket consumption.",
                 "Counter intervals are time-weighted and prorated at boundaries. Peak is the maximum interval average, not a transient peak.",
                 "Uncovered or reset intervals are excluded. External input is DC only; disconnected intervals are zero only when both battery observations agree.",
                 "Battery energy uses signed instantaneous current and voltage; sparse or switching intervals are excluded.",
                 "Sleep state mapping is inferred from PowerLog; dark wake is separate. User idle does not prove display-off or human sleep."]]
    if !isSleep && covered>0 && (covered<o.range.seconds || [p,b,s,i].contains{!$0.issues.isEmpty} || !knownState) { result["status"]="partial" }
    if isSleep && spans.contains(where:{$0.state=="unknown" || $0.state=="awake_unknown"}) && knownState { result["status"]="partial" }
    if isSleep || o.topic=="timeline" {
        result["intervals"]=Array(spans.reversed().prefix(o.limit)).reversed().map{["from":stamp($0.a),"to":stamp($0.b),"state":$0.state]};result["interval_count"]=spans.count
    }
    if let group=o.group {
        let all=buckets(o.range,group)
        result["groups"]=all.suffix(o.limit).map{r in ["range":r.json,"summary":powerSummary(intervals,r),"states":aggregateStates(spans,intervals,r)] as Row}
        result["group_count"]=all.count
    }
    return result
}
func batteryResult(_ log:PowerLog,_ o:Options)->Row {
    let b=batteryRows(log),p=powerRows(log)
    let rows=b.rows.filter{let t=number($0["timestamp"]) ?? 0;return t>=o.range.start && t<=o.range.end}
    let points=rows.suffix(o.limit).map { row -> Row in
        var r=row; if let t=number(r.removeValue(forKey:"timestamp")) {r["timestamp"]=stamp(t)}
        return r
    }
    let levels=rows.compactMap{number($0["Level"])}
    return ["status":statusFor([b],usable:!rows.isEmpty),"source":b.info,"summary":["first_level_pct":numeric(levels.first),"last_level_pct":numeric(levels.last),"min_level_pct":numeric(levels.min()),"max_level_pct":numeric(levels.max()),"sample_count":rows.count],
            "energy":powerSummary(powerIntervals(p,b,o.range),o.range),"samples":points,"estimated":true,
            "notes":["Raw battery fields are retained with their native names; battery current is signed. Energy uses observed intervals only."]]
}
func cpuResult(_ log:PowerLog,_ o:Options)->Row {
    let s=log.series(cpuTable,required:["cpu_time","LaunchdName"],optional:["BundleId","gpu_energy_nj","ane_energy_nj","bytesread","byteswritten","platform_idle_wakeups"],interval:true)
    var totals:[String:[String:Double]]=[:];var used=0
    for row in s.rows {
        guard let a=number(row["timestamp"]),let b=number(row["timestampEnd"]),b>a,let cpu=number(row["cpu_time"]),cpu>=0 else{continue}
        let d=o.range.overlap(a,b);guard d>0 else{continue}
        let name=str(row["BundleId"]).isEmpty ? str(row["LaunchdName"]):str(row["BundleId"])
        guard !name.isEmpty else{continue}
        let fraction=d/(b-a);var t=totals[name] ?? [:]
        for k in ["cpu_time","gpu_energy_nj","ane_energy_nj","bytesread","byteswritten","platform_idle_wakeups"] { if let v=number(row[k]),v>=0 {t[k,default:0]+=v*fraction} }
        totals[name]=t;used+=1
    }
    let apps=totals.sorted{($0.value["cpu_time"] ?? 0)>($1.value["cpu_time"] ?? 0)}.prefix(o.limit).map{key,t -> Row in
        ["app_or_coalition":key,"cpu_seconds":numeric(t["cpu_time"]),"gpu_energy_j":numeric(t["gpu_energy_nj"].map{$0/1e9}),"ane_energy_j":numeric(t["ane_energy_nj"].map{$0/1e9}),"bytes_read":numeric(t["bytesread"]),"bytes_written":numeric(t["byteswritten"]),"platform_idle_wakeups":numeric(t["platform_idle_wakeups"])]
    }
    return ["status":statusFor([s],usable:used>0),"source":s.info,"top":apps,"coalition_count":totals.count,"estimated":true,"notes":["PowerLog coalition intervals, not instantaneous process CPU. Partial interval values are prorated; unavailable apps/intervals are not zero."]]
}
func memoryResult(_ log:PowerLog,_ o:Options)->Row {
    let s=log.series(memoryTable,required:["SwapUsedSize","MemoryPressureLevel"],optional:["FreeCount","CompressorPageCount","CompressedPageCount","WiredCount","PageIns","PageOuts"])
    let swaps=s.rows.compactMap{number($0["SwapUsedSize"])}
    var pressure:[String:Int]=[:]
    for row in s.rows {let p=str(row["MemoryPressureLevel"]);if !p.isEmpty{pressure[p,default:0]+=1}}
    let samples=s.rows.suffix(o.limit).map{ row -> Row in var r=row;if let t=number(r.removeValue(forKey:"timestamp")){r["timestamp"]=stamp(t)};return r }
    return ["status":statusFor([s],usable:!s.rows.isEmpty),"source":s.info,"summary":["sample_count":s.rows.count,"max_swap_bytes":numeric(swaps.max()),"pressure_sample_counts":pressure],"samples":samples,"notes":["PowerLog memory samples are sparse; they do not represent every transient event. Page counts are native fields; no assumed page size."]]
}
func tsv(_ url:URL)->[Row] {
    guard let text=readText(url) else{return []}
    var lines=text.split(separator:"\n",omittingEmptySubsequences:true)
    guard !lines.isEmpty else{return []}
    let keys=lines.removeFirst().split(separator:"\t",omittingEmptySubsequences:false).map(String.init)
    guard keys.count>1,Set(keys).count==keys.count else{return []}
    return lines.compactMap{line in
        let values=line.split(separator:"\t",omittingEmptySubsequences:false).map(String.init)
        guard values.count==keys.count else{return nil}
        return Dictionary(uniqueKeysWithValues:zip(keys,values).map{($0.0,$0.1 as Any)})
    }
}
func selected(_ rows:[Row],_ r:Range,_ keys:[String]=["timestamp","observed_at","captured_at","first_observed"])->[Row] {
    rows.filter{row in keys.compactMap{time(row[$0])}.contains{$0>=r.start && $0<=r.end}}
}
func networkResult(_ log:PowerLog,_ o:Options,_ data:URL)->Row {
    let s=log.series(networkTable,required:["ProcessName"],optional:["BundleName","WifiIn","WifiOut","WiredIn","WiredOut","BTCompanionIn","BTCompanionOut"],interval:true)
    var totals:[String:[String:Double]]=[:]
    for row in s.rows {
        guard let a=number(row["timestamp"]),let b=number(row["timestampEnd"]),b>a else{continue}
        let d=o.range.overlap(a,b)/(b-a),name=str(row["BundleName"]).isEmpty ? str(row["ProcessName"]):str(row["BundleName"])
        guard d>0,!name.isEmpty else{continue}
        let rx=["WifiIn","WiredIn","BTCompanionIn"].compactMap{number(row[$0])}.filter{$0>=0}
        let tx=["WifiOut","WiredOut","BTCompanionOut"].compactMap{number(row[$0])}.filter{$0>=0}
        guard !rx.isEmpty || !tx.isEmpty else{continue}
        var t=totals[name] ?? [:];if !rx.isEmpty{t["received_bytes",default:0]+=rx.reduce(0,+)*d};if !tx.isEmpty{t["sent_bytes",default:0]+=tx.reduce(0,+)*d};totals[name]=t
    }
    let events=selected(tsv(data.appendingPathComponent("network-events.tsv")),o.range)
    return ["status":statusFor([s],usable:!totals.isEmpty || !events.isEmpty),"source":s.info,
            "top_transfer":totals.sorted{$0.value.values.reduce(0,+)>$1.value.values.reduce(0,+)}.prefix(o.limit).map{["app":$0.key,"received_bytes":numeric($0.value["received_bytes"]),"sent_bytes":numeric($0.value["sent_bytes"])] as Row},
            "monitor_events":Array(events.suffix(o.limit)),"monitor_event_count":events.count,"estimated":true,
            "notes":["OS transfer intervals and monitor reachability/path transitions are different evidence. Missing transitions do not prove continuous connectivity."]]
}
func properties(_ file:URL)->Row {
    guard let text=readText(file) else{return [:]}
    var r:Row=[:]
    for line in text.split(separator:"\n") {if let p=line.firstIndex(of:"="){r[String(line[..<p])]=String(line[line.index(after:p)...])}}
    return r
}
func incidentResult(_ data:URL,_ o:Options)->Row {
    let items=files(data.appendingPathComponent("incidents")).compactMap{u -> Row? in
        let m=properties(u.appendingPathComponent("metadata.txt"))
        guard let t=time(m["started"]),t<o.range.end,(time(m["ended"]) ?? t)>=o.range.start else{return nil}
        let d=properties(u.appendingPathComponent("diagnosis.txt"))
        return ["id":u.lastPathComponent,"started":stamp(t),"ended":m["ended"] ?? null,"reason":m["reason"] ?? null,
                "completion_status":m["completion_status"] ?? "unknown","classification":d["classification"] ?? null,"confidence":d["confidence"] ?? null,
                "path":u.path]
    }.sorted{str($0["started"])>str($1["started"])}
    return ["status":"ok","source":"maclagmonitor.incidents","count":items.count,"incidents":Array(items.prefix(o.limit)),
            "notes":["Retained captures only; no incidents found does not establish absence of faults."]]
}
func reportsResult(_ o:Options)->Row {
    let roots=[fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),URL(fileURLWithPath:"/Library/Logs/DiagnosticReports")]
    var results:[Row]=[]
    for root in roots {
        for f in files(root) where ["ips","diag","crash","hang","spin","panic"].contains(f.pathExtension) {
            guard let date=(try? f.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate else{continue}
            let t=date.timeIntervalSince1970;guard t>=o.range.start && t<=o.range.end else{continue}
            results.append(["name":f.lastPathComponent,"modified_at":stamp(t),"path":f.path,"type":f.pathExtension])
        }
    }
    results.sort{str($0["modified_at"])>str($1["modified_at"])}
    return ["status":"ok","source":"macos.DiagnosticReports","count":results.count,"reports":Array(results.prefix(o.limit)),"notes":["File modification time is not guaranteed to be the event time. Reports are referenced, not copied."]]
}
func logsResult(_ o:Options)throws->Row {
    // Query only on explicit request. Aggregate by process and level without log bodies.
    let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd HH:mm:ss"
    let p=Process(),pipe=Pipe()
    p.executableURL=URL(fileURLWithPath:"/usr/bin/log")
    p.arguments=["show","--start",f.string(from:Date(timeIntervalSince1970:o.range.start)),"--end",f.string(from:Date(timeIntervalSince1970:o.range.end)),
                 "--style","ndjson","--predicate","(messageType == error OR messageType == fault) AND (process == \"kernel\" OR process == \"airportd\" OR process == \"configd\" OR process == \"mDNSResponder\" OR process == \"nesessionmanager\" OR process == \"neagent\" OR process == \"nehelper\" OR process == \"ReportCrash\" OR process == \"WindowServer\" OR process == \"powerd\")"]
    p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
    try p.run()
    var counts:[String:Int]=[:],pending=Data()
    while true {
        let d=pipe.fileHandleForReading.availableData;if d.isEmpty{break};pending.append(d)
        while let index=pending.firstIndex(of:10) {
            let line=pending.prefix(upTo:index);pending.removeSubrange(...index)
            if let row=(try? JSONSerialization.jsonObject(with:line)) as? Row {
                let name=URL(fileURLWithPath:str(row["processImagePath"])).lastPathComponent
                guard !name.isEmpty else{continue}
                counts[name+" / "+str(row["messageType"]),default:0]+=1
            }
        }
    }
    p.waitUntilExit()
    return ["status":p.terminationStatus==0 ? "ok":"partial","source":"macos.UnifiedLog","exit_status":p.terminationStatus,
            "categories":counts.sorted{$0.value>$1.value}.prefix(o.limit).map{["category":$0.key,"records":$0.value] as Row},
            "notes":["Filtered error/fault records only; retained log messages are not independent fault counts. No raw messages stored or returned."]]
}
func historicalResult(_ root:URL,_ o:Options)->Row {
    let data=root.appendingPathComponent("data")
    let old=files(data).filter{$0.lastPathComponent=="summary.tsv" || ($0.lastPathComponent.hasPrefix("summary-legacy-") && $0.pathExtension=="tsv")}
    let recent=root.appendingPathComponent("state/recent-detection.tsv")
    let sources=old+[recent]
    var matches:[Row]=[], info:[Row]=[]
    for url in sources where fm.fileExists(atPath:url.path) {
        let rows=selected(tsv(url),o.range)
        matches += rows.map { row in var r=row;r["source_file"]=url.lastPathComponent;return r }
        info.append(["file":url.lastPathComponent,"matching_rows":rows.count])
    }
    matches.sort{(time($0["timestamp"]) ?? 0)<(time($1["timestamp"]) ?? 0)}
    return ["status":info.isEmpty ? "unavailable":"ok","sources":info,"count":matches.count,"samples":Array(matches.suffix(o.limit)),
            "notes":["Frozen pre-upgrade history and bounded recent detection only. Missing or unknown values are not zero. No normal historical logging is performed."]]
}
func localEvidence(_ data:URL,_ o:Options)->Row {
    let context=selected(tsv(data.appendingPathComponent("process-context.tsv")),o.range)
    let lifecycle=selected(tsv(data.appendingPathComponent("safari-lifecycle.tsv")),o.range)
    return ["process_context":Array(context.suffix(o.limit)),"process_context_count":context.count,"safari_lifecycle":Array(lifecycle.suffix(o.limit)),"safari_lifecycle_count":lifecycle.count]
}
func chronologicalEvents(_ parts:Row,_ limit:Int)->Row {
    var events:[Row]=[]
    func add(_ rows:[Row],_ key:String,_ kind:String) {
        for row in rows {
            if let t=time(row[key]) { events.append(["timestamp":stamp(t),"kind":kind,"evidence":row]) }
        }
    }
    add((parts["power"] as? Row)?["intervals"] as? [Row] ?? [],"from","power_state")
    add((parts["network"] as? Row)?["monitor_events"] as? [Row] ?? [],"timestamp","network_transition")
    add((parts["memory"] as? Row)?["samples"] as? [Row] ?? [],"timestamp","os_memory_sample")
    add((parts["incidents"] as? Row)?["incidents"] as? [Row] ?? [],"started","incident")
    add(parts["recent_detection"] as? [Row] ?? [],"timestamp","monitor_detection")
    add((parts["local_evidence"] as? Row)?["safari_lifecycle"] as? [Row] ?? [],"observed_at","safari_lifecycle")
    events.sort{str($0["timestamp"])<str($1["timestamp"])}
    return ["count_in_selected_results":events.count,"events":Array(events.suffix(limit))]
}
func runQuery(_ root:URL,_ args:[String]) throws {
    let o=try Options(args),data=root.appendingPathComponent("data")
    let native=URL(fileURLWithPath:env["MLM_POWERLOG_ROOT"] ?? "/private/var/db/powerlog/Library/BatteryLife",isDirectory:true)
    var result:Row
    switch o.topic {
    case "incidents":result=incidentResult(data,o)
    case "history":result=historicalResult(root,o)
    case "reports":result=reportsResult(o)
    case "logs":result=try logsResult(o)
    case "sources","power","battery","sleep","cpu","memory","network","timeline":
        let log=PowerLog(root:native,range:o.range)
        switch o.topic {
        case "sources":
            let list=log.sources()
            result=["status":list.contains{str($0["status"])=="ok"} ? "ok":list.contains{str($0["status"])=="partial"} ? "partial":"unavailable",
                    "powerlog":list,"local_sources": ["network-events.tsv","process-context.tsv","safari-lifecycle.tsv","incidents"].map{["name":$0,"exists":fm.fileExists(atPath:data.appendingPathComponent($0).path)]},
                    "notes":["Availability is based on the selected archive files; private schemas may change. Unified Log and DiagnosticReports are queried separately."]]
        case "power":result=powerResult(log,o)
        case "battery":result=batteryResult(log,o)
        case "sleep":result=powerResult(log,o,true)
        case "cpu":result=cpuResult(log,o)
        case "memory":result=memoryResult(log,o)
        case "network":result=networkResult(log,o,data)
        default:
            let parts:Row=["power":powerResult(log,o),"cpu":cpuResult(log,o),"memory":memoryResult(log,o),"network":networkResult(log,o,data),"incidents":incidentResult(data,o),"reports":reportsResult(o),"local_evidence":localEvidence(data,o),"recent_detection":Array(selected(tsv(root.appendingPathComponent("state/recent-detection.tsv")),o.range).suffix(o.limit))]
            result=["status":parts.values.contains{($0 as? Row)?["status"] as? String == "partial" || ($0 as? Row)?["status"] as? String == "unavailable"} ? "partial":"ok","topics":parts,"chronological_evidence":chronologicalEvents(parts,o.limit),"notes":["Groups describe power and state. Sources have different sampling intervals and coverage; temporal coincidence does not establish causation. Use query logs for an explicit Unified Log scan."]]
        }
    default:throw QueryError("unknown query topic "+o.topic)
    }
    result["schema_version"]=1;result["topic"]=o.topic;result["requested_range"]=o.range.json;result["local_timezone"]=TimeZone.current.identifier
    // Compact JSON is the stable machine contract. Pretty JSON is also readable
    // in a terminal, avoiding a second formatter and divergent output semantics.
    try writeJSON(result,pretty:!o.json)
}
func status(_ root:URL,_ args:[String])throws {
    let state=root.appendingPathComponent("state"),data=root.appendingPathComponent("data")
    let pid=readText(state.appendingPathComponent("monitor.pid")).flatMap{Int32($0.trimmingCharacters(in:.whitespacesAndNewlines))}
    let active=pid.map{$0>0 && kill($0,0)==0} ?? false
    let config=properties(root.appendingPathComponent("config.conf"))
    let keys=["AC_INTERVAL_SECONDS","BATTERY_INTERVAL_SECONDS","LOW_POWER_INTERVAL_SECONDS","DISPLAY_OFF_INTERVAL_SECONDS","INCIDENT_INTERVAL_SECONDS","INCIDENT_DURATION_SECONDS","INTERNET_PROBE_INTERVAL_SECONDS"]
    var settings:Row=[:]
    let defaults:[String:Double]=["AC_INTERVAL_SECONDS":120,"BATTERY_INTERVAL_SECONDS":300,"LOW_POWER_INTERVAL_SECONDS":600,"DISPLAY_OFF_INTERVAL_SECONDS":600,"INCIDENT_INTERVAL_SECONDS":8,"INCIDENT_DURATION_SECONDS":240,"INTERNET_PROBE_INTERVAL_SECONDS":300]
    for k in keys {if let n=number(config[k]) ?? defaults[k]{settings[k]=n}}
    let last=tsv(state.appendingPathComponent("recent-detection.tsv")).last
    let result:Row=["schema_version":1,"status":active ? "running":"stopped","version":readText(root.appendingPathComponent("VERSION"))?.trimmingCharacters(in:.whitespacesAndNewlines) as Any? ?? null,"pid":active ? pid as Any? ?? null:null,
                    "settings":settings,"latest_detection":last as Any? ?? null,"incident_count":files(data.appendingPathComponent("incidents")).count]
    try writeJSON(result,pretty:!args.contains("--json"))
}
let a=Array(CommandLine.arguments.dropFirst())
do {
    guard let command=a.first else{throw QueryError("missing native command")}
    if command=="display" {print(displayState());exit(0)}
    if command=="wait" {
        guard a.count==3,let n=Double(a[1]),n.isFinite,n>=0 else{throw QueryError("wait requires seconds and memory flag")}
        waitForEvent(n,memory:Int(a[2]) ?? 0)
    }
    guard a.count>=2 else{throw QueryError("missing install root")}
    let root=URL(fileURLWithPath:a[1],isDirectory:true)
    if command=="query" {try runQuery(root,Array(a.dropFirst(2)))}
    else if command=="status" {try status(root,Array(a.dropFirst(2)))}
    else {throw QueryError("unknown native command")}
} catch {fail(String(describing:error))}
