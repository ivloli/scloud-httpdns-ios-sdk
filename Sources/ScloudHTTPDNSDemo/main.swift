import Foundation
import ScloudHTTPDNS
import Darwin

setbuf(stdout, nil)

final class DemoLogger: NSObject, HttpdnsLogger {
    func log(_ message: String) {
        print("HTTPDNS \(message)")
    }
}

func env(_ key: String, _ fallback: String = "") -> String {
    ProcessInfo.processInfo.environment[key] ?? fallback
}

func printResult(_ scene: String, _ result: HttpdnsResult) {
    print("HTTPDNS \(scene) host=\(result.host)")
    print("HTTPDNS \(scene) ips=\(result.ips)")
    print("HTTPDNS \(scene) ipv6=\(result.ipv6s)")
    print("HTTPDNS \(scene) ttl=\(result.ttl) expired=\(result.expired)")
    print("HTTPDNS \(scene) extras=\(result.extras)")
}

let accountId = env("ACCOUNT_ID")
let aesKey = env("AES_KEY")

func parseHosts(_ raw: String) -> [String] {
    return raw
        .replacingOccurrences(of: "x", with: ",")
        .replacingOccurrences(of: "X", with: ",")
        .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" || $0 == "\t" })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

let hostsRaw = env("TEST_HOSTS", env("TEST_HOST", "www.baidu.com"))
let hosts = parseHosts(hostsRaw)
let testHost = hosts.first ?? "www.baidu.com"

guard !accountId.isEmpty, !aesKey.isEmpty else {
    print("ERROR: set ACCOUNT_ID and AES_KEY first")
    print("Example:")
    print("ACCOUNT_ID=430992419037876224 AES_KEY=78eb9332f1fc18a45597dbf332858ff4 swift run ScloudHTTPDNSDemo")
    exit(1)
}

print("HTTPDNS init start")
let service = HttpDnsService.initWithAccountID(accountId, aesSecretKey: aesKey, logger: DemoLogger())
print("HTTPDNS init done")
service.setPersistentCacheIPEnabled(true)

print("HTTPDNS config ready: https=<default>, cache=true, hostOverride=<none>")
print("HTTPDNS test hosts=\(hosts)")
print("HTTPDNS begin all sdk methods")

service.setPreResolveHosts(hosts, byIPType: .both)
service.setPreResolveHosts(hosts)
print("HTTPDNS preResolve done")

Thread.sleep(forTimeInterval: 2.0)
print("HTTPDNS after preResolve wait 2s")

let syncBoth = service.getHttpDnsResultForHostSync(testHost, byIPType: .both)
printResult("sync-both", syncBoth)

let syncBothCacheHit = service.getHttpDnsResultForHostSync(testHost, byIPType: .both)
printResult("sync-both-cache-hit", syncBothCacheHit)

let syncDefault = service.getHttpDnsResultForHostSync(testHost)
printResult("sync-default", syncDefault)

let sem1 = DispatchSemaphore(value: 0)
service.getHttpDnsResultForHostAsync(testHost, byIPType: .ipv4) { result in
    printResult("async-v4-callback", result)
    sem1.signal()
}
_ = sem1.wait(timeout: .now() + 15)

let sem2 = DispatchSemaphore(value: 0)
service.getHttpDnsResultForHostAsync(testHost) { result in
    printResult("async-default-callback", result)
    sem2.signal()
}
_ = sem2.wait(timeout: .now() + 15)

let nonblockingBoth = service.getHttpDnsResultForHostSyncNonBlocking(testHost, byIPType: .both)
printResult("nonblocking-both", nonblockingBoth)

let nonblockingBothCacheHit = service.getHttpDnsResultForHostSyncNonBlocking(testHost, byIPType: .both)
printResult("nonblocking-both-cache-hit", nonblockingBothCacheHit)

let nonblockingDefault = service.getHttpDnsResultForHostSyncNonBlocking(testHost)
printResult("nonblocking-default", nonblockingDefault)

service.cleanHostCache([testHost])
service.cleanHostCache(nil)
print("HTTPDNS cleanHostCache done")
print("HTTPDNS end all sdk methods")

fflush(stdout)
exit(0)
