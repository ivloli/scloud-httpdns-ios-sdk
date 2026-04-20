import Foundation

protocol ScloudHttpDnsService: AnyObject {
    func setPreResolveHosts(_ hostList: [String], requestIpType: ScloudRequestIpType)
    func getHttpDnsResultForHostSync(_ host: String, requestIpType: ScloudRequestIpType) -> ScloudHTTPDNSResult
    func getHttpDnsResultForHostAsync(
        _ host: String,
        requestIpType: ScloudRequestIpType,
        callback: @escaping (ScloudHTTPDNSResult) -> Void
    )
    func getHttpDnsResultForHostSyncNonBlocking(_ host: String, requestIpType: ScloudRequestIpType) -> ScloudHTTPDNSResult
    func cleanHostCache(_ hosts: [String]?)
}

extension ScloudHttpDnsService {
    func setPreResolveHosts(_ hostList: [String]) {
        setPreResolveHosts(hostList, requestIpType: .v4)
    }

    func getHttpDnsResultForHostSync(_ host: String) -> ScloudHTTPDNSResult {
        return getHttpDnsResultForHostSync(host, requestIpType: .v4)
    }

    func getHttpDnsResultForHostAsync(_ host: String, callback: @escaping (ScloudHTTPDNSResult) -> Void) {
        getHttpDnsResultForHostAsync(host, requestIpType: .v4, callback: callback)
    }

    func getHttpDnsResultForHostSyncNonBlocking(_ host: String) -> ScloudHTTPDNSResult {
        return getHttpDnsResultForHostSyncNonBlocking(host, requestIpType: .v4)
    }
}
