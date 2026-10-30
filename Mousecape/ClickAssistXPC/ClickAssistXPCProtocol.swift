// baseline-guard:allow new standalone XPC protocol file, no prior baseline possible
//
//  ClickAssistXPCProtocol.swift
//  Shared by ClickAssistAgent (client) and ClickAssistResolver.xpc (service).
//  Minimal A1a surface: liveness + service identity only.
//

import Foundation

@objc protocol ClickAssistXPCProtocol {
    /// Liveness probe. The service replies with a short token.
    func ping(reply: @escaping (String) -> Void)
    /// Service identity as JSON {version, pid, epoch}. `epoch` is generated once
    /// at service start, so a client can detect a replaced process later.
    func serviceInfo(reply: @escaping (Data) -> Void)
}
