//
//  ServiceFinder.swift
//  SpokenWord
//
//  Created by Joe Holt on 5/9/23.
//  Copyright © 2023 Apple. All rights reserved.
//

import Foundation
import dnssd

class ServiceHost {
    var finder: ServiceFinder
    var host: String
    var port: UInt16
    var sd: DNSServiceRef?
    var error: DNSServiceErrorType = 0
    var queryTimer: Timer?

    init(_ infinder: ServiceFinder, _ inhost: String, _ inport: UInt16) {
        finder = infinder
        host = inhost
        port = inport
        resolve()
    }

    deinit {
        if (queryTimer != nil) {
            queryTimer!.invalidate()
        }
        if (sd != nil) {
            DNSServiceRefDeallocate(sd)
        }
    }

    let queryReply: DNSServiceQueryRecordReply = { _, _, _, error, _, _, _, rdlen, rdata, _, context in
        let this: ServiceHost = Unmanaged.fromOpaque(context!).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError else {
            this.error = error
            return
        }
        guard var offsetPointer = rdata else { return }

        let a = offsetPointer.load(as: UInt8.self)
        offsetPointer += 1
        let b = offsetPointer.load(as: UInt8.self)
        offsetPointer += 1
        let c = offsetPointer.load(as: UInt8.self)
        offsetPointer += 1
        let d = offsetPointer.load(as: UInt8.self)
        let addr = "\(a).\(b).\(c).\(d)"

        print("resolved \(this.host) -> \(addr)")

        var dt = this.finder.dests.first(where: { return ($0.ip == addr && $0.port == this.port && $0.host == this.host) })
        if (dt == nil) {
            dt = Dest(addr, this.port, this.host)
            this.finder.dests.append(dt!)
        }
    }

    func resolve() {
        DNSServiceQueryRecord(&sd, 0, 0, host, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), queryReply, Unmanaged.passUnretained(self).toOpaque())

        queryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            guard let sd = self.sd else { return }
            let sfd = DNSServiceRefSockFD(sd)
            guard sfd >= 0 else { return }
            let ev = Int16(POLLIN)
            var pollFD = pollfd(fd: sfd, events: ev, revents: 0)
            guard poll(&pollFD, 1, 0) > 0 else { return }
            let error = DNSServiceProcessResult(sd)
            if (error != 0) {
                print("DNSServiceProcessResult(resolve) error: \(error)")
            }
        }
    }
}

class Dest {
    var ip = ""
    var port: UInt16 = 0
    var host = ""
    var sock: sockaddr_in
    var fd: Int32 = 0
    var createTime: Double = 0

    init(_ inip: String, _ inport: UInt16, _ inhost: String) {
        ip = inip
        host = inhost
        port = inport
        sock = sockaddr_in()
        createTime = Date().timeIntervalSince1970

        var ep = port
        if (NSHostByteOrder() == NS_LittleEndian) {
            ep = NSSwapShort(ep)
        }
        sock.sin_len = UInt8(MemoryLayout.size(ofValue: sock))
        sock.sin_family = sa_family_t(AF_INET)
        sock.sin_addr.s_addr = inet_addr(ip)
        sock.sin_port = ep

        fd = socket(AF_INET, SOCK_DGRAM, 0)  // DGRAM makes it UDP
    }

    deinit {
        if (fd != 0) {
            close(fd)
        }
    }
}

// https://opensource.apple.com/source/mDNSResponder/mDNSResponder-544/mDNSShared/dns_sd.h.auto.html

class ServiceFinder {
    var services: [String] = []
    var hosts: [ServiceHost] = []
    var dests: [Dest] = []
    var browseSR: DNSServiceRef?
    var browseError: DNSServiceErrorType = 0
    var resolveSR: DNSServiceRef?
    var resolveError: DNSServiceErrorType = 0
    var lookingFor: String
    
    init(_ inlookingFor: String) {
        print("ServiceFinder")
        lookingFor = inlookingFor
        var error = DNSServiceBrowse(&browseSR, 0, 0, "_x-plane9._udp", "local", browseReply, Unmanaged.passUnretained(self).toOpaque())
        if (error != 0) {
            print("error browsing (1): \(error)")
        }

        error = DNSServiceResolve(&resolveSR, 0, 0, lookingFor, "_x-plane9._udp", "local", resolveReply, Unmanaged.passUnretained(self).toOpaque())
        if error != 0 {
            print("error browsing (2): \(error)")
        }

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            self.checkForResult(self.browseSR)
            self.checkForResult(self.resolveSR)
        }
        
    }

    func checkForResult(_ insd:DNSServiceRef?) {
        guard let sd = insd else { return }
        let sfd = DNSServiceRefSockFD(sd)
        guard sfd >= 0 else { return }
        let ev = Int16(POLLIN)
        var pollFD = pollfd(fd: sfd, events: ev, revents: 0)
        guard poll(&pollFD, 1, 0) > 0 else { return }
        let error = DNSServiceProcessResult(sd)
        if (error != 0) {
            print("DNSServiceProcessResult(checkForResult) error: \(error)")
        }
    }

    let browseReply: DNSServiceBrowseReply = { _, flags, _, error, serviceName, _, _, context in
        let this: ServiceFinder = Unmanaged.fromOpaque(context!).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError else {
            this.browseError = error
            print("browseReply error: \(error)")
            return
        }
        
        let serviceName = String(cString: serviceName!)
//            print("browseReply: \(serviceName) \(flags)")
        if (serviceName == this.lookingFor) {
            var add = (flags == 3 || flags == 2)  // kDNSServiceFlagsAdd + kDNSServiceFlagsMoreComing
            if (add) {
                if (!this.services.contains(serviceName)) {
                    this.services.append(serviceName)
                    
                }
            } else {
                if let i = this.services.firstIndex(of: serviceName) {
                    this.services.remove(at: 0)
                }
            }
        }
    }

    let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, host, port, _, _, context in
        let this: ServiceFinder = Unmanaged.fromOpaque(context!).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError else {
            this.resolveError = error
            print("resolveReply error: \(error)")
            return
        }
        
        let host = String(cString: host!)
        let port = UInt16(bigEndian: port)
        var h = this.hosts.first(where: { return ($0.host == host && $0.port == port) })
        if (h == nil) {
            h = ServiceHost(this, host, port)
            this.hosts.append(h!)
        }
    }

    func bestDest() -> Dest? {
        if (services.contains(lookingFor) && dests.count > 0) {
            var best = dests[0]
            for dst in dests {
                let timediff = dst.createTime - best.createTime
                // consider them registered at the same time if within a small delta
                if (abs(timediff) < 2) {
                    // prefer link local
                    if (dst.ip.starts(with: "169.254")) {
                        best = dst
                    }
                    // if this one's newer then take it
                } else if (timediff > 0) {
                    best = dst
                }
            }
            return best
        }
        return nil
    }

    deinit {
        if (browseSR != nil) {
            DNSServiceRefDeallocate(browseSR)
        }
        if (resolveSR != nil) {
            DNSServiceRefDeallocate(resolveSR)
        }
    }
}
